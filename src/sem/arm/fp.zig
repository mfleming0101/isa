//! Floating-point extension semantics for the T32 VFP rows: arithmetic, fused multiply-add, unary
//! operations, conversions, fixed-point, compares, moves between core and FP registers, loads,
//! stores and blocks, FPSCR access, the FPv5 extremum, rounding and select rows, and the Security
//! Extension's VLLDM, VLSTM and VSCCLRM. The numeric work lives in `lib` (src/arm/isa/fp.zig); this
//! file decodes register fields, checks the extension is present and enabled, and returns an
//! `Outcome`. Generic rows take `T` of f16, f32 or f64; the `*Double` rows carry the f64 register
//! numbering.
const std = @import("std");
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;

/// The shared floating-point library: register access, rounding, exceptions and context checks.
pub const lib = @import("../../arm/isa/fp.zig");

fn entered(s: *State, host: anytype) ?Outcome {
    return lib.check(root.Host(@TypeOf(host)), s, host) catch |err| return Outcome.faulted(err);
}

fn single(high: u32, low: u32) u5 {
    return @intCast(high << 1 | low);
}

fn double(high: u32) u5 {
    return @intCast(high << 1);
}

/// VADD, VSUB, VMUL, VNMUL and VDIV for a single or half register.
pub fn Binary(comptime kind: lib.Arithmetic, comptime T: type) type {
    return struct {
        /// Computes the operation on Sn and Sm into Sd.
        pub fn call(s: *State, host: anytype, y: u32, n: u32, d: u32, x: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const answer = lib.arithmetic(s, kind, T, lib.get(s, T, single(n, x)), lib.get(s, T, single(m, z)));
            lib.put(s, T, single(d, y), if (kind == .nmul) -answer else answer);
            return .next;
        }
    };
}

/// VMLA, VMLS, VFMA, VFMS and their negated forms for a single or half register.
pub fn Fused(comptime kind: lib.Accumulate, comptime T: type) type {
    return struct {
        /// Accumulates Sn * Sm into Sd by the kind.
        pub fn call(s: *State, host: anytype, y: u32, n: u32, d: u32, x: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const d5 = single(d, y);
            const a = lib.get(s, T, single(n, x));
            const b = lib.get(s, T, single(m, z));
            const held = lib.get(s, T, d5);
            lib.put(s, T, d5, lib.accumulate(s, kind, T, a, b, held));
            return .next;
        }
    };
}

/// VMOV, VABS, VNEG and VSQRT for a single or half register.
pub fn Unary(comptime kind: lib.Simple, comptime T: type) type {
    return struct {
        /// Applies the unary operation to Sm into Sd.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const m5 = single(m, z);
            const d5 = single(d, y);
            const top: std.meta.Int(.unsigned, @bitSizeOf(T)) = 1 << (@bitSizeOf(T) - 1);
            switch (kind) {
                .move => lib.store(s, T, d5, lib.word(s, T, m5)),
                .abs => lib.store(s, T, d5, lib.word(s, T, m5) & ~top),
                .negate => lib.store(s, T, d5, lib.word(s, T, m5) ^ top),
                .root => {
                    const value = lib.get(s, T, m5);
                    const answer = @sqrt(value);
                    lib.put(s, T, d5, lib.raise(s, T, answer, lib.root(T, value, answer), false, std.math.isNan(value), lib.signalling(T, value)));
                },
            }
            return .next;
        }
    };
}

