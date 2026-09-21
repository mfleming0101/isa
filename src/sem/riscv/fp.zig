//! RV32F handlers: the single-precision arithmetic, fused, sign-injection, min/max, compare,
//! classify, conversion and transfer rows, plus the compressed C.FLW, C.FSW, C.FLWSP and C.FSWSP.
//! Every row is illegal with mstatus.FS off and leaves it dirty otherwise, privileged 3.1.6.7.
//! Operands widen to doubles; a result that would round twice is first rounded to odd, then
//! `narrow` rounds it once to a single in the mode asked, detecting tininess after rounding,
//! section 20.4. Flags accrue into fflags. Bound by `sem/riscv/root.zig`.
const std = @import("std");
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const access = root.access;

/// The canonical quiet NaN every NaN result becomes.
pub const canonical: u32 = 0x7fc0_0000;

/// fflags bit NX, inexact.
pub const inexact: u5 = 1;
/// fflags bit UF, underflow.
pub const underflow: u5 = 2;
/// fflags bit OF, overflow.
pub const overflow: u5 = 4;
/// fflags bit DZ, divide by zero.
pub const divide_by_zero: u5 = 8;
/// fflags bit NV, invalid operation.
pub const invalid: u5 = 16;

/// The five rounding modes, section 20.2 table 25.
pub const Mode = enum(u3) { rne, rtz, rdn, rup, rmm };

fn isNan(b: u32) bool {
    return b & 0x7f80_0000 == 0x7f80_0000 and b & 0x7f_ffff != 0;
}

fn isSignalling(b: u32) bool {
    return isNan(b) and b & 0x40_0000 == 0;
}

fn isInfinite(b: u32) bool {
    return b & 0x7fff_ffff == 0x7f80_0000;
}

fn isZero(b: u32) bool {
    return b & 0x7fff_ffff == 0;
}

fn wide(b: u32) f64 {
    return @as(f32, @bitCast(b));
}

/// The FCLASS.S mask of a single's bits: one bit for the kind it is.
pub fn classOf(b: u32) u32 {
    const sign = b >> 31;
    const exponent = (b >> 23) & 0xff;
    const fraction = b & 0x7f_ffff;
    if (exponent == 0xff) {
        if (fraction == 0) return if (sign == 1) 1 << 0 else 1 << 7;
        return if (fraction & 0x40_0000 == 0) 1 << 8 else 1 << 9;
    }
    if (exponent == 0) {
        if (fraction == 0) return if (sign == 1) 1 << 3 else 1 << 4;
        return if (sign == 1) 1 << 2 else 1 << 5;
    }
    return if (sign == 1) 1 << 1 else 1 << 6;
}

/// A single's bits and the flags its rounding raised.
pub const Rounded = struct { bits: u32, flags: u5 };

