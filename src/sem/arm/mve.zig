//! Semantics of the Armv8.1-M MVE vector instructions. Each `pub fn` returning a
//! type is a comptime constructor whose `call` executes one decoded encoding
//! against the machine state through the host; src/sem/arm/root.zig binds
//! them to the rows in src/arm/isa/mve.zig. Each entry runs the floating-point
//! context check, applies the VPR predicate and tail count per lane, and
//! advances the VPT block masks on the way out.

const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const fp = @import("../../arm/isa/fp.zig");

/// The MVE encoding tables and lane helpers.
pub const lib = @import("../../arm/isa/mve.zig");

const Entry = union(enum) { refused: Outcome, opened: bool };

fn enter(s: *State, host: anytype) Entry {
    if (!host.mve()) return .{ .refused = .undefined };
    const checked = fp.check(root.Host(@TypeOf(host)), s, host) catch |err| return .{ .refused = Outcome.faulted(err) };
    if (checked) |outcome| return .{ .refused = outcome };
    return .{ .opened = s.vpr & (lib.mask01 | lib.mask23) != 0 };
}

fn leave(s: *State, blocked: bool) Outcome {
    if (blocked) lib.advance(s);
    return .next;
}

/// Integer three-operand lane instruction: VADD, VSUB, VMUL, the bitwise set and the halving and saturating set.
pub fn Lanewise(comptime op: lib.Op, comptime esize: u8, comptime signed: bool, comptime scalar: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, x: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const other = if (scalar) root.get(s, x) else 0;
            var saturated = false;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const second = if (scalar) other else lib.lane(s, @intCast(x), esize, at);
                var sat = false;
                const value = lib.apply(op, esize, signed, lib.lane(s, @intCast(n), esize, at), second, &sat);
                if (sat and lib.active(mask, esize, at)) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, at, value);
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VMLA when swapped is false, VMLAS when true: lane times scalar or destination, plus the other.
pub fn Accumulate(comptime esize: u8, comptime swapped: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, t: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const scalar = lib.widened(esize, true, root.get(s, t));
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const first = lib.widened(esize, true, lib.lane(s, @intCast(n), esize, at));
                const held = lib.widened(esize, true, lib.lane(s, @intCast(d), esize, at));
                const value = if (swapped) first * held + scalar else first * scalar + held;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(value))));
            }
            return leave(s, blocked);
        }
    };
}

/// VMLA with the unused leading field dropped.
pub fn AccumulateFree(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, _: u32, n: u32, d: u32, t: u32) Outcome {
            return Accumulate(esize, false).call(s, host, n, d, t);
        }
    };
}

/// VDUP: fills every lane with a core register.
pub fn Dup(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, t: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const value = root.get(s, t);
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                lib.merge(s, mask, @intCast(d), esize, at, value);
            }
            return leave(s, blocked);
        }
    };
}

/// Integer VPT and VCMP: writes the P0 predicate and opens a VPT block when k names one.
pub fn Compare(comptime esize: u8, comptime scalar: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, c: u32, x: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const bytes = esize / 8;
            const other = if (scalar) lib.scalarOf(s, @intCast(x)) else 0;
            var flags: u32 = 0;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                const second = if (scalar) other else lib.lane(s, @intCast(x), esize, at);
                if (lib.holds(@enumFromInt(c), esize, lib.lane(s, @intCast(n), esize, at), second)) flags |= ((@as(u32, 1) << bytes) - 1) << @intCast(at * bytes);
            }
            s.vpr = (s.vpr & ~lib.p0) | (flags & mask);
            if (k != 0) s.vpr = (s.vpr & ~(lib.mask01 | lib.mask23)) | (k * 0x0011_0000);
            return leave(s, blocked);
        }
    };
}

const std = @import("std");
const wide = @import("../../arm/isa/t32_wide.zig");

/// One-source lane instruction: VABS, VNEG, VQABS, VQNEG, VCLS, VCLZ or VMVN.
pub fn Solo(comptime op: lib.Single, comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const Unsigned = std.meta.Int(.unsigned, esize);
            const high: i64 = (@as(i64, 1) << (esize - 1)) - 1;
            var saturated = false;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const raw: Unsigned = @truncate(lib.lane(s, @intCast(m), esize, at));
                const x = lib.widened(esize, true, raw);
                var sat = false;
                const value: i64 = switch (op) {
                    .abs => @intCast(@abs(x)),
                    .neg => -x,
                    .qabs => lib.clamped(@as(i64, @intCast(@abs(x))), -high - 1, high, &sat),
                    .qneg => lib.clamped(-x, -high - 1, high, &sat),
                    .cls => @clz(if (raw >> (esize - 1) != 0) ~raw else raw) - 1,
                    .clz => @clz(raw),
                    .mvn => ~@as(i64, raw),
                };
                if (sat and lib.active(mask, esize, at)) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(value))));
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VREV16, VREV32 and VREV64: reverses the elements within each chunk.
pub fn Reverse(comptime esize: u8, comptime chunk: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                lib.merge(s, mask, @intCast(d), esize, at, lib.lane(s, @intCast(m), esize, at ^ (chunk / esize - 1)));
            }
            return leave(s, blocked);
        }
    };
}

fn variable(s: *State, comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, source: u32, d: u32, amounts: u32, comptime scalar: bool) void {
    const mask = lib.predicate(s);
    const shared: i32 = if (scalar) @as(i8, @bitCast(@as(u8, @truncate(root.get(s, amounts))))) else 0;
    var saturated = false;
    for (0..128 / esize) |i| {
        const at: u32 = @intCast(i);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const amount: i32 = if (scalar) shared else @as(i8, @bitCast(@as(u8, @truncate(lib.lane(s, @intCast(amounts), esize, at)))));
        var sat = false;
        const value = lib.slid(esize, esize, signed, rounding, saturating, false, lib.lane(s, @intCast(source), esize, at), amount, &sat);
        if (sat and lib.active(mask, esize, at)) saturated = true;
        lib.merge(s, mask, @intCast(d), esize, at, value);
    }
    if (saturated) s.fpscr |= fp.qc;
}

/// VSHL, VRSHL, VQSHL and VQRSHL by a vector of signed byte amounts.
pub fn Variable(comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            variable(s, esize, signed, rounding, saturating, m, d, n, false);
            return leave(s, blocked);
        }
    };
}

/// VSHL, VRSHL, VQSHL and VQRSHL by one signed byte amount from a core register.
pub fn VariableScalar(comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, t: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            variable(s, esize, signed, rounding, saturating, d, d, t, true);
            return leave(s, blocked);
        }
    };
}

/// Immediate shifts: VSHL, VSHR, VRSHR, VQSHL and VQSHLU.
pub fn Immediate(comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, comptime unsigned: bool, comptime left: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const amount: i32 = if (left) @intCast(i) else @as(i32, @intCast(i)) - esize;
            var saturated = false;
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                var sat = false;
                const value = lib.slid(esize, esize, signed, rounding, saturating, unsigned, lib.lane(s, @intCast(m), esize, at), amount, &sat);
                if (sat and lib.active(mask, esize, at)) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, at, value);
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VSLI and VSRI: shifts in, keeping the destination bits the shift did not reach.
pub fn Insert(comptime esize: u8, comptime left: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const places: u6 = if (left) @intCast(i) else @as(u6, esize) - @as(u6, @intCast(i));
            const width = (@as(u64, 1) << esize) - 1;
            const kept: u64 = if (left) (@as(u64, 1) << places) - 1 else ~((@as(u64, 1) << @intCast(@as(u8, esize) - places)) - 1) & width;
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const source: u64 = lib.lane(s, @intCast(m), esize, at);
                const moved = if (left) source << places else source >> places;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate((moved & ~kept) | (lib.lane(s, @intCast(d), esize, at) & kept)));
            }
            return leave(s, blocked);
        }
    };
}