/// VCVT and VCVTR between integers, halves and `T`, including the rounding forms.
pub fn Convert(comptime kind: lib.Cast, comptime T: type) type {
    return struct {
        /// Converts Sm into Sd by the cast kind.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            switch (kind) {
                .from_unsigned, .from_signed => {
                    const lane = s.fp[single(m, z)];
                    const source: i64 = if (kind == .from_signed) @as(i32, @bitCast(lane)) else lane;
                    const exact: f64 = @floatFromInt(source);
                    const value: T = @floatCast(exact);
                    const back: f64 = value;
                    const direction: i2 = if (exact > back) 1 else if (exact < back) -1 else 0;
                    const overflow = std.math.isInf(value);
                    lib.put(s, T, single(d, y), lib.raise(s, T, value, direction, overflow, false, if (overflow) lib.overflowed(T, exact) else 0));
                },
                .to_unsigned, .to_signed, .to_unsigned_round, .to_signed_round => {
                    const value = lib.get(s, T, single(m, z));
                    const rounded = if (kind == .to_unsigned or kind == .to_signed) @trunc(value) else lib.nearest(s, T, value);
                    const Int = if (kind == .to_unsigned or kind == .to_unsigned_round) u32 else i32;
                    s.fp[single(d, y)] = lib.integer(s, Int, T, value, rounded);
                },
                .from_half_low, .from_half_high => {
                    const lane = s.fp[single(m, z)];
                    const raw: u16 = @truncate(if (kind == .from_half_high) lane >> 16 else lane);
                    lib.put(s, T, single(d, y), lib.fromHalf(s, T, raw));
                },
                .to_half_low, .to_half_high => {
                    const d5 = single(d, y);
                    const half: u32 = lib.toHalf(s, T, lib.get(s, T, single(m, z)));
                    s.fp[d5] = if (kind == .to_half_high) (s.fp[d5] & 0xffff) | (half << 16) else (s.fp[d5] & 0xffff_0000) | half;
                },
            }
            return .next;
        }
    };
}

/// VCVT between `T` and a fixed-point integer of `size` bits, in place.
pub fn Fixed(comptime to_fixed: bool, comptime signed: bool, comptime size: u8, comptime T: type) type {
    return struct {
        /// Converts Sd in place with the fraction bits the fields name.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, j: u32, i: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const Int = std.meta.Int(if (signed) .signed else .unsigned, size);
            const d5 = single(d, y);
            const places: i32 = @as(i32, size) - @as(i32, @intCast(i << 1 | j));
            const scale = std.math.ldexp(@as(f64, 1.0), places);
            if (to_fixed) {
                const value = lib.get(s, T, d5);
                const scaled: f64 = @as(f64, value) * scale;
                const held = lib.clamped(s, Int, f64, scaled, @trunc(scaled), lib.signalling(T, value));
                lib.store(s, f32, d5, if (signed) @bitCast(@as(i32, held)) else @as(u32, held));
            } else {
                const source: Int = @bitCast(@as(std.meta.Int(.unsigned, size), @truncate(lib.word(s, f32, d5))));
                const exact: f64 = @as(f64, @floatFromInt(source)) / scale;
                const answer: T = @floatCast(exact);
                if (std.math.isInf(answer)) {
                    s.fpscr |= lib.ofc | lib.ixc;
                    lib.put(s, T, d5, answer);
                } else if (exact != 0 and @abs(exact) < std.math.floatMin(T) and s.fpscr & lib.flushed(T) != 0) {
                    s.fpscr |= lib.ufc;
                    lib.put(s, T, d5, if (std.math.signbit(exact)) -@as(T, 0.0) else 0.0);
                } else {
                    const inexact = @as(f64, answer) != exact;
                    const under: u32 = if (inexact and @abs(exact) < std.math.floatMin(T)) lib.ufc else 0;
                    lib.put(s, T, d5, lib.raise(s, T, answer, 0, false, false, under | (if (inexact) lib.ixc else 0)));
                }
            }
            return .next;
        }
    };
}

fn compared(s: *State, comptime T: type, x: T, y: T, comptime ordered: bool) Outcome {
    const unordered = std.math.isNan(x) or std.math.isNan(y);
    s.fpscr |= lib.signalling(T, x) | lib.signalling(T, y) | (if (ordered and unordered) lib.ioc else 0);
    const flags: u32 = if (unordered)
        0x3000_0000
    else if (x == y)
        0x6000_0000
    else if (x < y)
        0x8000_0000
    else
        0x2000_0000;
    s.fpscr = (s.fpscr & ~lib.nzcv) | flags;
    return .next;
}

/// VCMP and VCMPE of two registers, writing FPSCR NZCV.
pub fn Compare(comptime ordered: bool, comptime T: type) type {
    return struct {
        /// Compares Sd with Sm into FPSCR NZCV.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const x = lib.get(s, T, single(d, y));
            return compared(s, T, x, lib.get(s, T, single(m, z)), ordered);
        }
    };
}

/// VCMP and VCMPE against zero, writing FPSCR NZCV.
pub fn CompareZero(comptime ordered: bool, comptime T: type) type {
    return struct {
        /// Compares Sd with zero into FPSCR NZCV.
        pub fn call(s: *State, host: anytype, y: u32, d: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            return compared(s, T, lib.get(s, T, single(d, y)), 0, ordered);
        }
    };
}