/// Rounds a double holding one single operation's exact result to a single in the given mode,
/// section 20.4.
pub fn narrow(x: f64, mode: Mode) Rounded {
    const raw: u64 = @bitCast(x);
    const sign: u32 = @intCast(raw >> 63);
    const exponent: i32 = @intCast((raw >> 52) & 0x7ff);
    const fraction: u64 = raw & 0x000f_ffff_ffff_ffff;
    if (exponent == 0x7ff) return .{ .bits = if (fraction != 0) canonical else sign << 31 | 0x7f80_0000, .flags = 0 };
    if (exponent == 0 and fraction == 0) return .{ .bits = sign << 31, .flags = 0 };

    var place: i32 = exponent - 1023 + 127;
    var shift: i32 = 29;
    if (place <= 0) {
        shift += 1 - place;
        place = 0;
    }
    if (shift > 63) return .{ .bits = sign << 31 | @intFromBool(mode == .rup and sign == 0) | @intFromBool(mode == .rdn and sign == 1), .flags = inexact | underflow };

    const whole: u64 = fraction | (1 << 52);
    const kept: u64 = whole >> @intCast(shift);
    const rest: u64 = whole & ((@as(u64, 1) << @intCast(shift)) - 1);
    const half: u64 = @as(u64, 1) << @intCast(shift - 1);
    const up = rest != 0 and switch (mode) {
        .rne => rest > half or (rest == half and kept & 1 != 0),
        .rtz => false,
        .rdn => sign == 1,
        .rup => sign == 0,
        .rmm => rest >= half,
    };
    var value: u64 = kept + @intFromBool(up);
    if (place == 0 and value >> 23 == 1) place = 1;
    if (place != 0) {
        if (value >> 24 == 1) {
            value >>= 1;
            place += 1;
        }
        value &= 0x7f_ffff;
    }
    if (place >= 0xff) {
        const away = switch (mode) {
            .rne, .rmm => true,
            .rtz => false,
            .rdn => sign == 1,
            .rup => sign == 0,
        };
        return .{ .bits = if (away) sign << 31 | 0x7f80_0000 else sign << 31 | 0x7f7f_ffff, .flags = inexact | overflow };
    }
    const bits: u32 = sign << 31 | @as(u32, @intCast(place)) << 23 | @as(u32, @intCast(value));
    const missed = rest != 0;
    return .{ .bits = bits, .flags = if (missed) inexact | (if (place == 0) underflow else 0) else 0 };
}

fn toOdd(value: f64, missed: f64) f64 {
    if (missed == 0 or value == 0 or !std.math.isFinite(value)) return value;
    const bits: u64 = @bitCast(value);
    if (bits & 1 == 1) return value;
    const away = (missed > 0) == (value > 0);
    return @bitCast(if (away) bits + 1 else bits - 1);
}

fn sum(x: f64, y: f64) f64 {
    const total = x + y;
    if (!std.math.isFinite(total)) return total;
    const split = total - x;
    return toOdd(total, (x - (total - split)) + (y - split));
}

fn signedZero(value: f64, mode: Mode) f64 {
    return if (value == 0 and mode == .rdn) -0.0 else value;
}

fn off(s: *const State) bool {
    return s.csr.mstatus.fs == .off;
}

fn touch(s: *State) void {
    s.csr.mstatus.fs = .dirty;
}

fn raise(s: *State, flags: u5) void {
    s.csr.fflags |= flags;
}

fn modeOf(s: *const State, field: u32) ?Mode {
    const m = if (field == 0b111) s.csr.frm else @as(u3, @intCast(field));
    return if (m > 4) null else @enumFromInt(m);
}

fn put(s: *State, d: u32, bits: u32, flags: u5) Outcome {
    s.f[d] = bits;
    raise(s, flags);
    touch(s);
    return .next;
}

fn result(s: *State, d: u32, x: f64, mode: Mode, flags: u5) Outcome {
    const rounded = narrow(x, mode);
    return put(s, d, rounded.bits, rounded.flags | flags);
}

/// The four two-operand arithmetic rows.
pub const Binary = enum { add, sub, mul, div };

/// FADD.S, FSUB.S, FMUL.S and FDIV.S (RV32F): NaN and infinity cases first, then rounded
/// arithmetic, section 20.6.
pub fn Arith(comptime op: Binary) type {
    return struct {
        /// Computes rs1 op rs2 into rd in the mode the rm field or frm names.
        pub fn call(s: *State, _: anytype, m: u32, n: u32, r: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const mode = modeOf(s, r) orelse return .illegal;
            const a = s.f[n];
            const b = s.f[m];
            if (isNan(a) or isNan(b)) {
                const flag: u5 = if (isSignalling(a) or isSignalling(b)) invalid else 0;
                return put(s, d, canonical, flag);
            }
            switch (op) {
                .add, .sub => if (isInfinite(a) and isInfinite(b)) {
                    const opposed = (a >> 31 != b >> 31) == (op == .add);
                    if (opposed) return put(s, d, canonical, invalid);
                },
                .mul => if ((isInfinite(a) and isZero(b)) or (isZero(a) and isInfinite(b))) return put(s, d, canonical, invalid),
                .div => {
                    if ((isZero(a) and isZero(b)) or (isInfinite(a) and isInfinite(b))) return put(s, d, canonical, invalid);
                    if (isZero(b) and !isInfinite(a)) return put(s, d, (a ^ b) & 0x8000_0000 | 0x7f80_0000, divide_by_zero);
                },
            }
            const x = wide(a);
            const y = wide(b);
            return result(s, d, switch (op) {
                .add => signedZero(sum(x, y), mode),
                .sub => signedZero(sum(x, -y), mode),
                .mul => x * y,
                .div => blk: {
                    const quotient = x / y;
                    const missed = @mulAdd(f64, -quotient, y, x);
                    break :blk toOdd(quotient, if (y > 0) missed else -missed);
                },
            }, mode, 0);
        }
    };
}