/// VBRSR: reverses the low bits of each element and clears the rest.
pub fn BitReverse(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, t: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const places = @min(root.get(s, t) & 0xff, esize);
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const source = lib.lane(s, @intCast(n), esize, at);
                var value: u32 = 0;
                for (0..places) |b| value |= (source >> @intCast(b) & 1) << @intCast(places - 1 - b);
                lib.merge(s, mask, @intCast(d), esize, at, value);
            }
            return leave(s, blocked);
        }
    };
}

/// VSHLC: shifts the whole register left as one number, carrying through Rdm.
pub fn carry(s: *State, host: anytype, i: u32, d: u32, t: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const places: u6 = if (i == 0) 32 else @intCast(i);
    var held: u64 = root.get(s, t);
    for (0..4) |word| {
        const value: u64 = s.fp[d * 4 + word];
        const moved = (value << places) | (held & ((@as(u64, 1) << places) - 1));
        const out: u32 = @truncate(value >> @intCast(32 - places));
        for (0..4) |byte| {
            const at: u32 = @intCast(word * 4 + byte);
            if (lib.active(mask, 8, at)) lib.setLane(s, @intCast(d), 8, at, @truncate(moved >> @intCast(byte * 8)));
        }
        if (lib.active(mask, 8, @intCast(word * 4))) held = out;
    }
    root.set(s, t, @truncate(held));
    return leave(s, blocked);
}

fn longPair(s: *State, comptime kind: wide.LongShift, comptime odd: u4, a: u32, d: u32, amount: i32, to: u9) Outcome {
    const hi: u32 = d * 2 + odd;
    const lo: u32 = a * 2;
    var q = false;
    const result = wide.longShift(kind, 64, @as(u64, root.get(s, hi)) << 32 | root.get(s, lo), amount, to, &q);
    root.set(s, hi, @truncate(result >> 32));
    root.set(s, lo, @truncate(result));
    if (q) s.xpsr |= State.flag_q;
    return .next;
}

/// Register-pair shifts by immediate: ASRL, LSLL, LSRL, SQSHLL, SRSHRL, UQSHLL and URSHRL.
pub fn LongPairImmediate(comptime kind: wide.LongShift, comptime odd: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, i: u32, d: u32) Outcome {
            if (!host.mve()) return .undefined;
            return longPair(s, kind, odd, a, d, if (i == 0) 32 else @intCast(i), 64);
        }
    };
}

/// ASRL and LSLL of a register pair by a signed byte amount.
pub fn LongPairRegister(comptime kind: wide.LongShift, comptime odd: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, m: u32, d: u32) Outcome {
            if (!host.mve()) return .undefined;
            return longPair(s, kind, odd, a, d, @as(i8, @bitCast(@as(u8, @truncate(root.get(s, m))))), 64);
        }
    };
}

/// SQRSHRL and UQRSHLL: saturating rounding pair shifts, limited to 48 bits when asked.
pub fn LongPairLimited(comptime kind: wide.LongShift, comptime odd: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, m: u32, d: u32, q: u32) Outcome {
            if (!host.mve()) return .undefined;
            return longPair(s, kind, odd, a, d, @as(i8, @bitCast(@as(u8, @truncate(root.get(s, m))))), if (q == 0) 64 else 48);
        }
    };
}

fn longOne(s: *State, comptime kind: wide.LongShift, n: u32, amount: i32) Outcome {
    var q = false;
    const result = wide.longShift(kind, 32, root.get(s, n), amount, 32, &q);
    root.set(s, n, @truncate(result));
    if (q) s.xpsr |= State.flag_q;
    return .next;
}

/// Single-register shifts by immediate: SQSHL, SRSHR, UQSHL and URSHR.
pub fn LongOneImmediate(comptime kind: wide.LongShift) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, i: u32) Outcome {
            if (!host.mve()) return .undefined;
            return longOne(s, kind, n, if (i == 0) 32 else @intCast(i));
        }
    };
}

/// SQRSHR and UQRSHL: saturating rounding shifts of one register by a signed byte amount.
pub fn LongOneRegister(comptime kind: wide.LongShift) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, m: u32) Outcome {
            if (!host.mve()) return .undefined;
            return longOne(s, kind, n, @as(i8, @bitCast(@as(u8, @truncate(root.get(s, m))))));
        }
    };
}

fn contiguous(s: *State, host: anytype, comptime load: bool, comptime msize: u8, comptime esize: u8, comptime indexed: bool, unsigned: bool, a: u32, w: u32, n: u32, d: u32, i: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const stride = msize / 8;
    const span = i * stride;
    const base = root.get(s, n);
    const start = if (indexed) (if (a == 1) base +% span else base -% span) else base;
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (!lib.active(mask, esize, at)) {
            if (load) lib.setLane(s, @intCast(d), esize, at, 0);
            continue;
        }
        const address = start +% at * stride;
        if (load) {
            const raw = root.read(host, address, msize, false, true) catch |err| return Outcome.faulted(err);
            lib.setLane(s, @intCast(d), esize, at, if (msize == esize or unsigned) raw else lib.extend(msize, raw));
        } else {
            root.write(host, address, msize, lib.lane(s, @intCast(d), esize, at), true) catch |err| return Outcome.faulted(err);
        }
    }
    if (!indexed or w == 1) root.set(s, n, if (a == 1) base +% span else base -% span);
    return leave(s, blocked);
}

/// Contiguous VLDR and VSTR, post-indexed: accesses at the base, then writes it back.
pub fn Contiguous(comptime load: bool, comptime msize: u8, comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, n: u32, d: u32, i: u32) Outcome {
            return contiguous(s, host, load, msize, esize, false, msize == esize, a, 1, n, d, i);
        }
    };
}

/// Contiguous VLDR and VSTR with an offset, writing the base back when W is set.
pub fn ContiguousIndexed(comptime load: bool, comptime msize: u8, comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, w: u32, n: u32, d: u32, i: u32) Outcome {
            return contiguous(s, host, load, msize, esize, true, msize == esize, a, w, n, d, i);
        }
    };
}

/// Widening VLDR, post-indexed, extending each element as U says.
pub fn ContiguousWide(comptime msize: u8, comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, u: u32, a: u32, n: u32, d: u32, i: u32) Outcome {
            return contiguous(s, host, true, msize, esize, false, u == 1, a, 1, n, d, i);
        }
    };
}

/// Widening VLDR with an offset, extending each element as U says.
pub fn ContiguousWideIndexed(comptime msize: u8, comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, u: u32, a: u32, w: u32, n: u32, d: u32, i: u32) Outcome {
            return contiguous(s, host, true, msize, esize, true, u == 1, a, w, n, d, i);
        }
    };
}

fn scattered(s: *State, host: anytype, comptime load: bool, comptime msize: u8, comptime esize: u8, comptime unsigned: bool, comptime scale: u5, n: u32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        const from = lib.lane(s, @intCast(m), esize, at);
        if (!lib.active(mask, esize, at)) {
            if (load) lib.setLane(s, @intCast(d), esize, at, 0);
            continue;
        }
        const address = root.get(s, n) +% (from << scale);
        if (load) {
            const raw = root.read(host, address, msize, false, true) catch |err| return Outcome.faulted(err);
            lib.setLane(s, @intCast(d), esize, at, if (msize == esize or unsigned) raw else lib.extend(msize, raw));
        } else {
            root.write(host, address, msize, lib.lane(s, @intCast(d), esize, at), true) catch |err| return Outcome.faulted(err);
        }
    }
    return leave(s, blocked);
}

/// VLDR and VSTR with a vector of offsets, scaled when the encoding asks.
pub fn Scattered(comptime load: bool, comptime msize: u8, comptime esize: u8, comptime unsigned: bool, comptime scale: u5) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            return scattered(s, host, load, msize, esize, unsigned, scale, n, d, m);
        }
    };
}