/// VMOV (immediate) for a single or half register.
pub fn MoveImmediate(comptime T: type) type {
    return struct {
        /// Expands the immediate into Sd.
        pub fn call(s: *State, host: anytype, y: u32, i: u32, d: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            lib.store(s, T, single(d, y), lib.expandImm(T, i));
            return .next;
        }
    };
}

/// VMOV between a core register and a single-precision register.
pub fn Lane(comptime to_core: bool) type {
    return struct {
        /// Moves the word between Rt and Sn in the chosen direction.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, t: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            const at = single(d, y);
            if (to_core) root.set(s, t, s.fp[at]) else s.fp[at] = root.get(s, t);
            return .next;
        }
    };
}

/// VMOV between a core register and a register of `T`.
pub fn MoveCore(comptime to_core: bool, comptime T: type) type {
    return struct {
        /// Moves the value between Rt and Sn in the chosen direction.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, x: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const n5 = single(n, x);
            if (to_core) root.set(s, t, lib.word(s, T, n5)) else lib.store(s, T, n5, @truncate(root.get(s, t)));
            return .next;
        }
    };
}

/// VMOV between two core registers and two consecutive single registers.
pub fn MovePair(comptime to_core: bool) type {
    return struct {
        /// Moves two words between Rt, Rt2 and Sm, Sm+1.
        pub fn call(s: *State, host: anytype, e: u32, t: u32, z: u32, m: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            const m5 = single(m, z);
            if (to_core) {
                root.set(s, t, s.fp[m5]);
                root.set(s, e, s.fp[m5 +% 1]);
            } else {
                s.fp[m5] = root.get(s, t);
                s.fp[m5 +% 1] = root.get(s, e);
            }
            return .next;
        }
    };
}

/// VMOV between two core registers and a double register.
pub fn MoveDouble(comptime to_core: bool) type {
    return struct {
        /// Moves two words between Rt, Rt2 and Dm.
        pub fn call(s: *State, host: anytype, e: u32, t: u32, z: u32, m: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            const low: u5 = @truncate((z << 4 | m) * 2);
            if (to_core) {
                root.set(s, t, s.fp[low]);
                root.set(s, e, s.fp[low +% 1]);
            } else {
                s.fp[low] = root.get(s, t);
                s.fp[low +% 1] = root.get(s, e);
            }
            return .next;
        }
    };
}

fn moved(s: *State, host: anytype, comptime T: type, comptime load: bool, d: u5, at: u32) Outcome {
    lib.transfer(root.Host(@TypeOf(host)), s, host, T, load, d, at) catch |err| return Outcome.faulted(err);
    return .next;
}

/// VLDR and VSTR for a single or half register at an immediate offset.
pub fn LoadStore(comptime load: bool, comptime T: type) type {
    return struct {
        /// Transfers Sd at Rn plus or minus the scaled offset.
        pub fn call(s: *State, host: anytype, u: u32, y: u32, n: u32, d: u32, i: u32) Outcome {
            if (fitted(s, host, T)) |outcome| return outcome;
            const offset = i * @bitSizeOf(T) / 8;
            return moved(s, host, T, load, single(d, y), lib.literal(s, @intCast(n)) +% (if (u == 1) offset else 0 -% offset));
        }
    };
}

/// VLDR and VSTR for a double register at an immediate offset.
pub fn LoadStoreDouble(comptime load: bool) type {
    return struct {
        /// Transfers Dd at Rn plus or minus the scaled offset.
        pub fn call(s: *State, host: anytype, u: u32, n: u32, d: u32, i: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            const offset = i * 4;
            return moved(s, host, f64, load, double(d), lib.literal(s, @intCast(n)) +% (if (u == 1) offset else 0 -% offset));
        }
    };
}

fn block(s: *State, host: anytype, comptime T: type, comptime load: bool, comptime decrement: bool, n: u32, first: u5, total: u32, w: u32) Outcome {
    const words = @bitSizeOf(T) / 32;
    const count: u32 = @min(total / words, (root.instruction.registers - @as(u32, first)) / words);
    const span = total * 4;
    const base = root.get(s, n);
    var at = if (decrement) base -% span else base;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        switch (moved(s, host, T, load, @truncate(first + i * words), at)) {
            .next => {},
            else => |bad| return bad,
        }
        at +%= 4 * words;
    }
    if (decrement or w == 1) root.set(s, n, if (decrement) base -% span else base +% span);
    return .next;
}