/// FSQRT.S (RV32F): the square root of rs1, invalid for a negative other than minus zero.
pub fn sqrt(s: *State, _: anytype, n: u32, r: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    const mode = modeOf(s, r) orelse return .illegal;
    const a = s.f[n];
    if (isNan(a)) return put(s, d, canonical, if (isSignalling(a)) invalid else 0);
    if (a >> 31 == 1 and !isZero(a)) return put(s, d, canonical, invalid);
    if (isZero(a) or isInfinite(a)) return put(s, d, a, 0);
    const x = wide(a);
    const root_of = @sqrt(x);
    return result(s, d, toOdd(root_of, @mulAdd(f64, -root_of, root_of, x)), mode, 0);
}

/// FMADD.S, FMSUB.S, FNMSUB.S and FNMADD.S (RV32F): product and addend rounded once, section 20.6.
pub fn Fused(comptime negate_product: bool, comptime negate_addend: bool) type {
    return struct {
        /// Forms the exact product in a double, adds the addend and rounds once into rd.
        pub fn call(s: *State, _: anytype, t: u32, m: u32, n: u32, r: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const mode = modeOf(s, r) orelse return .illegal;
            const a = s.f[n];
            const b = s.f[m];
            const c = s.f[t];
            if (isNan(a) or isNan(b) or isNan(c)) {
                const flag: u5 = if (isSignalling(a) or isSignalling(b) or isSignalling(c)) invalid else 0;
                return put(s, d, canonical, flag);
            }
            if ((isInfinite(a) and isZero(b)) or (isZero(a) and isInfinite(b))) return put(s, d, canonical, invalid);
            var product = wide(a) * wide(b);
            if (negate_product) product = -product;
            var addend = wide(c);
            if (negate_addend) addend = -addend;
            if (std.math.isInf(product) and std.math.isInf(addend) and (product < 0) != (addend < 0)) return put(s, d, canonical, invalid);
            return result(s, d, signedZero(sum(product, addend), mode), mode, 0);
        }
    };
}

/// How a sign-injection row derives the sign: copied, negated, or exclusive-ored.
pub const Sign = enum { copy, negate, exclusive };

/// FSGNJ.S, FSGNJN.S and FSGNJX.S (RV32F): rs1's bits with a sign from rs2, section 20.6; no flags.
pub fn Sgnj(comptime kind: Sign) type {
    return struct {
        /// Writes rs1 with the derived sign to rd.
        pub fn call(s: *State, _: anytype, m: u32, n: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const a = s.f[n];
            const b = s.f[m];
            const sign = switch (kind) {
                .copy => b & 0x8000_0000,
                .negate => ~b & 0x8000_0000,
                .exclusive => (a ^ b) & 0x8000_0000,
            };
            return put(s, d, a & 0x7fff_ffff | sign, 0);
        }
    };
}