/// VLDRB and VSTRB with a vector of byte offsets.
pub fn ScatteredByte(comptime load: bool, comptime esize: u8, comptime unsigned: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32, _: u32) Outcome {
            return scattered(s, host, load, 8, esize, unsigned, 0, n, d, m);
        }
    };
}

/// VLDRW and VSTRW at a vector of addresses plus an immediate, written back when W is set.
pub fn ScatteredOffset(comptime load: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, w: u32, m: u32, d: u32, i: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const span = i * 4;
            for (0..4) |k| {
                const at: u32 = @intCast(k);
                const from = lib.lane(s, @intCast(m), 32, at);
                if (!lib.active(mask, 32, at)) {
                    if (load) lib.setLane(s, @intCast(d), 32, at, 0);
                    continue;
                }
                const address = if (a == 1) from +% span else from -% span;
                if (load) {
                    const raw = root.read(host, address, 32, false, true) catch |err| return Outcome.faulted(err);
                    lib.setLane(s, @intCast(d), 32, at, raw);
                } else {
                    root.write(host, address, 32, lib.lane(s, @intCast(d), 32, at), true) catch |err| return Outcome.faulted(err);
                }
            }
            if (w == 1) {
                for (0..4) |k| {
                    const at: u32 = @intCast(k);
                    const from = lib.lane(s, @intCast(m), 32, at);
                    lib.setLane(s, @intCast(m), 32, at, if (a == 1) from +% span else from -% span);
                }
            }
            return leave(s, blocked);
        }
    };
}

fn couples(s: *State, host: anytype, comptime load: bool, mask: u32, d: u32, address: u32, couple: u32) ?Outcome {
    for (0..2) |half| {
        const word: u32 = couple * 2 + @as(u32, @intCast(half));
        if (!lib.active(mask, 32, word)) {
            if (load) lib.setLane(s, @intCast(d), 32, word, 0);
            continue;
        }
        const at = address +% @as(u32, @intCast(half)) * 4;
        if (load) {
            const raw = root.read(host, at, 32, false, true) catch |err| return Outcome.faulted(err);
            lib.setLane(s, @intCast(d), 32, word, raw);
        } else {
            root.write(host, at, 32, lib.lane(s, @intCast(d), 32, word), true) catch |err| return Outcome.faulted(err);
        }
    }
    return null;
}

/// VLDRD and VSTRD: each 64-bit lane at the base plus its scaled offset.
pub fn Paired(comptime load: bool, comptime scale: u5) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            for (0..2) |k| {
                const couple: u32 = @intCast(k);
                const from = lib.lane(s, @intCast(m), 32, couple * 2);
                if (couples(s, host, load, mask, d, root.get(s, n) +% (from << scale), couple)) |bad| return bad;
            }
            return leave(s, blocked);
        }
    };
}

/// VLDRD and VSTRD at a vector of addresses plus an immediate, written back when W is set.
pub fn PairedOffset(comptime load: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, a: u32, w: u32, m: u32, d: u32, i: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const span = i * 8;
            for (0..2) |k| {
                const couple: u32 = @intCast(k);
                const from = lib.lane(s, @intCast(m), 32, couple * 2);
                const moved = if (a == 1) from +% span else from -% span;
                if (couples(s, host, load, mask, d, moved, couple)) |bad| return bad;
                if (w == 1) lib.setLane(s, @intCast(m), 32, couple * 2, moved);
            }
            return leave(s, blocked);
        }
    };
}

/// VLD2, VLD4, VST2 and VST4: one beat of a de-interleaving structure load or store.
pub fn Interleaved(comptime load: bool, comptime esize: u8, comptime four: bool, comptime quarter: u2) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, w: u32, n: u32, d: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            for (0..4) |beat| {
                const high: u32 = @intCast(beat >> 1);
                const low: u32 = @intCast(beat & 1);
                const turned = (quarter >> 1) ^ (if (four) (quarter & 1) & high else 0);
                const swapped = (quarter & 1) ^ high;
                const middle = if (four) (high + quarter) & 3 else (high + quarter) & 1;
                const word = (high << (if (four) 3 else 2)) | (middle << 1) | low;
                const first = root.get(s, n) +% word * 4;
                const xbeat = (high << 1) | (if (four) turned else swapped);
                for (0..32 / esize) |e| {
                    const at = first +% @as(u32, @intCast(e)) * (esize / 8);
                    const y: u32 = if (four) switch (esize) {
                        8 => @intCast(e & 3),
                        16 => (low << 1) | @as(u32, @intCast(e & 1)),
                        else => (swapped << 1) | low,
                    } else switch (esize) {
                        8, 16 => @intCast(e & 1),
                        else => low,
                    };
                    const inner: u32 = if (four) switch (esize) {
                        8 => (swapped << 1) | low,
                        16 => swapped,
                        else => 0,
                    } else switch (esize) {
                        8 => (low << 1) | @as(u32, @intCast((e >> 1) & 1)),
                        16 => low,
                        else => 0,
                    };
                    const which: u3 = @truncate(d + y);
                    const index = xbeat * (32 / esize) + inner;
                    if (load) {
                        const raw = root.read(host, at, esize, false, true) catch |err| return Outcome.faulted(err);
                        lib.setLane(s, which, esize, index, raw);
                    } else {
                        root.write(host, at, esize, lib.lane(s, which, esize, index), true) catch |err| return Outcome.faulted(err);
                    }
                }
            }
            if (w == 1) root.set(s, n, root.get(s, n) +% (if (four) 64 else 32));
            return leave(s, blocked);
        }
    };
}

/// VMOV of one element between a vector lane and a core register.
pub fn Element(comptime esize: u8, comptime to_core: bool, comptime signed: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, y: u32, d: u32, t: u32, j: u32) Outcome {
            if (!host.mve()) return .undefined;
            const checked = fp.check(root.Host(@TypeOf(host)), s, host) catch |err| return Outcome.faulted(err);
            if (checked) |outcome| return outcome;
            const at = d * 2 + y;
            const shift: u5 = @intCast(j * esize);
            const mask: u32 = ((@as(u32, 1) << esize) - 1) << shift;
            if (!to_core) {
                s.fp[at] = (s.fp[at] & ~mask) | ((root.get(s, t) << shift) & mask);
                return .next;
            }
            const raw = (s.fp[at] & mask) >> shift;
            const Small = std.meta.Int(.unsigned, esize);
            root.set(s, t, if (signed) @bitCast(@as(i32, @as(std.meta.Int(.signed, esize), @bitCast(@as(Small, @truncate(raw)))))) else raw);
            return .next;
        }
    };
}

fn widen(s: *State, host: anytype, comptime esize: u8, comptime signed: bool, comptime top: bool, places: u5, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const source = lib.whole(s, @intCast(m)).*;
    for (0..64 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize * 2, at) == 0) continue;
        const value = lib.widened(esize, signed, lib.part(&source, esize, at * 2 + @intFromBool(top)));
        lib.merge(s, mask, @intCast(d), esize * 2, at, @truncate(@as(u64, @bitCast(value)) << places));
    }
    return leave(s, blocked);
}

/// VSHLL: widens every other element and shifts by the immediate.
pub fn Widen(comptime esize: u8, comptime signed: bool, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            return widen(s, host, esize, signed, top, @intCast(i), d, m);
        }
    };
}

/// VSHLLB and VSHLLT by the full element width.
pub fn WidenWhole(comptime esize: u8, comptime signed: bool, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            return widen(s, host, esize, signed, top, esize, d, m);
        }
    };
}