/// VLDM and VSTM of single registers, incrementing; `top` fixes high n bits.
pub fn Block(comptime load: bool, comptime top: u4) type {
    return struct {
        /// Transfers the run of single registers from Rn, writing back when W is set.
        pub fn call(s: *State, host: anytype, y: u32, w: u32, n: u32, d: u32, i: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f32, load, false, top + n, single(d, y), i, w);
        }
    };
}

/// VLDM and VSTM of single registers with the base fixed at r14.
pub fn BlockTop(comptime load: bool) type {
    return struct {
        /// Transfers the run of single registers from lr, writing back when W is set.
        pub fn call(s: *State, host: anytype, y: u32, w: u32, d: u32, i: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f32, load, false, 14, single(d, y), i, w);
        }
    };
}

/// VLDMDB, VSTMDB, VPUSH and VPOP of single registers: decrementing, always writing back.
pub fn BlockBack(comptime load: bool) type {
    return struct {
        /// Transfers the run of single registers below Rn and lowers it.
        pub fn call(s: *State, host: anytype, y: u32, n: u32, d: u32, i: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f32, load, true, n, single(d, y), i, 0);
        }
    };
}

/// VLDM and VSTM of double registers, incrementing; `top` fixes high n bits.
pub fn BlockDouble(comptime load: bool, comptime top: u4) type {
    return struct {
        /// Transfers the run of double registers from Rn, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, n: u32, d: u32, i: u32, x: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f64, load, false, top + n, double(d), i << 1 | x, w);
        }
    };
}

/// VLDM and VSTM of double registers with the base fixed at r14.
pub fn BlockDoubleTop(comptime load: bool) type {
    return struct {
        /// Transfers the run of double registers from lr, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, d: u32, i: u32, x: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f64, load, false, 14, double(d), i << 1 | x, w);
        }
    };
}

/// VLDMDB, VSTMDB, VPUSH and VPOP of double registers: decrementing, always writing back.
pub fn BlockDoubleBack(comptime load: bool) type {
    return struct {
        /// Transfers the run of double registers below Rn and lowers it.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, i: u32, x: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            return block(s, host, f64, load, true, n, double(d), i << 1 | x, 0);
        }
    };
}

/// VMRS and VMSR: FPSCR to or from a core register; VMRS APSR_nzcv copies the flags.
pub fn Status(comptime to_core: bool) type {
    return struct {
        /// Moves FPSCR to or from Rt.
        pub fn call(s: *State, host: anytype, t: u32) Outcome {
            if (entered(s, host)) |outcome| return outcome;
            if (!to_core) {
                s.fpscr = lib.written(root.Host(@TypeOf(host)), host, root.get(s, t));
            } else if (t == 15) {
                s.xpsr = (s.xpsr & ~lib.nzcv) | (s.fpscr & lib.nzcv);
            } else {
                root.set(s, t, s.fpscr);
            }
            return .next;
        }
    };
}

fn fitted(s: *State, host: anytype, comptime T: type) ?Outcome {
    if (T == f64 and !host.doublePrecision()) return .undefined;
    if (T == f16 and !host.halfPrecision()) return .undefined;
    return entered(s, host);
}

fn latest(s: *State, host: anytype, comptime T: type) ?Outcome {
    if (!host.fpv5()) return .undefined;
    return fitted(s, host, T);
}

/// VADD, VSUB, VMUL, VNMUL and VDIV for double registers.
pub fn BinaryDouble(comptime kind: lib.Arithmetic) type {
    return struct {
        /// Computes the operation on Dn and Dm into Dd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const answer = lib.arithmetic(s, kind, f64, lib.get(s, f64, double(n)), lib.get(s, f64, double(m)));
            lib.put(s, f64, double(d), if (kind == .nmul) -answer else answer);
            return .next;
        }
    };
}

/// VMLA, VMLS, VFMA, VFMS and their negated forms for double registers.
pub fn FusedDouble(comptime kind: lib.Accumulate) type {
    return struct {
        /// Accumulates Dn * Dm into Dd by the kind.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const d5 = double(d);
            const a = lib.get(s, f64, double(n));
            const b = lib.get(s, f64, double(m));
            lib.put(s, f64, d5, lib.accumulate(s, kind, f64, a, b, lib.get(s, f64, d5)));
            return .next;
        }
    };
}