/// FMIN.S and FMAX.S (RV32F), section 20.6: NaNs canonicalise or yield the other operand, minus
/// zero is smaller.
pub fn MinMax(comptime want_max: bool) type {
    return struct {
        /// Writes the smaller or larger of rs1 and rs2 to rd, raising invalid for a signalling NaN.
        pub fn call(s: *State, _: anytype, m: u32, n: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const a = s.f[n];
            const b = s.f[m];
            const flag: u5 = if (isSignalling(a) or isSignalling(b)) invalid else 0;
            if (isNan(a) and isNan(b)) return put(s, d, canonical, flag);
            if (isNan(a)) return put(s, d, b, flag);
            if (isNan(b)) return put(s, d, a, flag);
            if (isZero(a) and isZero(b)) {
                const negative = if (want_max) (a >> 31 == 1 and b >> 31 == 1) else (a >> 31 == 1 or b >> 31 == 1);
                return put(s, d, if (negative) 0x8000_0000 else 0, flag);
            }
            const x = wide(a);
            const y = wide(b);
            const pick = if (want_max) x > y else x < y;
            return put(s, d, if (pick) a else b, flag);
        }
    };
}

/// The three comparisons, section 20.8.
pub const Relation = enum { eq, lt, le };

/// FEQ.S, FLT.S and FLE.S (RV32F): a NaN answers zero; FLT and FLE are signalling, FEQ quiet,
/// section 20.8.
pub fn Compare(comptime how: Relation) type {
    return struct {
        /// Writes 1 or 0 to rd for the relation between rs1 and rs2.
        pub fn call(s: *State, _: anytype, m: u32, n: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const a = s.f[n];
            const b = s.f[m];
            if (isNan(a) or isNan(b)) {
                const loud = how != .eq or isSignalling(a) or isSignalling(b);
                if (loud) raise(s, invalid);
                root.write(s, d, 0);
                return .next;
            }
            const x = wide(a);
            const y = wide(b);
            root.write(s, d, @intFromBool(switch (how) {
                .eq => x == y,
                .lt => x < y,
                .le => x <= y,
            }));
            return .next;
        }
    };
}

/// FCLASS.S (RV32F): writes the class mask of rs1 to rd.
pub fn class(s: *State, _: anytype, n: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    root.write(s, d, classOf(s.f[n]));
    return .next;
}

/// FMV.X.W (RV32F): moves rs1's bits unmodified into integer rd.
pub fn moveOut(s: *State, _: anytype, n: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    root.write(s, d, s.f[n]);
    return .next;
}

/// FMV.W.X (RV32F): moves integer rs1's bits unmodified into floating-point rd.
pub fn moveIn(s: *State, _: anytype, n: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    return put(s, d, s.x[n], 0);
}

/// FCVT.W.S and FCVT.WU.S (RV32F): round to a word, section 20.7; NaN or overflow gives the range
/// end and invalid.
pub fn ToInt(comptime signed: bool) type {
    const low: f64 = if (signed) -2147483648.0 else 0.0;
    const high: f64 = if (signed) 2147483647.0 else 4294967295.0;
    const low_bits: u32 = if (signed) 0x8000_0000 else 0;
    const high_bits: u32 = if (signed) 0x7fff_ffff else 0xffff_ffff;
    return struct {
        /// Rounds rs1 toward a word in the mode asked and writes it to integer rd.
        pub fn call(s: *State, _: anytype, n: u32, r: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const mode = modeOf(s, r) orelse return .illegal;
            const a = s.f[n];
            if (isNan(a)) {
                raise(s, invalid);
                root.write(s, d, high_bits);
                return .next;
            }
            const x = wide(a);
            const whole = toward(x, mode);
            if (whole < low or whole > high) {
                raise(s, invalid);
                root.write(s, d, if (x < 0) low_bits else high_bits);
                return .next;
            }
            if (whole != x) raise(s, inexact);
            root.write(s, d, if (signed) @bitCast(@as(i32, @intFromFloat(whole))) else @as(u32, @intFromFloat(whole)));
            return .next;
        }
    };
}