fn narrow(s: *State, host: anytype, comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, comptime unsigned: bool, comptime top: bool, amount: i32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const source = lib.whole(s, @intCast(m)).*;
    var saturated = false;
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k * 2 + @intFromBool(top));
        if (lib.bytesOn(mask, esize / 2, at) == 0) continue;
        var sat = false;
        const value = lib.slid(esize, esize / 2, signed, rounding, saturating, unsigned, lib.part(&source, esize, @intCast(k)), amount, &sat);
        if (sat and lib.active(mask, esize / 2, at)) saturated = true;
        lib.merge(s, mask, @intCast(d), esize / 2, at, value);
    }
    if (saturated) s.fpscr |= fp.qc;
    return leave(s, blocked);
}

/// VMOVN, VQMOVN and VQMOVUN: narrows into every other element.
pub fn Narrow(comptime esize: u8, comptime signed: bool, comptime saturating: bool, comptime unsigned: bool, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            return narrow(s, host, esize, signed, false, saturating, unsigned, top, 0, d, m);
        }
    };
}

/// Narrowing shifts: VSHRN, VRSHRN, VQSHRN, VQRSHRN, VQSHRUN and VQRSHRUN.
pub fn NarrowShift(comptime esize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, comptime unsigned: bool, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            return narrow(s, host, esize, signed, rounding, saturating, unsigned, top, @as(i32, @intCast(i)) - esize / 2, d, m);
        }
    };
}

fn constant(s: *State, host: anytype, comptime negated: bool, cmode: u4, i: u32, d: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const words = lib.expandedWord(cmode, negated, @intCast(i));
    const combining = cmode & 1 == 1 and cmode >> 2 != 3;
    for (0..16) |k| {
        const at: u32 = @intCast(k);
        if (!lib.active(mask, 8, at)) continue;
        const byte: u32 = words[k / 4 & 1] >> @intCast(k % 4 * 8) & 0xff;
        const old = lib.lane(s, @intCast(d), 8, at);
        lib.setLane(s, @intCast(d), 8, at, if (!combining)
            (if (negated and cmode >> 1 != 7) ~byte else byte)
        else if (negated) old & ~byte else old | byte);
    }
    return leave(s, blocked);
}

/// Vector immediate VMOV, VMVN, VORR or VBIC with cmode completed from the encoding.
pub fn Constant(comptime negated: bool, comptime base: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, p: u32) Outcome {
            return constant(s, host, negated, base | @as(u4, @intCast(p)), i, d);
        }
    };
}

/// Vector immediate VMOV, VMVN, VORR or VBIC with a fixed cmode.
pub fn ConstantFixed(comptime negated: bool, comptime cmode: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32) Outcome {
            return constant(s, host, negated, cmode, i, d);
        }
    };
}

fn counter(s: *State, host: anytype, comptime esize: u8, comptime up: bool, comptime wrapping: bool, limit: u32, n: u32, d: u32, i: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const step = @as(u32, 1) << @intCast(i);
    var at = root.get(s, n * 2);
    for (0..128 / esize) |k| {
        lib.merge(s, mask, @intCast(d), esize, @intCast(k), at);
        if (up) {
            at +%= step;
            if (wrapping and at == limit) at = 0;
        } else if (wrapping and at == 0) {
            at = limit -% step;
        } else {
            at -%= step;
        }
    }
    root.set(s, n * 2, at);
    return leave(s, blocked);
}

/// VIDUP and VDDUP: fills the lanes with a counter stepping by the immediate.
pub fn Counter(comptime esize: u8, comptime up: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, i: u32) Outcome {
            return counter(s, host, esize, up, false, 0, n, d, i);
        }
    };
}

/// VIWDUP and VDWDUP: a counter that wraps at the limit register.
pub fn CounterWrapping(comptime esize: u8, comptime up: bool, comptime base: u3) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, i: u32, m: u32) Outcome {
            return counter(s, host, esize, up, true, root.get(s, (@as(u32, base) | m) * 2 + 1), n, d, i);
        }
    };
}

fn across(s: *State, host: anytype, comptime esize: u8, comptime signed: bool, comptime long: bool, high: u32, l: u32, a: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    var total: u64 = if (a == 0) 0 else if (long) @as(u64, root.get(s, high)) << 32 | root.get(s, l * 2) else root.get(s, l * 2);
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (!lib.active(mask, esize, at)) continue;
        total +%= @bitCast(lib.widened(esize, signed, lib.lane(s, @intCast(m), esize, at)));
    }
    root.set(s, l * 2, @truncate(total));
    if (long) root.set(s, high, @truncate(total >> 32));
    return leave(s, blocked);
}

/// VADDV: sums the lanes into a core register, accumulating when A is set.
pub fn Across(comptime esize: u8, comptime signed: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, l: u32, a: u32, m: u32) Outcome {
            return across(s, host, esize, signed, false, 0, l, a, m);
        }
    };
}

/// VADDLV: sums 32-bit lanes into a register pair, accumulating when A is set.
pub fn AcrossLong(comptime signed: bool, comptime base: u3) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, h: u32, l: u32, a: u32, m: u32) Outcome {
            return across(s, host, 32, signed, true, (@as(u32, base) | h) * 2 + 1, l, a, m);
        }
    };
}

/// VMAXV, VMINV, VMAXAV and VMINAV: reduces the lanes with a core register.
pub fn Extremum(comptime esize: u8, comptime signed: bool, comptime absolute: bool, comptime maximum: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, t: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            var best = lib.widened(esize, signed and !absolute, root.get(s, t));
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (!lib.active(mask, esize, at)) continue;
                const value = lib.widened(esize, signed, lib.lane(s, @intCast(m), esize, at));
                const seen = if (absolute) @as(i64, @intCast(@abs(value))) else value;
                best = if (maximum) @max(best, seen) else @min(best, seen);
            }
            root.set(s, t, @truncate(@as(u64, @bitCast(best))));
            return leave(s, blocked);
        }
    };
}

/// VABAV: accumulates absolute lane differences into a core register.
pub fn Difference(comptime esize: u8, comptime signed: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            var total: u32 = root.get(s, t);
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (!lib.active(mask, esize, at)) continue;
                const first = lib.widened(esize, signed, lib.lane(s, @intCast(n), esize, at));
                const second = lib.widened(esize, signed, lib.lane(s, @intCast(m), esize, at));
                total +%= @truncate(@abs(first - second));
            }
            root.set(s, t, total);
            return leave(s, blocked);
        }
    };
}

/// VMAXA and VMINA: unsigned destination lane against the absolute source lane.
pub fn Extreme(comptime esize: u8, comptime maximum: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const held = lib.widened(esize, false, lib.lane(s, @intCast(d), esize, at));
                const seen: i64 = @intCast(@abs(lib.widened(esize, true, lib.lane(s, @intCast(m), esize, at))));
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(if (maximum) @max(held, seen) else @min(held, seen)))));
            }
            return leave(s, blocked);
        }
    };
}

fn products(s: *State, host: anytype, comptime esize: u8, comptime signed: bool, comptime subtract: bool, comptime long: bool, comptime rounding: bool, high: u32, n: u32, l: u32, swap: u32, a: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    const held: u64 = if (a == 0) 0 else if (long) @as(u64, root.get(s, high)) << 32 | root.get(s, l * 2) else root.get(s, l * 2);
    var total: i128 = if (a == 0) 0 else if (long and signed) @as(i64, @bitCast(held)) else held;
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        const on = lib.active(mask, esize, at);
        if (!on and !rounding) continue;
        const first = lib.widened(esize, signed, lib.lane(s, @intCast(n), esize, at ^ swap));
        const second = lib.widened(esize, signed, lib.lane(s, @intCast(m), esize, at));
        const product = @as(i128, first) * second;
        if (!rounding) {
            total += if (subtract and at & 1 == 1) -product else product;
            continue;
        }
        var wider = total << 8;
        if (on) wider += (if (subtract and at & 1 == 1) -product else product) + 128;
        const kept: u64 = @truncate(@as(u128, @bitCast(wider >> 8)));
        total = if (signed) @as(i64, @bitCast(kept)) else kept;
    }
    const answer: u64 = @truncate(@as(u128, @bitCast(total)));
    root.set(s, l * 2, @truncate(answer));
    if (long) root.set(s, high, @truncate(answer >> 32));
    return leave(s, blocked);
}