/// VMOV, VABS, VNEG and VSQRT for double registers.
pub fn UnaryDouble(comptime kind: lib.Simple) type {
    return struct {
        /// Applies the unary operation to Dm into Dd.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const m5 = double(m);
            const d5 = double(d);
            const top: u64 = 1 << 63;
            switch (kind) {
                .move => lib.store(s, f64, d5, lib.word(s, f64, m5)),
                .abs => lib.store(s, f64, d5, lib.word(s, f64, m5) & ~top),
                .negate => lib.store(s, f64, d5, lib.word(s, f64, m5) ^ top),
                .root => {
                    const value = lib.get(s, f64, m5);
                    const answer = @sqrt(value);
                    lib.put(s, f64, d5, lib.raise(s, f64, answer, lib.root(f64, value, answer), false, std.math.isNan(value), lib.signalling(f64, value)));
                },
            }
            return .next;
        }
    };
}

/// VCMP and VCMPE of two double registers.
pub fn CompareDouble(comptime ordered: bool) type {
    return struct {
        /// Compares Dd with Dm into FPSCR NZCV.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const x = lib.get(s, f64, double(d));
            return compared(s, f64, x, lib.get(s, f64, double(m)), ordered);
        }
    };
}

/// VCMP and VCMPE of a double register against zero.
pub fn CompareZeroDouble(comptime ordered: bool) type {
    return struct {
        /// Compares Dd with zero into FPSCR NZCV.
        pub fn call(s: *State, host: anytype, d: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            return compared(s, f64, lib.get(s, f64, double(d)), 0, ordered);
        }
    };
}

/// VMOV (immediate) for a double register.
pub fn moveImmediateDouble(s: *State, host: anytype, i: u32, d: u32) Outcome {
    if (fitted(s, host, f64)) |outcome| return outcome;
    lib.store(s, f64, double(d), lib.expandImm(f64, i));
    return .next;
}

/// VCVT to double from an integer or half in a single register.
pub fn WidenToDouble(comptime kind: lib.Cast) type {
    return struct {
        /// Converts Sm into Dd by the cast kind.
        pub fn call(s: *State, host: anytype, d: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const lane = s.fp[single(m, z)];
            switch (kind) {
                .from_unsigned, .from_signed => {
                    const source: i64 = if (kind == .from_signed) @as(i32, @bitCast(lane)) else lane;
                    const value: f64 = @floatFromInt(source);
                    lib.put(s, f64, double(d), lib.raise(s, f64, value, 0, false, false, 0));
                },
                .from_half_low, .from_half_high => {
                    const raw: u16 = @truncate(if (kind == .from_half_high) lane >> 16 else lane);
                    lib.put(s, f64, double(d), lib.fromHalf(s, f64, raw));
                },
                else => unreachable,
            }
            return .next;
        }
    };
}

/// VCVT from double to an integer or half in a single register.
pub fn NarrowFromDouble(comptime kind: lib.Cast) type {
    return struct {
        /// Converts Dm into Sd by the cast kind.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, m: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const value = lib.get(s, f64, double(m));
            switch (kind) {
                .to_unsigned, .to_signed, .to_unsigned_round, .to_signed_round => {
                    const rounded = if (kind == .to_unsigned or kind == .to_signed) @trunc(value) else lib.nearest(s, f64, value);
                    const Int = if (kind == .to_unsigned or kind == .to_unsigned_round) u32 else i32;
                    s.fp[single(d, y)] = lib.integer(s, Int, f64, value, rounded);
                },
                .to_half_low, .to_half_high => {
                    const d5 = single(d, y);
                    const half: u32 = lib.toHalf(s, f64, value);
                    s.fp[d5] = if (kind == .to_half_high) (s.fp[d5] & 0xffff) | (half << 16) else (s.fp[d5] & 0xffff_0000) | half;
                },
                else => unreachable,
            }
            return .next;
        }
    };
}

/// VCVT.F64.F32: widens Sm into Dd.
pub fn widenDouble(s: *State, host: anytype, d: u32, z: u32, m: u32) Outcome {
    if (fitted(s, host, f64)) |outcome| return outcome;
    lib.put(s, f64, double(d), lib.widened(s, f32, f64, lib.get(s, f32, single(m, z))));
    return .next;
}

/// VCVT.F32.F64: narrows Dm into Sd.
pub fn narrowDouble(s: *State, host: anytype, y: u32, d: u32, m: u32) Outcome {
    if (fitted(s, host, f64)) |outcome| return outcome;
    lib.put(s, f32, single(d, y), lib.narrowed(s, f64, f32, lib.get(s, f64, double(m))));
    return .next;
}

