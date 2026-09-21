//! DSP-extension integer semantics for the T32 rows: the parallel add and subtract family with GE
//! flags, SEL, the QADD and QSUB saturating forms, PKH, the extend-and-add forms, the halfword,
//! dual, top-word and long multiplies, and USAD8. Rows take the machine state, host and decoded
//! fields and return an `Outcome`; root.zig binds them to row names for the generated decoder. The
//! SMMLS and SMMLA encodings also carry PACG and AUTG on a core with PACBTI.
const std = @import("std");
const root = @import("root.zig");
const alu = @import("alu.zig");
const State = root.State;
const Outcome = root.Outcome;

const pac = root.pac;

/// The parallel add and subtract shapes: bytes, halfwords, and the crossed ASX and SAX.
pub const SimdOp = enum { add8, add16, sub8, sub16, asx, sax };
/// The six parallel arithmetic flavours: plain, saturating and halving, each signed or unsigned.
pub const SimdMode = enum { signed, saturating, halving, unsigned, unsigned_saturating, unsigned_halving };

fn simdSigned(comptime mode: SimdMode) bool {
    return mode == .signed or mode == .saturating or mode == .halving;
}

fn simdField(comptime mode: SimdMode, comptime width: u6, value: u32) i64 {
    if (!simdSigned(mode)) return @as(u32, @truncate(value & ((@as(u64, 1) << width) - 1)));
    return switch (width) {
        8 => @as(i8, @bitCast(@as(u8, @truncate(value)))),
        else => @as(i16, @bitCast(@as(u16, @truncate(value)))),
    };
}

const SimdLane = struct { value: u32, ge: bool };

fn simdLane(comptime mode: SimdMode, comptime width: u6, left: u32, right: u32, subtract: bool) SimdLane {
    const top: i64 = @as(i64, 1) << width;
    const x = simdField(mode, width, left);
    const y = simdField(mode, width, right);
    const raw: i64 = if (subtract) x - y else x + y;
    const wrapped: u32 = @truncate(@as(u64, @bitCast(raw)));
    const halved: u32 = @truncate(@as(u64, @bitCast(raw >> 1)));
    const value: u32 = switch (mode) {
        .signed, .unsigned => wrapped,
        .halving, .unsigned_halving => halved,
        .saturating => @truncate(@as(u64, @bitCast(@min(@max(raw, -(top >> 1)), (top >> 1) - 1)))),
        .unsigned_saturating => @intCast(@min(@max(raw, 0), top - 1)),
    };
    return .{
        .value = value & @as(u32, @intCast(top - 1)),
        .ge = switch (mode) {
            .signed => raw >= 0,
            .unsigned => if (subtract) raw >= 0 else raw >= top,
            else => false,
        },
    };
}

/// SADD8, UADD16, QSUB8, SHASX and the rest; the plain modes also write APSR.GE.
pub fn Simd(comptime op: SimdOp, comptime mode: SimdMode) type {
    return struct {
        /// Combines Rn and Rm lane by lane into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            _ = host;
            const x = root.get(s, n);
            const y = root.get(s, m);
            var result: u32 = 0;
            var ge: u4 = 0;
            switch (op) {
                .add8, .sub8 => inline for (0..4) |i| {
                    const at: u5 = 8 * i;
                    const lane = simdLane(mode, 8, x >> at, y >> at, op == .sub8);
                    result |= lane.value << at;
                    if (lane.ge) ge |= @as(u4, 1) << @intCast(i);
                },
                .add16, .sub16 => inline for (0..2) |i| {
                    const at: u5 = 16 * i;
                    const lane = simdLane(mode, 16, x >> at, y >> at, op == .sub16);
                    result |= lane.value << at;
                    if (lane.ge) ge |= @as(u4, 3) << @intCast(2 * i);
                },
                .asx, .sax => {
                    const low = simdLane(mode, 16, x, y >> 16, op == .asx);
                    const high = simdLane(mode, 16, x >> 16, y, op == .sax);
                    result = low.value | (high.value << 16);
                    if (low.ge) ge |= 3;
                    if (high.ge) ge |= 0b1100;
                },
            }
            root.set(s, d, result);
            if (mode == .signed or mode == .unsigned) s.xpsr = (s.xpsr & ~State.flag_ge) | (@as(u32, ge) << 16);
            return .next;
        }
    };
}

/// SEL: picks each byte of Rd from Rn or Rm by the APSR.GE bits.
pub fn sel(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
    _ = host;
    const x = root.get(s, n);
    const y = root.get(s, m);
    const ge: u4 = @truncate((s.xpsr & State.flag_ge) >> 16);
    var result: u32 = 0;
    inline for (0..4) |i| {
        const at: u5 = 8 * i;
        result |= (if ((ge >> @intCast(i)) & 1 == 1) x else y) & (@as(u32, 0xff) << at);
    }
    root.set(s, d, result);
    return .next;
}