/// VMLADAV and VMLSDAV: dot product of the lanes into a core register.
pub fn Products(comptime esize: u8, comptime signed: bool, comptime subtract: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, l: u32, a: u32, m: u32) Outcome {
            return products(s, host, esize, signed, subtract, false, false, 0, n, l, 0, a, m);
        }
    };
}

/// VMLADAVX and VMLSDAVX: dot product with the source lanes exchanged.
pub fn ProductsExchange(comptime esize: u8, comptime signed: bool, comptime subtract: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, l: u32, x: u32, a: u32, m: u32) Outcome {
            return products(s, host, esize, signed, subtract, false, false, 0, n, l, x, a, m);
        }
    };
}

/// VMLALDAV, VMLSLDAV and VRMLALDAVH: dot product into a register pair.
pub fn ProductsLong(comptime esize: u8, comptime signed: bool, comptime subtract: bool, comptime rounding: bool, comptime base: u3) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, h: u32, n: u32, l: u32, a: u32, m: u32) Outcome {
            return products(s, host, esize, signed, subtract, true, rounding, (@as(u32, base) | h) * 2 + 1, n, l, 0, a, m);
        }
    };
}

/// Exchanged forms of VMLALDAV, VMLSLDAV and VRMLALDAVH.
pub fn ProductsLongExchange(comptime esize: u8, comptime signed: bool, comptime subtract: bool, comptime rounding: bool, comptime base: u3) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, h: u32, n: u32, l: u32, x: u32, a: u32, m: u32) Outcome {
            return products(s, host, esize, signed, subtract, true, rounding, (@as(u32, base) | h) * 2 + 1, n, l, x, a, m);
        }
    };
}

/// VMULH, VRMULH, VQDMULH and VQRDMULH: high half of the lane product, vector or scalar.
pub fn Product(comptime esize: u8, comptime signed: bool, comptime doubling: bool, comptime rounding: bool, comptime scalar: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, x: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const bounds = lib.Bounds(esize, signed);
            const round: i64 = if (rounding) @as(i64, 1) << (esize - 1) else 0;
            const shared = if (scalar) lib.widened(esize, signed, root.get(s, x)) else 0;
            var saturated = false;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const first = lib.widened(esize, signed, lib.lane(s, @intCast(n), esize, at));
                const second = if (scalar) shared else lib.widened(esize, signed, lib.lane(s, @intCast(x), esize, at));
                if (!signed) {
                    const raw = @as(u64, @bitCast(first)) * @as(u64, @bitCast(second)) + @as(u64, @bitCast(round));
                    lib.merge(s, mask, @intCast(d), esize, at, @truncate(raw >> esize));
                    continue;
                }
                var sat = false;
                const scaled = @mulWithOverflow(first * second, @as(i64, if (doubling) 2 else 1));
                const value = if (scaled[1] != 0) bounds.high else lib.clamped((scaled[0] + round) >> esize, bounds.low, bounds.high, &sat);
                if ((sat or scaled[1] != 0) and lib.active(mask, esize, at)) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(value))));
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VMULL and VQDMULL: widening lane products, vector or scalar.
pub fn Widening(comptime esize: u8, comptime signed: bool, comptime doubling: bool, comptime top: bool, comptime scalar: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, x: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const pair = esize * 2;
            const source = lib.whole(s, @intCast(n)).*;
            const other = if (scalar) source else lib.whole(s, @intCast(x)).*;
            const shared = if (scalar) lib.widened(esize, signed, root.get(s, x)) else 0;
            var saturated = false;
            for (0..128 / pair) |i| {
                const at: u32 = @intCast(i * 2 + @intFromBool(top));
                const first = lib.widened(esize, signed, lib.part(&source, esize, at));
                const second = if (scalar) shared else lib.widened(esize, signed, lib.part(&other, esize, at));
                var raw: u64 = @as(u64, @bitCast(first)) *% @as(u64, @bitCast(second));
                var sat = false;
                if (doubling) {
                    const twice = @mulWithOverflow(first * second, @as(i64, 2));
                    if (twice[1] != 0) {
                        sat = true;
                        raw = @bitCast(@as(i64, std.math.maxInt(i64)));
                    } else if (pair == 64) {
                        raw = @bitCast(twice[0]);
                    } else {
                        const bounds = lib.Bounds(pair, true);
                        raw = @bitCast(lib.clamped(twice[0], bounds.low, bounds.high, &sat));
                    }
                }
                if (pair == 64) {
                    if (sat and lib.active(mask, 32, @intCast(i * 2))) saturated = true;
                    lib.merge(s, mask, @intCast(d), 32, @intCast(i * 2), @truncate(raw));
                    lib.merge(s, mask, @intCast(d), 32, @intCast(i * 2 + 1), @truncate(raw >> 32));
                } else {
                    if (sat and lib.active(mask, pair, @intCast(i))) saturated = true;
                    lib.merge(s, mask, @intCast(d), if (pair == 64) 32 else pair, @intCast(i), @truncate(raw));
                }
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VMULL.P8 and VMULL.P16: carry-less polynomial products.
pub fn Polynomial(comptime esize: u8, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const pair = esize * 2;
            const source = lib.whole(s, @intCast(n)).*;
            const other = lib.whole(s, @intCast(m)).*;
            for (0..128 / pair) |i| {
                if (lib.bytesOn(mask, pair, @intCast(i)) == 0) continue;
                const at: u32 = @intCast(i * 2 + @intFromBool(top));
                const first: u64 = lib.part(&source, esize, at);
                const second = lib.part(&other, esize, at);
                var value: u64 = 0;
                for (0..esize) |bit| {
                    if (second >> @intCast(bit) & 1 != 0) value ^= first << @intCast(bit);
                }
                lib.merge(s, mask, @intCast(d), pair, @intCast(i), @truncate(value));
            }
            return leave(s, blocked);
        }
    };
}

/// VQDMLADH, VQDMLSDH and their rounding and exchanged forms.
pub fn Doubled(comptime esize: u8, comptime exchange: bool, comptime subtract: bool, comptime rounding: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const bounds = lib.Bounds(esize, true);
            const first = lib.whole(s, @intCast(n)).*;
            const second = lib.whole(s, @intCast(m)).*;
            var saturated = false;
            for (0..128 / esize) |i| {
                if ((i & 1 == 1) != exchange) continue;
                if (lib.bytesOn(mask, esize, @intCast(i)) == 0) continue;
                const other: u32 = @intCast(if (exchange) i - 1 else i + 1);
                const one = @as(i128, lib.widened(esize, true, lib.part(&first, esize, @intCast(i)))) * lib.widened(esize, true, lib.part(&second, esize, if (exchange) other else @intCast(i)));
                const two = @as(i128, lib.widened(esize, true, lib.part(&first, esize, other))) * lib.widened(esize, true, lib.part(&second, esize, if (exchange) @intCast(i) else other));
                const raw = 2 * (if (subtract) one - two else one + two) + (if (rounding) @as(i128, 1) << (esize - 1) else 0);
                const value: i64 = @intCast(raw >> esize);
                var sat = false;
                const capped = lib.clamped(value, bounds.low, bounds.high, &sat);
                if (sat and lib.active(mask, esize, @intCast(i))) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, @intCast(i), @truncate(@as(u64, @bitCast(capped))));
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VQDMLAH, VQDMLASH, VQRDMLAH and VQRDMLASH: doubling multiply-accumulate with a scalar.
pub fn Accumulated(comptime esize: u8, comptime rounding: bool, comptime addend: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, t: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const bounds = lib.Bounds(esize, true);
            const shared = lib.widened(esize, true, root.get(s, t));
            var saturated = false;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const held = lib.widened(esize, true, lib.lane(s, @intCast(d), esize, at));
                const source = lib.widened(esize, true, lib.lane(s, @intCast(n), esize, at));
                const raw = 2 * @as(i128, source) * (if (addend) held else shared) +
                    (@as(i128, if (addend) shared else held) << esize) +
                    (if (rounding) @as(i128, 1) << (esize - 1) else 0);
                const value: i64 = @intCast(raw >> esize);
                var sat = false;
                const capped = lib.clamped(value, bounds.low, bounds.high, &sat);
                if (sat and lib.active(mask, esize, at)) saturated = true;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(capped))));
            }
            if (saturated) s.fpscr |= fp.qc;
            return leave(s, blocked);
        }
    };
}