/// VCVT between double and a fixed-point integer of `size` bits, in place.
pub fn FixedDouble(comptime to_fixed: bool, comptime signed: bool, comptime size: u8) type {
    return struct {
        /// Converts Dd in place with the fraction bits the fields name.
        pub fn call(s: *State, host: anytype, d: u32, j: u32, i: u32) Outcome {
            if (fitted(s, host, f64)) |outcome| return outcome;
            const Int = std.meta.Int(if (signed) .signed else .unsigned, size);
            const d5 = double(d);
            const places: i32 = @as(i32, size) - @as(i32, @intCast(i << 1 | j));
            if (to_fixed) {
                const value = lib.get(s, f64, d5);
                const scaled: f64 = value * std.math.ldexp(@as(f64, 1.0), places);
                const held = lib.clamped(s, Int, f64, scaled, @trunc(scaled), lib.signalling(f64, value));
                lib.store(s, f64, d5, if (signed) @bitCast(@as(i64, held)) else @as(u64, held));
            } else {
                const source: Int = @bitCast(@as(std.meta.Int(.unsigned, size), @truncate(lib.word(s, f64, d5))));
                const exact: f128 = @as(f128, @floatFromInt(source)) / std.math.ldexp(@as(f128, 1.0), places);
                const answer: f64 = @floatCast(exact);
                if (std.math.isInf(answer)) {
                    s.fpscr |= lib.ofc | lib.ixc;
                    lib.put(s, f64, d5, answer);
                } else if (exact != 0 and @abs(exact) < std.math.floatMin(f64) and s.fpscr & lib.flushed(f64) != 0) {
                    s.fpscr |= lib.ufc;
                    lib.put(s, f64, d5, if (std.math.signbit(exact)) -@as(f64, 0.0) else 0.0);
                } else {
                    const inexact = @as(f128, answer) != exact;
                    const under: u32 = if (inexact and @abs(exact) < std.math.floatMin(f64)) lib.ufc else 0;
                    lib.put(s, f64, d5, lib.raise(s, f64, answer, 0, false, false, under | (if (inexact) lib.ixc else 0)));
                }
            }
            return .next;
        }
    };
}

/// VMAXNM and VMINNM for double registers, FPv5 only.
pub fn ExtremumDouble(comptime largest: bool) type {
    return struct {
        /// Writes the larger or smaller of Dn and Dm into Dd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            if (latest(s, host, f64)) |outcome| return outcome;
            const x = lib.get(s, f64, double(n));
            const y = lib.get(s, f64, double(m));
            lib.put(s, f64, double(d), lib.extremum(s, f64, largest, x, y));
            return .next;
        }
    };
}

/// The VRINT rounding forms for double registers, FPv5 only.
pub fn RoundDouble(comptime kind: lib.Rounding) type {
    return struct {
        /// Rounds Dm to integral by the kind into Dd.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            if (latest(s, host, f64)) |outcome| return outcome;
            lib.put(s, f64, double(d), lib.integralOf(s, kind, f64, lib.get(s, f64, double(m))));
            return .next;
        }
    };
}

/// VCVTA, VCVTN, VCVTP and VCVTM from double to integer, FPv5 only.
pub fn FixDouble(comptime kind: lib.Rounding, comptime signed: bool) type {
    return struct {
        /// Rounds Dm by the kind and converts to a 32-bit integer in Sd.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, m: u32) Outcome {
            if (latest(s, host, f64)) |outcome| return outcome;
            const value = lib.get(s, f64, double(m));
            const Int = if (signed) i32 else u32;
            s.fp[single(d, y)] = lib.integer(s, Int, f64, value, lib.integral(s, f64, kind, value));
            return .next;
        }
    };
}

/// VSEL for double registers, FPv5 only.
pub fn SelectDouble(comptime cond: u4) type {
    return struct {
        /// Copies Dn or Dm into Dd by the condition.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            if (latest(s, host, f64)) |outcome| return outcome;
            const source = if (s.condition(cond)) double(n) else double(m);
            lib.store(s, f64, double(d), lib.word(s, f64, source));
            return .next;
        }
    };
}