fn saturate32(value: i64, q: *bool) u32 {
    if (value > std.math.maxInt(i32)) {
        q.* = true;
        return @bitCast(@as(i32, std.math.maxInt(i32)));
    }
    if (value < std.math.minInt(i32)) {
        q.* = true;
        return @bitCast(@as(i32, std.math.minInt(i32)));
    }
    return @bitCast(@as(i32, @intCast(value)));
}

/// QADD, QSUB, QDADD and QDSUB: saturating 32-bit add or subtract, Rn optionally doubled.
pub fn Saturating(comptime subtract: bool, comptime double: bool) type {
    return struct {
        /// Saturates Rm plus or minus (doubled) Rn into Rd, setting Q on saturation.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            _ = host;
            var q = false;
            const left: i64 = @as(i32, @bitCast(root.get(s, m)));
            const right: i64 = @as(i32, @bitCast(root.get(s, n)));
            const scaled: i64 = if (double) @as(i32, @bitCast(saturate32(2 * right, &q))) else right;
            root.set(s, d, saturate32(if (subtract) left - scaled else left + scaled, &q));
            if (q) s.xpsr |= State.flag_q;
            return .next;
        }
    };
}

/// PKHBT and PKHTB: one halfword from Rn, the other from shifted Rm.
pub fn Pack(comptime bottom: bool) type {
    return struct {
        /// Packs the halves of Rn and shifted Rm into Rd.
        pub fn call(s: *State, host: anytype, n: u32, i: u32, d: u32, m: u32) Outcome {
            _ = host;
            const moved = alu.shiftedBy(s, m, if (bottom) 2 else 0, i).value;
            const kept = root.get(s, n);
            root.set(s, d, if (bottom) (kept & 0xffff_0000) | (moved & 0xffff) else (kept & 0xffff) | (moved & 0xffff_0000));
            return .next;
        }
    };
}

/// SXTAB, UXTAH and siblings: rotate Rm, extend to the width, add Rn; `top` fixes high n bits.
pub fn ExtendAdd(comptime width: u5, comptime signed: bool, comptime top: u32) type {
    return struct {
        /// Adds the rotated, extended Rm to Rn into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, r: u32, m: u32) Outcome {
            _ = host;
            return add(s, top | n, d, r, m);
        }

        /// The same with the base register fixed by the encoding.
        pub fn fixed(s: *State, host: anytype, d: u32, r: u32, m: u32) Outcome {
            _ = host;
            return add(s, top, d, r, m);
        }

        fn add(s: *State, rn: u32, d: u32, r: u32, m: u32) Outcome {
            const rotated = std.math.rotr(u32, root.get(s, m), r * 8);
            root.set(s, d, root.get(s, rn) +% alu.cut(width, signed, rotated));
            return .next;
        }
    };
}

/// SXTAB16 and UXTAB16: two bytes extended and added to the halves of Rn; r15 reads zero.
pub fn ExtendAdd16(comptime signed: bool) type {
    return struct {
        /// Adds each extended byte of rotated Rm to a halfword of Rn into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, r: u32, m: u32) Outcome {
            _ = host;
            const rotated = std.math.rotr(u32, root.get(s, m), r * 8);
            const kept = if (n == 15) 0 else root.get(s, n);
            const low = (kept & 0xffff) +% alu.cut(8, signed, rotated);
            const high = (kept >> 16) +% alu.cut(8, signed, rotated >> 16);
            root.set(s, d, (low & 0xffff) | (high << 16));
            return .next;
        }
    };
}

fn halfOf(value: u32, comptime top: bool) i64 {
    return @as(i16, @bitCast(@as(u16, @truncate(if (top) value >> 16 else value))));
}

fn addend(s: *const State, a: u32) i64 {
    return if (a == 15) 0 else @as(i32, @bitCast(root.get(s, a)));
}

fn narrowTo(s: *State, d: u32, sum: i64) void {
    root.set(s, d, @truncate(@as(u64, @bitCast(sum))));
    if (sum != @as(i64, @as(i32, @truncate(sum)))) s.xpsr |= State.flag_q;
}

/// SMULBB, SMLATB and siblings: a halfword times a halfword, accumulated; an r15 addend is zero.
pub fn HalfMultiply(comptime n_top: bool, comptime m_top: bool) type {
    return struct {
        /// Multiplies the chosen halves of Rn and Rm, adds Ra into Rd, setting Q on overflow.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            _ = host;
            narrowTo(s, d, halfOf(root.get(s, n), n_top) * halfOf(root.get(s, m), m_top) + addend(s, a));
            return .next;
        }
    };
}

/// SMULWB, SMLAWT and siblings: Rn times a halfword of Rm, top 32 of 48 bits kept.
pub fn WideHalfMultiply(comptime m_top: bool) type {
    return struct {
        /// Multiplies Rn by a half of Rm, adds Ra into Rd, setting Q on overflow.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            _ = host;
            const product = @as(i64, @as(i32, @bitCast(root.get(s, n)))) * halfOf(root.get(s, m), m_top);
            narrowTo(s, d, (product >> 16) + addend(s, a));
            return .next;
        }
    };
}