/// VCADD and VHCADD: complex add rotated by 90 or 270 degrees.
pub fn Turned(comptime esize: u8, comptime rotated: bool, comptime halving: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            const first = lib.whole(s, @intCast(n)).*;
            const second = lib.whole(s, @intCast(m)).*;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const one = lib.widened(esize, halving, lib.part(&first, esize, at));
                const two = lib.widened(esize, halving, lib.part(&second, esize, @intCast(i ^ 1)));
                const value = if (rotated == (i & 1 == 1)) one - two else one + two;
                lib.merge(s, mask, @intCast(d), esize, at, @truncate(@as(u64, @bitCast(if (halving) value >> 1 else value))));
            }
            return leave(s, blocked);
        }
    };
}

/// VADC, VADCI, VSBC and VSBCI: 32-bit add or subtract through FPSCR.C.
pub fn Carried(comptime subtract: bool, comptime initial: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            const mask = lib.predicate(s);
            if (initial) s.fpscr = (s.fpscr & ~fp.nzcv) | (if (subtract) @as(u32, 1) << 29 else 0);
            for (0..4) |i| {
                const one = lib.lane(s, @intCast(n), 32, @intCast(i));
                const two = if (subtract) ~lib.lane(s, @intCast(m), 32, @intCast(i)) else lib.lane(s, @intCast(m), 32, @intCast(i));
                const total = @as(u64, one) + two + (s.fpscr >> 29 & 1);
                if (lib.active(mask, 32, @intCast(i))) s.fpscr = (s.fpscr & ~fp.nzcv) | @as(u32, @truncate(total >> 32)) << 29;
                for (0..4) |byte| {
                    const at: u32 = @intCast(i * 4 + byte);
                    if (lib.active(mask, 8, at)) lib.setLane(s, @intCast(d), 8, at, @truncate(total >> @intCast(byte * 8)));
                }
            }
            return leave(s, blocked);
        }
    };
}

fn refuse(s: *State, blocked: bool) Outcome {
    if (blocked) lib.advance(s);
    return .undefined;
}

fn standard(s: *State) u32 {
    const kept = s.fpscr;
    s.fpscr = (kept & ~fp.modes) | fp.standard;
    return kept;
}

fn restore(s: *State, kept: u32) void {
    s.fpscr = (s.fpscr & ~fp.modes) | (kept & fp.modes);
}

fn arithmetic(s: *State, host: anytype, comptime esize: u8, comptime kind: fp.Arithmetic, comptime absolute: bool, comptime scalar: bool, n: u32, d: u32, x: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const mask = lib.predicate(s);
    const shared: T = if (scalar) lib.real(s, esize, root.get(s, x)) else 0;
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const a = lib.real(s, esize, lib.lane(s, @intCast(n), esize, at));
        const b = if (scalar) shared else lib.real(s, esize, lib.lane(s, @intCast(x), esize, at));
        const answer = fp.arithmetic(s, kind, T, a, b);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, if (absolute) @abs(answer) else answer));
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// Floating-point VADD, VSUB, VMUL and VABD over lanes.
pub fn Real(comptime esize: u8, comptime kind: fp.Arithmetic, comptime absolute: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            return arithmetic(s, host, esize, kind, absolute, false, n, d, m);
        }
    };
}

/// Floating-point VADD, VSUB and VMUL against a core register scalar.
pub fn RealScalar(comptime esize: u8, comptime kind: fp.Arithmetic) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, t: u32) Outcome {
            return arithmetic(s, host, esize, kind, false, true, n, d, t);
        }
    };
}

fn accumulate(s: *State, host: anytype, comptime esize: u8, comptime kind: fp.Accumulate, comptime scalar: bool, comptime addend: bool, n: u32, d: u32, x: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const mask = lib.predicate(s);
    const shared: T = if (scalar) lib.real(s, esize, root.get(s, x)) else 0;
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const held = lib.real(s, esize, lib.lane(s, @intCast(d), esize, at));
        const source = lib.real(s, esize, lib.lane(s, @intCast(n), esize, at));
        const other = if (scalar) shared else lib.real(s, esize, lib.lane(s, @intCast(x), esize, at));
        const answer = if (addend) fp.multiplyAdd(s, kind, T, held, source, shared) else fp.multiplyAdd(s, kind, T, source, other, held);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, answer));
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// Floating-point VFMA and VFMS over lanes.
pub fn Chained(comptime esize: u8, comptime kind: fp.Accumulate) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            return accumulate(s, host, esize, kind, false, false, n, d, m);
        }
    };
}

/// VFMA and VFMAS with a core register scalar.
pub fn ChainedScalar(comptime esize: u8, comptime addend: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, t: u32) Outcome {
            return accumulate(s, host, esize, .fma, true, addend, n, d, t);
        }
    };
}

/// Floating-point VABS and VNEG: touches only the sign bit.
pub fn Sign(comptime esize: u8, comptime negate: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            if (!host.halfPrecision()) return refuse(s, blocked);
            const mask = lib.predicate(s);
            const top = @as(u32, 1) << (esize - 1);
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const value = lib.lane(s, @intCast(m), esize, at);
                lib.merge(s, mask, @intCast(d), esize, at, if (negate) value ^ top else value & ~top);
            }
            return leave(s, blocked);
        }
    };
}

fn compared(s: *State, host: anytype, comptime esize: u8, comptime scalar: bool, comptime base: u3, comptime who: u4, k: u32, n: u32, p: u32, c: u32, x: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const mask = lib.predicate(s);
    const bytes = esize / 8;
    const index: u3 = base | (@as(u3, @intCast(c)) << 1) | @as(u3, @intCast(p));
    const other: T = if (scalar) lib.real(s, esize, lib.scalarOf(s, who | @as(u4, @intCast(x)))) else 0;
    var flags: u32 = 0;
    for (0..128 / esize) |i| {
        const at: u32 = @intCast(i);
        if (!lib.active(mask, esize, at)) continue;
        const a = lib.real(s, esize, lib.lane(s, @intCast(n), esize, at));
        const b = if (scalar) other else lib.real(s, esize, lib.lane(s, @intCast(x), esize, at));
        if (std.math.isNan(a) or std.math.isNan(b)) s.fpscr |= fp.ioc;
        if (lib.ordered(T, index, a, b)) flags |= ((@as(u32, 1) << bytes) - 1) << @intCast(at * bytes);
    }
    s.vpr = (s.vpr & ~lib.p0) | (flags & mask);
    if (k != 0) s.vpr = (s.vpr & ~(lib.mask01 | lib.mask23)) | (k * 0x0011_0000);
    restore(s, kept);
    return leave(s, blocked);
}

/// Floating-point VPT and VCMP against a vector, conditions EQ and NE.
pub fn RealCompare(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32, m: u32) Outcome {
            return compared(s, host, esize, false, 0, 0, k, n, p, 0, m);
        }
    };
}