/// VMAXNM and VMINNM for a single or half register, FPv5 only.
pub fn Extremum(comptime largest: bool, comptime T: type) type {
    return struct {
        /// Writes the larger or smaller of Sn and Sm into Sd.
        pub fn call(s: *State, host: anytype, y: u32, n: u32, d: u32, x: u32, z: u32, m: u32) Outcome {
            if (latest(s, host, T)) |outcome| return outcome;
            const a = lib.get(s, T, single(n, x));
            const b = lib.get(s, T, single(m, z));
            lib.put(s, T, single(d, y), lib.extremum(s, T, largest, a, b));
            return .next;
        }
    };
}

/// The VRINT rounding forms for a single or half register, FPv5 only.
pub fn Round(comptime kind: lib.Rounding, comptime T: type) type {
    return struct {
        /// Rounds Sm to integral by the kind into Sd.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (latest(s, host, T)) |outcome| return outcome;
            lib.put(s, T, single(d, y), lib.integralOf(s, kind, T, lib.get(s, T, single(m, z))));
            return .next;
        }
    };
}

/// VCVTA, VCVTN, VCVTP and VCVTM from `T` to integer, FPv5 only.
pub fn Fix(comptime kind: lib.Rounding, comptime signed: bool, comptime T: type) type {
    return struct {
        /// Rounds Sm by the kind and converts to a 32-bit integer in Sd.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (latest(s, host, T)) |outcome| return outcome;
            const value = lib.get(s, T, single(m, z));
            const Int = if (signed) i32 else u32;
            s.fp[single(d, y)] = lib.integer(s, Int, T, value, lib.integral(s, T, kind, value));
            return .next;
        }
    };
}

/// VSEL for a single or half register, FPv5 only.
pub fn Select(comptime cond: u4, comptime T: type) type {
    return struct {
        /// Copies Sn or Sm into Sd by the condition.
        pub fn call(s: *State, host: anytype, y: u32, n: u32, d: u32, x: u32, z: u32, m: u32) Outcome {
            if (latest(s, host, T)) |outcome| return outcome;
            const source = if (s.condition(cond)) single(n, x) else single(m, z);
            lib.store(s, T, single(d, y), lib.word(s, T, source));
            return .next;
        }
    };
}

/// VINS and VMOVX: move the top half of a single register in or out.
pub fn Halves(comptime insert: bool) type {
    return struct {
        /// Inserts Sm's low half into Sd's top, or extracts Sm's top half.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, z: u32, m: u32) Outcome {
            if (fitted(s, host, f16)) |outcome| return outcome;
            const d5 = single(d, y);
            const source = s.fp[single(m, z)];
            s.fp[d5] = if (insert) (s.fp[d5] & 0xffff) | (source << 16) else source >> 16;
            return .next;
        }
    };
}

fn registerOf(comptime fixed: ?lib.SystemRegister, k: u32) lib.SystemRegister {
    if (comptime fixed) |which| return which;
    return switch (k) {
        0 => .vpr,
        1 => .p0,
        2 => .fpcxt_ns,
        else => .fpcxt_s,
    };
}

fn reached(s: *State, host: anytype, which: lib.SystemRegister, inactive: bool) ?Outcome {
    return lib.reachSystem(root.Host(@TypeOf(host)), s, host, which, inactive) catch |err| return Outcome.faulted(err);
}

/// VMRS and VMSR of VPR, P0, FPCXT_NS and FPCXT_S.
pub fn SystemMove(comptime to_core: bool, comptime which: lib.SystemRegister) type {
    return struct {
        /// Moves the system register to or from Rt.
        pub fn call(s: *State, host: anytype, t: u32) Outcome {
            const Host = root.Host(@TypeOf(host));
            if (lib.context(which) and !s.secure) return .undefined;
            const inactive = lib.contextInactive(Host, s, host);
            if (reached(s, host, which, inactive)) |outcome| return outcome;
            if (to_core) {
                root.set(s, t, lib.systemWord(Host, s, host, which, inactive));
                lib.afterSystemWrite(Host, s, host, which, inactive);
            } else lib.takeSystem(Host, s, host, which, root.get(s, t), inactive);
            return .next;
        }
    };
}