fn dualProduct(s: *const State, n: u32, m: u32, comptime subtract: bool, comptime swap: bool) i64 {
    const x = root.get(s, n);
    const y = root.get(s, m);
    const first = halfOf(x, false) * halfOf(y, swap);
    const second = halfOf(x, true) * halfOf(y, !swap);
    return if (subtract) first - second else first + second;
}

/// SMUAD, SMUSD, SMLAD, SMLSD and their X forms: two halfword products added or subtracted.
pub fn DualMultiply(comptime subtract: bool, comptime swap: bool) type {
    return struct {
        /// Sums the dual products with Ra into Rd, setting Q on overflow.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            _ = host;
            narrowTo(s, d, dualProduct(s, n, m, subtract, swap) + addend(s, a));
            return .next;
        }
    };
}

/// SMMUL, SMMLA, SMMLS and their R forms: the top word of a 64-bit product, optionally rounded.
pub fn TopMultiply(comptime subtract: bool, comptime round: bool) type {
    return struct {
        /// Adds or subtracts Rn * Rm from Ra << 32 and keeps the top word in Rd.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            _ = host;
            const product = @as(i64, @as(i32, @bitCast(root.get(s, n)))) * @as(i64, @as(i32, @bitCast(root.get(s, m))));
            const held = addend(s, a) << 32;
            const total = (if (subtract) held -% product else held +% product) +% (if (round) 0x8000_0000 else 0);
            root.set(s, d, @truncate(@as(u64, @bitCast(total >> 32))));
            return .next;
        }
    };
}

/// SMMLA space with Rd=15 and Ra!=15: AUTG on a PACBTI core, otherwise the multiply.
pub fn Authenticating(comptime subtract: bool, comptime round: bool) type {
    return struct {
        /// Authenticates or multiplies depending on the fields and the core.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            if (d == 15 and a != 15 and host.pacbti()) return pac.autg(root.Host(@TypeOf(host)), s, host, round, @intCast(a), @intCast(n), @intCast(m));
            return TopMultiply(subtract, round).call(s, host, n, a, d, m);
        }
    };
}

/// SMMLS with Ra=15: PACG on a PACBTI core, otherwise the multiply.
pub fn signing(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
    if (a == 15 and host.pacbti()) return pac.pacg(root.Host(@TypeOf(host)), s, host, @intCast(d), @intCast(n), @intCast(m));
    return TopMultiply(true, false).call(s, host, n, a, d, m);
}

/// USAD8 and USADA8: sum of byte absolute differences, plus Ra unless Ra is r15.
pub fn absoluteDifference(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
    _ = host;
    const x = root.get(s, n);
    const y = root.get(s, m);
    var sum: u32 = if (a == 15) 0 else root.get(s, a);
    inline for (0..4) |i| {
        const at: u5 = 8 * i;
        const left = (x >> at) & 0xff;
        const right = (y >> at) & 0xff;
        sum +%= if (left > right) left - right else right - left;
    }
    root.set(s, d, sum);
    return .next;
}

fn accumulateLong(s: *State, l: u32, h: u32, product: i64) void {
    const held: i64 = @bitCast((@as(u64, root.get(s, h)) << 32) | root.get(s, l));
    const sum: u64 = @bitCast(held +% product);
    root.set(s, l, @truncate(sum));
    root.set(s, h, @truncate(sum >> 32));
}

/// SMLALBB and siblings: a halfword product accumulated into the 64-bit pair.
pub fn LongHalfMultiply(comptime n_top: bool, comptime m_top: bool) type {
    return struct {
        /// Accumulates the halfword product of Rn and Rm into RdLo:RdHi.
        pub fn call(s: *State, host: anytype, n: u32, l: u32, h: u32, m: u32) Outcome {
            _ = host;
            accumulateLong(s, l, h, halfOf(root.get(s, n), n_top) * halfOf(root.get(s, m), m_top));
            return .next;
        }
    };
}

/// SMLALD, SMLSLD and their X forms: dual halfword products accumulated into the pair.
pub fn LongDualMultiply(comptime subtract: bool, comptime swap: bool) type {
    return struct {
        /// Accumulates the dual product into RdLo:RdHi.
        pub fn call(s: *State, host: anytype, n: u32, l: u32, h: u32, m: u32) Outcome {
            _ = host;
            accumulateLong(s, l, h, dualProduct(s, n, m, subtract, swap));
            return .next;
        }
    };
}

/// UMAAL: unsigned Rn * Rm plus RdHi plus RdLo into the pair.
pub fn umaal(s: *State, host: anytype, n: u32, l: u32, h: u32, m: u32) Outcome {
    _ = host;
    const sum = @as(u64, root.get(s, n)) * root.get(s, m) + root.get(s, h) + root.get(s, l);
    root.set(s, l, @truncate(sum));
    root.set(s, h, @intCast(sum >> 32));
    return .next;
}