/// Floating-point VPT and VCMP against a vector, conditions GE, LT, GT and LE.
pub fn RealCompareHigh(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32, m: u32, c: u32) Outcome {
            return compared(s, host, esize, false, 4, 0, k, n, p, c, m);
        }
    };
}

/// Floating-point VPT and VCMP against a core register, conditions EQ and NE.
pub fn RealCompareScalar(comptime esize: u8, comptime who: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32, t: u32) Outcome {
            return compared(s, host, esize, true, 0, who, k, n, p, 0, t);
        }
    };
}

/// Floating-point VPT and VCMP against a fixed core register, conditions EQ and NE.
pub fn RealCompareScalarOnly(comptime esize: u8, comptime who: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32) Outcome {
            return compared(s, host, esize, true, 0, who, k, n, p, 0, 0);
        }
    };
}

/// Floating-point VPT and VCMP against a core register, conditions GE, LT, GT and LE.
pub fn RealCompareScalarHigh(comptime esize: u8, comptime who: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32, c: u32, t: u32) Outcome {
            return compared(s, host, esize, true, 4, who, k, n, p, c, t);
        }
    };
}

/// Floating-point VPT and VCMP against a fixed core register, conditions GE, LT, GT and LE.
pub fn RealCompareScalarHighOnly(comptime esize: u8, comptime who: u4) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, k: u32, n: u32, p: u32, c: u32) Outcome {
            return compared(s, host, esize, true, 4, who, k, n, p, c, 0);
        }
    };
}

fn nearest(s: *State, host: anytype, comptime esize: u8, comptime largest: bool, comptime absolute: bool, n: u32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const mask = lib.predicate(s);
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const held = lib.real(s, esize, lib.lane(s, @intCast(if (absolute) d else n), esize, at));
        const seen = lib.real(s, esize, lib.lane(s, @intCast(m), esize, at));
        const a = if (absolute) @abs(held) else held;
        const b = if (absolute) @abs(seen) else seen;
        const answer = fp.extremum(s, T, largest, a, b);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, answer));
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// VMAXNM and VMINNM over lanes.
pub fn Nearest(comptime esize: u8, comptime largest: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            return nearest(s, host, esize, largest, false, n, d, m);
        }
    };
}

/// VMAXNMA and VMINNMA: destination lane against the absolute source lane.
pub fn NearestAbsolute(comptime esize: u8, comptime largest: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            return nearest(s, host, esize, largest, true, 0, d, m);
        }
    };
}

/// VMAXNMV, VMINNMV, VMAXNMAV and VMINNMAV: reduces the lanes with a core register.
pub fn Finest(comptime esize: u8, comptime largest: bool, comptime absolute: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, t: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            if (!host.halfPrecision()) return refuse(s, blocked);
            const kept = standard(s);
            const T = lib.Float(esize);
            const mask = lib.predicate(s);
            var best = lib.real(s, esize, root.get(s, t));
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (!lib.active(mask, esize, at)) continue;
                const seen = fp.converted(s, T, lib.real(s, esize, lib.lane(s, @intCast(m), esize, at)));
                best = fp.extremum(s, T, largest, if (absolute) @abs(seen) else seen, fp.converted(s, T, best));
            }
            root.set(s, t, lib.bitsOf(esize, best));
            restore(s, kept);
            return leave(s, blocked);
        }
    };
}

fn toFixed(s: *State, host: anytype, comptime esize: u8, comptime unsigned: bool, comptime kind: fp.Rounding, places: i32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const Int = std.meta.Int(if (unsigned) .unsigned else .signed, esize);
    const mask = lib.predicate(s);
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const value = lib.real(s, esize, lib.lane(s, @intCast(m), esize, at));
        const answer = fp.toFixed(s, Int, T, kind, value, places);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, answer);
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// VCVT float to integer by the rounding kind, including VCVTA, VCVTN, VCVTP and VCVTM.
pub fn Fixed(comptime esize: u8, comptime unsigned: bool, comptime kind: fp.Rounding) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            return toFixed(s, host, esize, unsigned, kind, 0, d, m);
        }
    };
}

/// VCVT float to fixed-point with the immediate's fraction bits, truncating.
pub fn FixedScaled(comptime esize: u8, comptime unsigned: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            return toFixed(s, host, esize, unsigned, .zero, @as(i32, esize) - @as(i32, @intCast(i)), d, m);
        }
    };
}

fn fromFixed(s: *State, host: anytype, comptime esize: u8, comptime unsigned: bool, places: i32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const Int = std.meta.Int(if (unsigned) .unsigned else .signed, esize);
    const mask = lib.predicate(s);
    for (0..128 / esize) |k| {
        const at: u32 = @intCast(k);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const value = fp.fromFixed(s, Int, T, lib.lane(s, @intCast(m), esize, at), places);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, value));
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// VCVT integer to float.
pub fn Loosed(comptime esize: u8, comptime unsigned: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            return fromFixed(s, host, esize, unsigned, 0, d, m);
        }
    };
}

/// VCVT fixed-point to float with the immediate's fraction bits.
pub fn LoosedScaled(comptime esize: u8, comptime unsigned: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, i: u32, d: u32, m: u32) Outcome {
            return fromFixed(s, host, esize, unsigned, @as(i32, esize) - @as(i32, @intCast(i)), d, m);
        }
    };
}

/// VCVTB and VCVTT between half and single precision lanes.
pub fn Halved(comptime widening: bool, comptime top: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            if (!host.halfPrecision()) return refuse(s, blocked);
            const kept = standard(s);
            const mask = lib.predicate(s);
            for (0..4) |i| {
                const at: u32 = @intCast(i * 2 + @intFromBool(top));
                const flags = s.fpscr;
                if (widening) {
                    if (lib.bytesOn(mask, 32, @intCast(i)) == 0) continue;
                    const raw: u16 = @truncate(lib.lane(s, @intCast(m), 16, at));
                    const answer = fp.fromHalf(s, f32, raw);
                    lib.quiet(s, mask, 32, @intCast(i), flags);
                    lib.merge(s, mask, @intCast(d), 32, @intCast(i), @bitCast(answer));
                } else {
                    if (lib.bytesOn(mask, 16, at) == 0) continue;
                    const value: f32 = @bitCast(lib.lane(s, @intCast(m), 32, @intCast(i)));
                    const answer = fp.toHalf(s, f32, fp.admitted(s, f32, value));
                    lib.quiet(s, mask, 16, at, flags);
                    lib.merge(s, mask, @intCast(d), 16, at, answer);
                }
            }
            restore(s, kept);
            return leave(s, blocked);
        }
    };
}

/// VRINT: rounds each lane to an integral value by kind.
pub fn Integral(comptime esize: u8, comptime kind: fp.Rounding) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            if (!host.halfPrecision()) return refuse(s, blocked);
            const kept = standard(s);
            const T = lib.Float(esize);
            const mask = lib.predicate(s);
            for (0..128 / esize) |k| {
                const at: u32 = @intCast(k);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const flags = s.fpscr;
                const value = lib.real(s, esize, lib.lane(s, @intCast(m), esize, at));
                const answer = fp.integralOf(s, kind, T, value);
                lib.quiet(s, mask, esize, at, flags);
                lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, answer));
            }
            restore(s, kept);
            return leave(s, blocked);
        }
    };
}