/// FCVT.S.W and FCVT.S.WU (RV32F): a word to a single, section 20.7; over twenty-four significant
/// bits it rounds.
pub fn FromInt(comptime signed: bool) type {
    return struct {
        /// Converts integer rs1, signed or unsigned, to a single in rd.
        pub fn call(s: *State, _: anytype, n: u32, r: u32, d: u32) Outcome {
            if (off(s)) return .illegal;
            const mode = modeOf(s, r) orelse return .illegal;
            const x: f64 = if (signed) @floatFromInt(@as(i32, @bitCast(s.x[n]))) else @floatFromInt(s.x[n]);
            return result(s, d, x, mode, 0);
        }
    };
}

fn toward(x: f64, mode: Mode) f64 {
    return switch (mode) {
        .rne => blk: {
            const down = @floor(x);
            const rest = x - down;
            break :blk if (rest > 0.5) down + 1 else if (rest < 0.5) down else if (@mod(down, 2) == 0) down else down + 1;
        },
        .rtz => @trunc(x),
        .rdn => @floor(x),
        .rup => @ceil(x),
        .rmm => if (x < 0) -@floor(-x + 0.5) else @floor(x + 0.5),
    };
}

/// FLW (RV32F): loads a word from rs1 plus the sign-extended offset into floating-point rd.
pub fn load(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    const value = access.read(@TypeOf(host.*), host, s.csr.implementation.misaligned, s.x[n] +% root.sext(12, i), 32, false) catch |err| return Outcome.faulted(err);
    return put(s, d, value, 0);
}

/// FSW (RV32F): stores floating-point rs2 at rs1 plus the sign-extended offset.
pub fn store(s: *State, host: anytype, i: u32, m: u32, n: u32, j: u32) Outcome {
    if (off(s)) return .illegal;
    access.write(@TypeOf(host.*), host, s.csr.implementation.misaligned, s.x[n] +% root.sext(12, i << 5 | j), 32, s.f[m]) catch |err| return Outcome.faulted(err);
    return .next;
}

/// C.FLW (RV32C with F): loads a word at rs1′ plus the offset scaled by four into rd′, section
/// 27.3.
pub fn clw(s: *State, host: anytype, a: u32, n: u32, i: u32, j: u32, d: u32) Outcome {
    if (off(s)) return .illegal;
    const at = s.x[root.primed(n)] +% (j << 6 | a << 3 | i << 2);
    const value = access.read(@TypeOf(host.*), host, s.csr.implementation.misaligned, at, 32, false) catch |err| return Outcome.faulted(err);
    return put(s, root.primed(d), value, 0);
}

/// C.FSW (RV32C with F): stores rs2′ at rs1′ plus the offset scaled by four, section 27.3.
pub fn csw(s: *State, host: anytype, a: u32, n: u32, i: u32, j: u32, m: u32) Outcome {
    if (off(s)) return .illegal;
    const at = s.x[root.primed(n)] +% (j << 6 | a << 3 | i << 2);
    access.write(@TypeOf(host.*), host, s.csr.implementation.misaligned, at, 32, s.f[root.primed(m)]) catch |err| return Outcome.faulted(err);
    return .next;
}

/// C.FLWSP (RV32C with F): loads a word at sp plus the offset scaled by four into rd, section 27.3.
pub fn lwsp(s: *State, host: anytype, i: u32, d: u32, a: u32, b: u32) Outcome {
    if (off(s)) return .illegal;
    const at = s.x[2] +% (b << 6 | i << 5 | a << 2);
    const value = access.read(@TypeOf(host.*), host, s.csr.implementation.misaligned, at, 32, false) catch |err| return Outcome.faulted(err);
    return put(s, d, value, 0);
}

/// C.FSWSP (RV32C with F): stores rs2 at sp plus the offset scaled by four, section 27.3.
pub fn swsp(s: *State, host: anytype, a: u32, b: u32, m: u32) Outcome {
    if (off(s)) return .illegal;
    access.write(@TypeOf(host.*), host, s.csr.implementation.misaligned, s.x[2] +% (b << 6 | a << 2), 32, s.f[m]) catch |err| return Outcome.faulted(err);
    return .next;
}