fn accessed(s: *State, host: anytype, comptime load: bool, comptime indexed: bool, which: lib.SystemRegister, u: u32, w: u32, n: u32, i: u32) Outcome {
    const Host = root.Host(@TypeOf(host));
    if (lib.context(which) and !s.secure) return .undefined;
    const inactive = lib.contextInactive(Host, s, host);
    if (reached(s, host, which, inactive)) |outcome| return outcome;
    const offset = i * 4;
    const stepped = if (u == 1) root.get(s, n) +% offset else root.get(s, n) -% offset;
    const at = if (indexed) stepped else root.get(s, n);
    if (load) {
        const value = root.read(host, at, 32, false, true) catch |err| return Outcome.faulted(err);
        lib.takeSystem(Host, s, host, which, value, inactive);
    } else {
        root.write(host, at, 32, lib.systemWord(Host, s, host, which, inactive), true) catch |err| return Outcome.faulted(err);
        lib.afterSystemWrite(Host, s, host, which, inactive);
    }
    if (!indexed or w == 1) root.set(s, n, stepped);
    return .next;
}

/// VLDR and VSTR of a fixed system register with pre-index or offset addressing.
pub fn SystemFixed(comptime load: bool, comptime which: lib.SystemRegister) type {
    return struct {
        /// Transfers the system register at Rn plus or minus the offset.
        pub fn call(s: *State, host: anytype, u: u32, w: u32, n: u32, i: u32) Outcome {
            return accessed(s, host, load, true, which, u, w, n, i);
        }
    };
}

/// VLDR and VSTR of a system register named by a field, pre-index or offset.
pub fn SystemBanked(comptime load: bool) type {
    return struct {
        /// Transfers the named system register at Rn plus or minus the offset.
        pub fn call(s: *State, host: anytype, u: u32, w: u32, n: u32, k: u32, i: u32) Outcome {
            return accessed(s, host, load, true, registerOf(null, k), u, w, n, i);
        }
    };
}

/// VLDR and VSTR of a fixed system register, post-indexed.
pub fn SystemFixedPost(comptime load: bool, comptime which: lib.SystemRegister) type {
    return struct {
        /// Transfers the system register at Rn, then moves Rn.
        pub fn call(s: *State, host: anytype, u: u32, n: u32, i: u32) Outcome {
            return accessed(s, host, load, false, which, u, 0, n, i);
        }
    };
}

/// VLDR and VSTR of a field-named system register, post-indexed.
pub fn SystemBankedPost(comptime load: bool) type {
    return struct {
        /// Transfers the named system register at Rn, then moves Rn.
        pub fn call(s: *State, host: anytype, u: u32, n: u32, k: u32, i: u32) Outcome {
            return accessed(s, host, load, false, registerOf(null, k), u, 0, n, i);
        }
    };
}

/// VLLDM and VLSTM: the Secure lazy floating-point context save and restore.
pub fn Lazy(comptime load: bool) type {
    return struct {
        /// Saves or restores the FP context at Rn, or arms lazy preservation.
        pub fn call(s: *State, host: anytype, n: u32) Outcome {
            const Host = root.Host(@TypeOf(host));
            if (!host.security() or !s.secure) return .undefined;
            if (s.control & State.control_sfpa == 0) return .next;
            if (!host.coprocessorEnabled()) return .no_coprocessor;
            const frame = root.get(s, n);
            const owed = host.lazyFpFrame() != null;
            if (!load and frame % 8 != 0) return .unaligned;
            if (load and owed) {
                host.setLazyFp(null);
            } else if (!load and host.lazyFpEnabled()) {
                host.setLazyFp(frame);
            } else {
                if (frame % 8 != 0) return .unaligned;
                const callee = host.lazyFpCallee();
                lib.transferFrame(Host, s, host, frame, load, callee) catch |err| return Outcome.faulted(err);
                if (!load) lib.invalidate(s, callee);
            }
            if (load) s.control |= State.control_fpca else s.control &= ~State.control_fpca;
            return .next;
        }
    };
}

/// VSCCLRM: clears a run of floating-point registers and VPR in Secure state.
pub fn Clear(comptime wide: bool) type {
    return struct {
        /// Zeroes the named registers and VPR when the FP context is active.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, i: u32) Outcome {
            if (!host.security() or !s.secure) return .undefined;
            if (!host.automaticFpState() or s.control & State.control_sfpa != 0) {
                if (entered(s, host)) |outcome| return outcome;
                const first: u32 = if (wide) y << 5 | d << 1 else d << 1 | y;
                const last = @min(first + (if (wide) i << 1 else i), root.instruction.registers);
                var at = first;
                while (at < last) : (at += 1) s.fp[at] = 0;
                s.vpr = 0;
            }
            return .next;
        }
    };
}