fn rotate(s: *State, host: anytype, comptime esize: u8, comptime accumulate_it: bool, n: u32, d: u32, r: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (!host.halfPrecision()) return refuse(s, blocked);
    const kept = standard(s);
    const T = lib.Float(esize);
    const mask = lib.predicate(s);
    const first = lib.whole(s, @intCast(n)).*;
    const second = lib.whole(s, @intCast(m)).*;
    const high = r >> 1 & 1 == 1;
    const low = r & 1 == 1;
    for (0..128 / esize) |i| {
        const at: u32 = @intCast(i);
        if (lib.bytesOn(mask, esize, at) == 0) continue;
        const flags = s.fpscr;
        const upper = i & 1 == 1;
        const other: u32 = @intCast(i ^ 1);
        const a = lib.real(s, esize, lib.part(&first, esize, if (upper == low) at else other));
        const raw = lib.real(s, esize, lib.part(&second, esize, if (low) other else at));
        const b = if (if (upper) high else high != low) -raw else raw;
        const answer = if (accumulate_it)
            fp.multiplyAdd(s, .fma, T, a, b, lib.real(s, esize, lib.lane(s, @intCast(d), esize, at)))
        else
            fp.arithmetic(s, .mul, T, a, b);
        lib.quiet(s, mask, esize, at, flags);
        lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, answer));
    }
    restore(s, kept);
    return leave(s, blocked);
}

/// VCMUL: complex multiply rotated by the encoded multiple of 90 degrees.
pub fn Complex(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, r: u32, m: u32) Outcome {
            return rotate(s, host, esize, false, n, d, r, m);
        }
    };
}

/// VCMLA: complex multiply-accumulate rotated by the encoded multiple of 90 degrees.
pub fn ComplexAccumulate(comptime esize: u8) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, r: u32, n: u32, d: u32, m: u32) Outcome {
            return rotate(s, host, esize, true, n, d, r, m);
        }
    };
}

/// Floating-point VCADD rotated by 90 or 270 degrees.
pub fn Crossed(comptime esize: u8, comptime rotated: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const blocked = switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => |b| b,
            };
            if (!host.halfPrecision()) return refuse(s, blocked);
            const kept = standard(s);
            const T = lib.Float(esize);
            const mask = lib.predicate(s);
            const first = lib.whole(s, @intCast(n)).*;
            const second = lib.whole(s, @intCast(m)).*;
            for (0..128 / esize) |i| {
                const at: u32 = @intCast(i);
                if (lib.bytesOn(mask, esize, at) == 0) continue;
                const flags = s.fpscr;
                const one = lib.real(s, esize, lib.part(&first, esize, at));
                const two = lib.real(s, esize, lib.part(&second, esize, @intCast(i ^ 1)));
                const answer = if (rotated == (i & 1 == 1))
                    fp.arithmetic(s, .sub, T, one, two)
                else
                    fp.arithmetic(s, .add, T, one, two);
                lib.quiet(s, mask, esize, at, flags);
                lib.merge(s, mask, @intCast(d), esize, at, lib.bitsOf(esize, answer));
            }
            restore(s, kept);
            return leave(s, blocked);
        }
    };
}

/// VMRS and VMSR of VPR or its P0 field; the whole register needs privilege.
pub fn Move(comptime to_core: bool, comptime field: u32) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, t: u32) Outcome {
            switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => {},
            }
            const allowed = field == lib.p0 or s.privileged();
            if (to_core) {
                root.set(s, t, if (allowed) s.vpr & field else 0);
            } else if (allowed) {
                s.vpr = (s.vpr & ~field) | (root.get(s, t) & field);
            }
            return .next;
        }
    };
}

/// VMOV of two 32-bit lanes with two core registers.
pub fn Lanes(comptime to_core: bool) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, e: u32, d: u32, i: u32, t: u32) Outcome {
            switch (enter(s, host)) {
                .refused => |outcome| return outcome,
                .opened => {},
            }
            if (to_core) {
                root.set(s, t, lib.lane(s, @intCast(d), 32, i));
                root.set(s, e, lib.lane(s, @intCast(d), 32, i + 2));
            } else {
                lib.setLane(s, @intCast(d), 32, i, root.get(s, t));
                lib.setLane(s, @intCast(d), 32, i + 2, root.get(s, e));
            }
            return .next;
        }
    };
}

/// VPST: opens a block over P0, or VPNOT inverting it when the mask is zero.
pub fn block(s: *State, host: anytype, k: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    if (k == 0) s.vpr = (s.vpr & ~lib.p0) | (~s.vpr & lib.predicate(s));
    if (k != 0) s.vpr = (s.vpr & ~(lib.mask01 | lib.mask23)) | (k * 0x0011_0000);
    return leave(s, blocked);
}

/// VPSEL: takes each byte from the source P0 names.
pub fn select(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    const mask = lib.predicate(s);
    for (0..16) |i| {
        const at: u32 = @intCast(i);
        if (!lib.active(mask, 8, at)) continue;
        const from = if (s.vpr >> @intCast(i) & 1 != 0) n else m;
        lib.setLane(s, @intCast(d), 8, at, lib.lane(s, @intCast(from), 8, at));
    }
    return leave(s, blocked);
}

/// VCTP: sets P0 to the elements a count leaves.
pub fn tail(s: *State, host: anytype, size: u32, n: u32) Outcome {
    const blocked = switch (enter(s, host)) {
        .refused => |outcome| return outcome,
        .opened => |b| b,
    };
    s.vpr = (s.vpr & ~lib.p0) | (lib.upTo(root.get(s, n), @intCast(size)) & lib.predicate(s));
    return leave(s, blocked);
}

fn available(s: *State, host: anytype) ?Outcome {
    return fp.check(root.Host(@TypeOf(host)), s, host) catch |err| Outcome.faulted(err);
}

fn startTail(s: *State, host: anytype, comptime while_loop: bool, size: u32, register: u32, j: u32, i: u32) Outcome {
    if (!host.mve()) return .undefined;
    if (!host.coprocessorEnabled()) return .no_coprocessor;
    const count = root.get(s, register);
    if (while_loop and count == 0) {
        s.pc = root.branch.targetLoopForward(s.pc, register, j, i);
        return .branched;
    }
    if (available(s, host)) |outcome| return outcome;
    lib.setTailSize(s, size);
    s.lr = count;
    return .next;
}

/// WLSTP: starts a tail-predicated while loop counting register top|n; a zero count branches past.
pub fn WhileTail(comptime top: u32) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, size: u32, n: u32, j: u32, i: u32) Outcome {
            return startTail(s, host, true, size, top | n, j, i);
        }
    };
}

/// WLSTP counting LR.
pub fn whileTailLink(s: *State, host: anytype, size: u32, j: u32, i: u32) Outcome {
    return startTail(s, host, true, size, 14, j, i);
}

/// DLSTP: starts a tail-predicated do loop counting register top|n.
pub fn DoTail(comptime top: u32) type {
    return struct {
        /// Runs the instruction for the decoded fields and returns its outcome.
        pub fn call(s: *State, host: anytype, size: u32, n: u32) Outcome {
            return startTail(s, host, false, size, top | n, 0, 0);
        }
    };
}

/// DLSTP counting LR.
pub fn doTailLink(s: *State, host: anytype, size: u32) Outcome {
    return startTail(s, host, false, size, 14, 0, 0);
}

/// LETP: takes a vector of elements off LR and branches back while some remain.
pub fn loopEndTail(s: *State, host: anytype, j: u32, i: u32) Outcome {
    if (!host.mve()) return .undefined;
    if (available(s, host)) |outcome| return outcome;
    const elements = @as(u32, 16) >> @intCast(@min(fp.tailSize(s), 4));
    if (s.lr <= elements) {
        lib.setTailSize(s, 4);
        return .next;
    }
    s.lr -= elements;
    s.pc = root.branch.targetLoopBack(s.pc, j, i);
    return .branched;
}

/// LCTP: ends tail predication by resetting LTPSIZE to four.
pub fn loopClear(s: *State, host: anytype) Outcome {
    if (!host.mve()) return .undefined;
    if (available(s, host)) |outcome| return outcome;
    lib.setTailSize(s, 4);
    return .next;
}
