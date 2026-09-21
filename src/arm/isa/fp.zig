//! Arithmetic for the Armv7-M and Armv8-M floating-point extension. Holds the FPSCR
//! field masks, the context check a floating-point instruction runs before executing,
//! the register file accessors, and the rounding, exception-flagging and conversion
//! routines that src/sem/arm/fp.zig and src/sem/arm/mve.zig share.

const std = @import("std");
const access = @import("access.zig");
const instruction = @import("instruction.zig");
const State = @import("state.zig").State;
const Architecture = @import("architecture.zig").Architecture;

const Outcome = instruction.Outcome;
const Failure = instruction.Failure;

/// Mask of the FPSCR condition flags.
pub const nzcv: u32 = 0xf000_0000;
/// FPSCR.LTPSIZE set to four, the value with no tail predication in force.
pub const ltpsize: u32 = 0x4 << 16;
/// Mask of the FPSCR.QC cumulative saturation flag.
pub const qc: u32 = 1 << 27;
/// Mask of the FPSCR.LTPSIZE field.
pub const ltpsize_field: u32 = 0x7 << 16;
const rmode: u32 = 0x3 << 22;
const flush: u32 = 1 << 24;
const flush16: u32 = 1 << 19;
const alternative: u32 = 1 << 26;
const nan_default: u32 = 1 << 25;

/// Mask of the FPSCR.IOC invalid operation flag.
pub const ioc: u32 = 1 << 0;
const dzc: u32 = 1 << 1;
/// Mask of the FPSCR.OFC overflow flag.
pub const ofc: u32 = 1 << 2;
/// Mask of the FPSCR.UFC underflow flag.
pub const ufc: u32 = 1 << 3;
/// Mask of the FPSCR.IXC inexact flag.
pub const ixc: u32 = 1 << 4;
const idc: u32 = 1 << 7;

/// IOC when value is a signalling NaN, otherwise zero.
pub fn signalling(comptime T: type, value: T) u32 {
    const Raw = std.meta.Int(.unsigned, @bitSizeOf(T));
    const top: Raw = @as(Raw, 1) << (std.math.floatMantissaBits(T) - 1);
    const raw: Raw = @bitCast(value);
    return if (std.math.isNan(value) and raw & top == 0) ioc else 0;
}

fn sign(comptime T: type, value: T) i2 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

fn residue(comptime T: type, a: T, b: T, sum: T) T {
    const part = sum - a;
    return (a - (sum - part)) + (b - part);
}

fn drifted(comptime T: type, a: T, b: T, sum: T) i2 {
    const err = residue(T, a, b, sum);
    if (std.math.isFinite(err)) return sign(T, err);
    return side(T, @as(Wide(T), a) + @as(Wide(T), b), 0, sum);
}

fn Wide(comptime T: type) type {
    return if (T == f64) f128 else f64;
}

/// The FPSCR flush-to-zero bit governing T: FZ16 for f16, FZ otherwise.
pub fn flushed(comptime T: type) u32 {
    return if (T == f16) flush16 else flush;
}

fn side(comptime T: type, head: Wide(T), err: Wide(T), result: T) i2 {
    const wide: Wide(T) = result;
    if (head != wide) return if (head > wide) 1 else -1;
    return sign(Wide(T), err);
}

fn multiplied(comptime T: type, x: T, y: T, result: T) i2 {
    return side(T, @as(Wide(T), x) * @as(Wide(T), y), 0, result);
}

fn quotient(comptime T: type, x: T, y: T, result: T) i2 {
    const W = Wide(T);
    const rest = @as(W, x) - @as(W, result) * @as(W, y);
    return sign(W, if (y < 0) -rest else rest);
}

/// Direction a square root result was rounded, judged from x minus its square.
pub fn root(comptime T: type, x: T, result: T) i2 {
    const W = Wide(T);
    return sign(W, @as(W, x) - @as(W, result) * @as(W, result));
}

fn chain(comptime T: type, x: T, y: T, c: T, result: T) i2 {
    const W = Wide(T);
    const head = @as(W, x) * @as(W, y);
    const total = head + @as(W, c);
    return side(T, total, residue(W, head, c, total), result);
}

fn upward(comptime T: type, value: T) T {
    const Raw = std.meta.Int(.unsigned, @bitSizeOf(T));
    const top: Raw = @as(Raw, 1) << (@bitSizeOf(T) - 1);
    const raw: Raw = @bitCast(value);
    if (raw == top) return @bitCast(@as(Raw, 1));
    return @bitCast(if (raw & top != 0) raw - 1 else raw + 1);
}

fn downward(comptime T: type, value: T) T {
    return -upward(T, -value);
}

fn steered(comptime T: type, mode: u32, value: T, direction: i2) T {
    return switch (mode) {
        1 => if (direction > 0) upward(T, value) else value,
        2 => if (direction < 0) downward(T, value) else value,
        3 => if (value > 0 and direction < 0) downward(T, value) else if (value < 0 and direction > 0) upward(T, value) else value,
        else => value,
    };
}

fn limited(comptime T: type, mode: u32, value: T) T {
    const largest = std.math.floatMax(T);
    return switch (mode) {
        1 => if (value < 0) -largest else value,
        2 => if (value > 0) largest else value,
        3 => if (value < 0) -largest else largest,
        else => value,
    };
}

/// OFC when the exact result's magnitude exceeds T's exponent range, otherwise zero.
pub fn overflowed(comptime T: type, exact: anytype) u32 {
    const W = @TypeOf(exact);
    return if (@abs(exact) >= std.math.ldexp(@as(W, 1.0), std.math.floatExponentMax(T) + 1)) ofc else 0;
}

fn outsized(comptime From: type, comptime To: type, value: From) bool {
    return @abs(value) >= std.math.ldexp(@as(From, 1.0), std.math.floatExponentMax(To) + 1);
}

fn tiny(comptime T: type, result: T, direction: i2) bool {
    const smallest = std.math.floatMin(T);
    const magnitude = @abs(result);
    if (magnitude != smallest) return magnitude < smallest;
    return if (result > 0) direction < 0 else direction > 0;
}

fn cancelled(comptime T: type, s: *const State, negative: bool, other: bool, sum: T, exact: bool) T {
    if (sum != 0 or !exact or negative == other) return sum;
    return if ((s.fpscr & rmode) >> 22 == 2) -@as(T, 0.0) else 0.0;
}

/// Applies the rounding mode and flush-to-zero to a result and accumulates its exception flags in FPSCR.
pub fn raise(s: *State, comptime T: type, result: T, direction: i2, overflow: bool, nan_operand: bool, extra: u32) T {
    var flags = extra;
    var value = result;
    const mode = (s.fpscr & rmode) >> 22;
    if (std.math.isNan(result)) {
        if (!nan_operand) flags |= ioc;
        if (s.fpscr & nan_default != 0) value = std.math.nan(T);
    } else if (overflow) {
        flags |= ixc;
        value = limited(T, mode, result);
        if (std.math.isInf(value)) flags |= ofc;
    } else if (direction != 0) {
        flags |= ixc;
        value = steered(T, mode, result, direction);
        if (std.math.isInf(value)) {
            flags |= ofc;
        } else if (tiny(T, result, direction)) flags |= ufc;
    }
    if (s.fpscr & flushed(T) != 0 and (result != 0 or direction != 0) and tiny(T, result, direction)) {
        value = if (std.math.signbit(value)) -@as(T, 0.0) else 0.0;
        flags = (flags & ~ixc) | ufc;
    }
    s.fpscr |= flags;
    return value;
}

/// Converts From to the narrower To, rounding per FPSCR and raising the flags the conversion earns.
pub fn narrowed(s: *State, comptime From: type, comptime To: type, value: From) To {
    const result: To = @floatCast(value);
    var narrow = result;
    var flags = signalling(From, value);
    const mode = (s.fpscr & rmode) >> 22;
    if (std.math.isNan(value)) {
        if (s.fpscr & nan_default != 0) narrow = std.math.nan(To);
    } else if (std.math.isInf(result) and !std.math.isInf(value)) {
        flags |= ixc;
        narrow = limited(To, mode, result);
        if (std.math.isInf(narrow) or outsized(From, To, value)) flags |= ofc;
    } else if (@as(From, result) != value) {
        flags |= ixc;
        narrow = steered(To, mode, result, if (value > @as(From, result)) 1 else -1);
        if (std.math.isInf(narrow)) {
            flags |= ofc;
        } else if (@abs(value) < @as(From, std.math.floatMin(To))) flags |= ufc;
    }
    if (To != f16 and s.fpscr & flush != 0 and value != 0 and @abs(value) < @as(From, std.math.floatMin(To))) {
        narrow = if (std.math.signbit(narrow)) -@as(To, 0.0) else 0.0;
        flags = (flags & ~ixc) | ufc;
    }
    s.fpscr |= flags;
    return narrow;
}

fn expanded(comptime To: type, raw: u16) To {
    const fraction: To = @floatFromInt(raw & 0x3ff);
    const magnitude: To = if (raw & 0x7c00 == 0)
        std.math.ldexp(fraction, -24)
    else
        std.math.ldexp(1 + fraction / 1024, @as(i32, @intCast((raw >> 10) & 0x1f)) - 15);
    return if (raw & 0x8000 != 0) -magnitude else magnitude;
}

fn shrunk(s: *State, comptime From: type, value: From) u16 {
    const top: u16 = if (std.math.signbit(value)) 0x8000 else 0;
    if (s.fpscr & alternative == 0) return @bitCast(narrowed(s, From, f16, value));
    if (std.math.isNan(value)) {
        s.fpscr |= ioc;
        return top;
    }
    if (std.math.isInf(value)) {
        s.fpscr |= ioc;
        return top | 0x7fff;
    }
    const tiny_enough = @abs(value) < std.math.ldexp(@as(From, 1.0), -13);
    const before = s.fpscr;
    s.fpscr &= ~ofc;
    const narrow: u16 = @bitCast(narrowed(s, From, f16, if (tiny_enough) value else value * 0.5));
    const over = s.fpscr & ofc != 0;
    s.fpscr |= before & ofc;
    if (tiny_enough) return narrow;
    if (over) {
        s.fpscr = before | ioc;
        return top | 0x7fff;
    }
    return narrow + 0x400;
}

/// Converts From to the wider To, defaulting a NaN when FPSCR.DN asks.
pub fn widened(s: *State, comptime From: type, comptime To: type, value: From) To {
    s.fpscr |= signalling(From, value);
    if (std.math.isNan(value) and s.fpscr & nan_default != 0) return std.math.nan(To);
    return @floatCast(value);
}

/// Converts a rounded float to Int, saturating and raising IOC or IXC.
pub fn integer(s: *State, comptime Int: type, comptime T: type, value: T, rounded: T) u32 {
    var flags = signalling(T, value);
    const low: f64 = @floatFromInt(std.math.minInt(Int));
    const high: f64 = @floatFromInt(std.math.maxInt(Int));
    const wide: f64 = rounded;
    if (std.math.isNan(value) or wide < low or wide > high) {
        flags |= ioc;
    } else if (rounded != value) {
        flags |= ixc;
    }
    s.fpscr |= flags;
    return saturated(Int, T, rounded);
}

/// Two-operand floating-point operations.
pub const Arithmetic = enum { add, sub, mul, nmul, div };
/// Multiply-accumulate variants: the chained VMLA family and the fused VFMA family.
pub const Accumulate = enum { mla, mls, nmla, nmls, fma, fms, fnma, fnms };
/// One-operand floating-point operations.
pub const Simple = enum { move, abs, negate, root };
/// Rounding modes: directed, FPSCR-current, or current with inexact reported.
pub const Rounding = enum { away, even, plus, minus, zero, current, exact };
/// Conversion directions between float, integer and half precision.
pub const Cast = enum {
    from_unsigned,
    from_signed,
    to_unsigned,
    to_signed,
    to_unsigned_round,
    to_signed_round,
    from_half_low,
    from_half_high,
    to_half_low,
    to_half_high,
};

fn quieted(comptime T: type, value: T) T {
    const Raw = std.meta.Int(.unsigned, @bitSizeOf(T));
    const top: Raw = @as(Raw, 1) << (std.math.floatMantissaBits(T) - 1);
    return @bitCast(@as(Raw, @bitCast(value)) | top);
}

/// Pins FPSCR.LTPSIZE to four in an Armv8.1-M value, its fixed reading without MVE.
pub fn fixedFields(architecture: Architecture, value: u32) u32 {
    return if (architecture == .armv8_1m_main) (value & ~ltpsize_field) | ltpsize else value;
}

/// The live FPSCR.LTPSIZE, or four when no floating-point context is active.
pub fn tailSize(s: *const State) u32 {
    return if (s.control & State.control_fpca == 0) 4 else s.fpscr >> 16 & 7;
}

/// The FPSCR value a write leaves, pinning LTPSIZE where the core lacks MVE.
pub fn written(comptime Host: type, host: *Host, value: u32) u32 {
    return if (host.mve()) value else fixedFields(host.architecture(), value);
}

fn created(architecture: Architecture, held: u32, default: u32) u32 {
    const fields: u32 = 0x07c0_0000;
    return switch (architecture) {
        .armv7m, .armv7em => (held & ~fields) | (default & fields),
        else => default,
    };
}

fn claim(s: *State) void {
    s.control |= State.control_fpca | (if (s.secure) State.control_sfpa else 0);
}

/// ExecuteFPCheck, E2.1.127: refuses without CP10, preserves a lazy frame and creates a context when none is live.
pub fn check(comptime Host: type, s: *State, host: *Host) Failure!?Outcome {
    if (!host.coprocessorEnabled()) return .no_coprocessor;
    if (host.lazyFpFrame()) |frame| try preserve(Host, s, host, frame);
    if (host.automaticFpState() and
        (s.control & State.control_fpca == 0 or (s.secure and s.control & State.control_sfpa == 0)))
    {
        s.fpscr = created(host.architecture(), s.fpscr, host.defaultFpscr());
        s.vpr = 0;
    }
    claim(s);
    return null;
}

noinline fn preserve(comptime Host: type, s: *State, host: *Host, frame: u32) Failure!void {
    const callee = host.lazyFpCallee();
    try transferFrame(Host, s, host, frame, false, callee);
    invalidate(s, callee);
    host.setLazyFp(null);
}

/// Zeroes the register file, FPSCR and VPR after a callee-saving lazy preservation.
pub fn invalidate(s: *State, callee: bool) void {
    if (!callee) return;
    for (&s.fp) |*r| r.* = 0;
    s.fpscr = 0;
    s.vpr = 0;
}

/// Loads or stores the s0-s15, FPSCR, VPR and optionally s16-s31 extended frame at frame.
pub fn transferFrame(comptime Host: type, s: *State, host: *Host, frame: u32, comptime load: bool, callee: bool) Failure!void {
    for (0..16) |i| {
        const at = frame +% 4 * @as(u32, @intCast(i));
        if (load) s.fp[i] = try access.read(Host, host, at, 32, false, true) else try access.write(Host, host, at, 32, s.fp[i], true);
    }
    if (load) s.fpscr = written(Host, host, try access.read(Host, host, frame +% 0x40, 32, false, true)) else try access.write(Host, host, frame +% 0x40, 32, s.fpscr, true);
    if (host.mve()) {
        if (load) s.vpr = try access.read(Host, host, frame +% 0x44, 32, false, true) else try access.write(Host, host, frame +% 0x44, 32, s.vpr, true);
    }
    if (!callee) return;
    for (16..32) |i| {
        const at = frame +% 0x48 +% 4 * @as(u32, @intCast(i - 16));
        if (load) s.fp[i] = try access.read(Host, host, at, 32, false, true) else try access.write(Host, host, at, 32, s.fp[i], true);
    }
}

/// The raw bits of register i read at T's width; f64 spans two words.
pub fn word(s: *const State, comptime T: type, i: u5) std.meta.Int(.unsigned, @bitSizeOf(T)) {
    if (T == f16) return @truncate(s.fp[i]);
    if (T == f32) return s.fp[i];
    return @as(u64, s.fp[i + 1]) << 32 | s.fp[i];
}

/// Writes T-width bits to register i; f64 spans two words.
pub fn store(s: *State, comptime T: type, i: u5, value: std.meta.Int(.unsigned, @bitSizeOf(T))) void {
    if (T == f16) {
        s.fp[i] = value;
        return;
    }
    if (T == f32) {
        s.fp[i] = value;
        return;
    }
    s.fp[i] = @truncate(value);
    s.fp[i + 1] = @truncate(value >> 32);
}

/// Flushes a denormal operand to zero when FPSCR asks, raising IDC except for f16.
pub fn admitted(s: *State, comptime T: type, value: T) T {
    if (s.fpscr & flushed(T) != 0 and value != 0 and std.math.isFinite(value) and !std.math.isNormal(value)) {
        if (T != f16) s.fpscr |= idc;
        return if (std.math.signbit(value)) -@as(T, 0.0) else 0.0;
    }
    return value;
}

/// Mask of the FPSCR mode bits DN, FZ and RMode.
pub const modes: u32 = nan_default | flush | rmode;
/// DN and FZ set with round-to-nearest, the modes MVE floating-point arithmetic runs under.
pub const standard: u32 = nan_default | flush;

/// Reads register i as T, flushing a denormal as FPSCR asks.
pub fn get(s: *State, comptime T: type, i: u5) T {
    return admitted(s, T, @bitCast(word(s, T, i)));
}

/// Writes value to register i as T.
pub fn put(s: *State, comptime T: type, i: u5, value: T) void {
    store(s, T, i, @bitCast(value));
}

/// VFPExpandImm: widens an 8-bit immediate into T's encoding.
pub fn expandImm(comptime T: type, imm8: u32) std.meta.Int(.unsigned, @bitSizeOf(T)) {
    const Raw = std.meta.Int(.unsigned, @bitSizeOf(T));
    const exponent = @bitSizeOf(T) - std.math.floatMantissaBits(T) - 1;
    const a: Raw = @intCast((imm8 >> 7) & 1);
    const b: Raw = @intCast((imm8 >> 6) & 1);
    const filled: Raw = if (b != 0) (@as(Raw, 1) << (exponent - 3)) - 1 else 0;
    const shift = std.math.floatMantissaBits(T) - 4;
    return (a << (@bitSizeOf(T) - 1)) | ((1 - b) << (@bitSizeOf(T) - 2)) | (filled << (shift + 6)) | (@as(Raw, @intCast(imm8 & 0x3f)) << shift);
}

fn chosen(comptime T: type, operands: []const T) ?T {
    for (operands) |value| if (signalling(T, value) != 0) return quieted(T, value);
    for (operands) |value| if (std.math.isNan(value)) return value;
    return null;
}

/// Performs VADD, VSUB, VMUL, VNMUL or VDIV on x and y with IEEE rounding and FPSCR flags.
pub fn arithmetic(s: *State, comptime kind: Arithmetic, comptime T: type, x: T, y: T) T {
    const raw_result: T = chosen(T, &.{ x, y }) orelse switch (kind) {
        .add => x + y,
        .sub => x - y,
        .mul, .nmul => x * y,
        .div => x / y,
    };
    const direction: i2 = switch (kind) {
        .add => drifted(T, x, y, raw_result),
        .sub => drifted(T, x, -y, raw_result),
        .mul, .nmul => multiplied(T, x, y, raw_result),
        .div => quotient(T, x, y, raw_result),
    };
    const result: T = switch (kind) {
        .add => cancelled(T, s, std.math.signbit(x), std.math.signbit(y), raw_result, direction == 0),
        .sub => cancelled(T, s, std.math.signbit(x), !std.math.signbit(y), raw_result, direction == 0),
        else => raw_result,
    };
    const divided: u32 = if (kind == .div and y == 0 and x != 0 and !std.math.isNan(x) and !std.math.isInf(x)) dzc else 0;
    const nan_operand = std.math.isNan(x) or std.math.isNan(y);
    const finite = !std.math.isInf(x) and !std.math.isInf(y) and (kind != .div or y != 0);
    const overflow = std.math.isInf(result) and finite;
    const spilled: u32 = if (overflow) overflowed(T, switch (kind) {
        .add => @as(Wide(T), x) + @as(Wide(T), y),
        .sub => @as(Wide(T), x) - @as(Wide(T), y),
        .mul, .nmul => @as(Wide(T), x) * @as(Wide(T), y),
        .div => @as(Wide(T), x) / @as(Wide(T), y),
    }) else 0;
    return raise(s, T, result, direction, overflow, nan_operand, spilled | divided | signalling(T, x) | signalling(T, y));
}

/// Whether kind is a chained, unfused multiply-accumulate.
pub fn chained(comptime kind: Accumulate) bool {
    return kind == .mla or kind == .mls or kind == .nmla or kind == .nmls;
}

/// Multiply-accumulate; chained kinds round the product first, fused kinds round once.
pub fn accumulate(s: *State, comptime kind: Accumulate, comptime T: type, x: T, y: T, held: T) T {
    if (!chained(kind)) return multiplyAdd(s, kind, T, x, y, held);
    const raw_product = chosen(T, &.{ x, y }) orelse x * y;
    const both = std.math.isNan(x) or std.math.isNan(y);
    const over = std.math.isInf(raw_product) and !std.math.isInf(x) and !std.math.isInf(y);
    const wide: u32 = if (over) overflowed(T, @as(Wide(T), x) * @as(Wide(T), y)) else 0;
    const made = raise(s, T, raw_product, multiplied(T, x, y, raw_product), over, both, wide | signalling(T, x) | signalling(T, y));
    const addend: T = if (kind == .nmla or kind == .nmls) -held else held;
    const signed: T = if (kind == .mls or kind == .nmla) -made else made;
    const raw_total = chosen(T, &.{ addend, signed }) orelse addend + signed;
    const drift = drifted(T, addend, signed, raw_total);
    const total = cancelled(T, s, std.math.signbit(addend), std.math.signbit(signed), raw_total, drift == 0);
    const nan_operand = std.math.isNan(addend) or std.math.isNan(signed);
    const beyond = std.math.isInf(total) and !std.math.isInf(addend) and !std.math.isInf(signed);
    const wider: u32 = if (beyond) overflowed(T, @as(Wide(T), addend) + @as(Wide(T), signed)) else 0;
    return raise(s, T, total, drift, beyond, nan_operand, wider | signalling(T, addend));
}

/// Fused multiply-add for VFMA, VFMS, VFNMA and VFNMS, rounded once.
pub fn multiplyAdd(s: *State, comptime kind: Accumulate, comptime T: type, x: T, y: T, held: T) T {
    const a: T = if (kind == .fms or kind == .fnma) -x else x;
    const c: T = if (kind == .fnma or kind == .fnms) -held else held;
    const nan_operand = std.math.isNan(a) or std.math.isNan(y) or std.math.isNan(c);
    const impossible = (std.math.isInf(a) and y == 0) or (a == 0 and std.math.isInf(y));
    const forced = impossible and signalling(T, c) == 0;
    const raw_result = if (forced) std.math.nan(T) else chosen(T, &.{ c, a, y }) orelse @mulAdd(T, a, y, c);
    const drift = chain(T, a, y, c, raw_result);
    const result = cancelled(T, s, std.math.signbit(a) != std.math.signbit(y), std.math.signbit(c), raw_result, drift == 0);
    const factors = !std.math.isInf(x) and !std.math.isInf(y);
    const spilled = std.math.isInf(result) and factors and !std.math.isInf(c);
    const wider: u32 = if (spilled) overflowed(T, @as(Wide(T), a) * @as(Wide(T), y) + @as(Wide(T), c)) else 0;
    return raise(s, T, result, drift, spilled, nan_operand, wider | signalling(T, a) | signalling(T, y) | signalling(T, c) | (if (impossible) ioc else 0));
}

/// Quiets or defaults a NaN as FPSCR.DN asks, leaving numbers alone.
pub fn converted(s: *State, comptime T: type, value: T) T {
    if (!std.math.isNan(value)) return value;
    s.fpscr |= signalling(T, value);
    return if (s.fpscr & nan_default != 0) std.math.nan(T) else quieted(T, value);
}

/// VMAXNM or VMINNM of x and y, raising the flags a signalling NaN earns.
pub fn extremum(s: *State, comptime T: type, comptime largest: bool, x: T, y: T) T {
    const answer = extreme(T, largest, x, y);
    const nan_operand = std.math.isNan(x) or std.math.isNan(y);
    return raise(s, T, answer, 0, false, nan_operand, signalling(T, x) | signalling(T, y));
}

fn extreme(comptime T: type, comptime largest: bool, x: T, y: T) T {
    if (signalling(T, x) != 0) return quieted(T, x);
    if (signalling(T, y) != 0) return quieted(T, y);
    if (std.math.isNan(x)) return if (std.math.isNan(y)) x else y;
    if (std.math.isNan(y)) return x;
    if (x == 0 and y == 0) {
        const negative = if (largest) std.math.signbit(x) and std.math.signbit(y) else std.math.signbit(x) or std.math.signbit(y);
        return if (negative) -@as(T, 0.0) else 0.0;
    }
    const takes = if (largest) x > y else x < y;
    return if (takes) x else y;
}

/// Rounds value to an integral float by kind, keeping a negative zero's sign.
pub fn integral(s: *const State, comptime T: type, comptime kind: Rounding, value: T) T {
    const result = switch (kind) {
        .away => @round(value),
        .even => ties(T, value),
        .plus => @ceil(value),
        .minus => @floor(value),
        .zero => @trunc(value),
        .current, .exact => nearest(s, T, value),
    };
    return if (result == 0 and std.math.signbit(value)) -@as(T, 0.0) else result;
}

/// VRINT: rounds by kind, quiets a NaN and reports inexact only for the exact kind.
pub fn integralOf(s: *State, comptime kind: Rounding, comptime T: type, value: T) T {
    const settled = std.math.isNan(value) or std.math.isInf(value);
    const answer = if (std.math.isNan(value)) quieted(T, value) else if (settled) value else integral(s, T, kind, value);
    const inexact = kind == .exact and !settled and answer != value;
    return raise(s, T, answer, 0, false, std.math.isNan(value), signalling(T, value) | (if (inexact) ixc else 0));
}

/// Converts a float scaled by places into Int with rounding kind, saturating.
pub fn toFixed(s: *State, comptime Int: type, comptime T: type, comptime kind: Rounding, value: T, places: i32) u32 {
    const scaled = if (std.math.isFinite(value) and value != 0) std.math.ldexp(value, places) else value;
    const settled = if (std.math.isNan(scaled) or std.math.isInf(scaled)) scaled else integral(s, T, kind, scaled);
    return integer(s, Int, T, scaled, settled);
}

/// Converts raw as a fixed-point Int with places fraction bits to T.
pub fn fromFixed(s: *State, comptime Int: type, comptime T: type, raw: u32, places: i32) T {
    const source: i64 = if (@typeInfo(Int).int.signedness == .signed) @as(Int, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(Int)), @truncate(raw)))) else @as(Int, @truncate(raw));
    const whole: f64 = @floatFromInt(source);
    const exact = if (source == 0) whole else std.math.ldexp(whole, -places);
    const value: T = @floatCast(exact);
    const back: f64 = value;
    const direction: i2 = if (exact > back) 1 else if (exact < back) -1 else 0;
    const overflow = std.math.isInf(value);
    return raise(s, T, value, direction, overflow, false, if (overflow) overflowed(T, exact) else 0);
}

/// Widens a half to T, using the alternative format when FPSCR.AHP is set.
pub fn fromHalf(s: *State, comptime T: type, raw: u16) T {
    return if (s.fpscr & alternative != 0) expanded(T, raw) else widened(s, f16, T, @bitCast(raw));
}

/// Narrows T to a half, using the alternative format when FPSCR.AHP is set.
pub fn toHalf(s: *State, comptime T: type, value: T) u16 {
    return shrunk(s, T, value);
}

/// Converts rounded to Int, saturating with IOC out of range and IXC when inexact.
pub fn clamped(s: *State, comptime Int: type, comptime T: type, value: T, rounded: T, flagged: u32) Int {
    var flags = flagged;
    const low: f64 = @floatFromInt(std.math.minInt(Int));
    const high: f64 = @floatFromInt(std.math.maxInt(Int));
    const wide: f64 = rounded;
    if (std.math.isNan(value) or wide < low or wide > high) {
        s.fpscr |= flags | ioc;
        if (std.math.isNan(value)) return 0;
        return if (wide < low) std.math.minInt(Int) else std.math.maxInt(Int);
    }
    if (rounded != value) flags |= ixc;
    s.fpscr |= flags;
    return @intFromFloat(rounded);
}

fn saturated(comptime Int: type, comptime T: type, value: T) u32 {
    const Raw = std.meta.Int(.unsigned, @bitSizeOf(Int));
    if (std.math.isNan(value)) return 0;
    const low: T = @floatFromInt(std.math.minInt(Int));
    const high: T = @floatFromInt(std.math.maxInt(Int));
    if (value <= low) return @as(Raw, @bitCast(@as(Int, std.math.minInt(Int))));
    if (value >= high) return @as(Raw, @bitCast(@as(Int, std.math.maxInt(Int))));
    return @as(Raw, @bitCast(@as(Int, @intFromFloat(value))));
}

/// Rounds value to an integer under the FPSCR.RMode in force.
pub fn nearest(s: *const State, comptime T: type, value: T) T {
    return switch ((s.fpscr & rmode) >> 22) {
        1 => @ceil(value),
        2 => @floor(value),
        3 => @trunc(value),
        else => ties(T, value),
    };
}

fn ties(comptime T: type, value: T) T {
    const down = @floor(value);
    const rest = value - down;
    if (rest > 0.5) return down + 1;
    if (rest < 0.5) return down;
    return if (@rem(down, 2) == 0) down else down + 1;
}

/// Loads or stores register d as T at address at, one word or half at a time.
pub fn transfer(comptime Host: type, s: *State, host: *Host, comptime T: type, comptime load: bool, d: u5, at: u32) Failure!void {
    if (T == f16) {
        if (load) {
            s.fp[d] = try access.read(Host, host, at, 16, false, true);
        } else {
            try access.write(Host, host, at, 16, word(s, f16, d), true);
        }
        return;
    }
    const words = @bitSizeOf(T) / 32;
    inline for (0..words) |i| {
        const which: u5 = d + @as(u5, @intCast(i));
        if (load) {
            s.fp[which] = try access.read(Host, host, at +% 4 * @as(u32, @intCast(i)), 32, false, true);
        } else {
            try access.write(Host, host, at +% 4 * @as(u32, @intCast(i)), 32, s.fp[which], true);
        }
    }
}

/// Reads base register n, with r15 reading as the aligned PC plus four.
pub fn literal(s: *const State, n: u4) u32 {
    return if (n == 15) (s.pc +% 4) & ~@as(u32, 3) else s.get(n);
}

/// Floating-point system registers VMRS, VMSR, VLDR and VSTR can name.
pub const SystemRegister = enum { fpscr, nzcvqc, vpr, p0, fpcxt_ns, fpcxt_s };

const nzcvqc_field: u32 = 0xf800_0000;
const fpcxt_payload: u32 = 0x0fff_ffff;
const p0_field: u32 = 0xffff;

/// Whether no floating-point context is live, so FPCXT_NS accesses take their inactive path.
pub fn contextInactive(comptime Host: type, s: *const State, host: *Host) bool {
    return !host.treatAsSecure() or (host.automaticFpState() and s.control & State.control_fpca == 0);
}

fn takeContext(s: *State, value: u32) void {
    s.control = (s.control & ~State.control_sfpa) | (value >> 31 << 3);
    s.fpscr = value & fpcxt_payload;
}

fn contextWord(s: *const State) u32 {
    return (s.control & State.control_sfpa) << 28 | (s.fpscr & fpcxt_payload);
}

/// Whether which is FPCXT_NS or FPCXT_S.
pub fn context(which: SystemRegister) bool {
    return which == .fpcxt_ns or which == .fpcxt_s;
}

/// Pre-transfer check for a system register, C2.4.406: FPCXT_NS never creates a context, others take check.
pub fn reachSystem(comptime Host: type, s: *State, host: *Host, which: SystemRegister, inactive: bool) Failure!?Outcome {
    if (which != .fpcxt_ns) return check(Host, s, host);
    if (!inactive) {
        if (!host.coprocessorEnabled()) return .no_coprocessor;
        if (host.lazyFpFrame()) |frame| try preserve(Host, s, host, frame);
    }
    return null;
}

/// Writes value into the named system register, honouring MVE and privilege for VPR and P0.
pub fn takeSystem(comptime Host: type, s: *State, host: *Host, which: SystemRegister, value: u32, inactive: bool) void {
    switch (which) {
        .fpscr => s.fpscr = written(Host, host, value),
        .nzcvqc => s.fpscr = (s.fpscr & ~nzcvqc_field) | (value & nzcvqc_field),
        .vpr => if (host.mve() and s.privileged()) {
            s.vpr = value;
        },
        .p0 => if (host.mve()) {
            s.vpr = (s.vpr & ~p0_field) | (value & p0_field);
        },
        .fpcxt_ns => if (host.treatAsSecure() and !inactive) takeContext(s, value),
        .fpcxt_s => takeContext(s, value),
    }
}

/// Reads the named system register, VPR reading as zero without MVE or privilege.
pub fn systemWord(comptime Host: type, s: *const State, host: *Host, which: SystemRegister, inactive: bool) u32 {
    return switch (which) {
        .fpscr => s.fpscr,
        .nzcvqc => s.fpscr & nzcvqc_field,
        .vpr => if (host.mve() and s.privileged()) s.vpr else 0,
        .p0 => s.vpr & p0_field,
        .fpcxt_ns => if (inactive) host.nonSecureFpscr() & fpcxt_payload else contextWord(s),
        .fpcxt_s => contextWord(s),
    };
}

/// After an FPCXT write, reloads FPSCR from the Non-secure copy and clears SFPA for FPCXT_S.
pub fn afterSystemWrite(comptime Host: type, s: *State, host: *Host, which: SystemRegister, inactive: bool) void {
    switch (which) {
        .fpcxt_ns => if (!inactive and s.control & State.control_sfpa == 0) {
            s.fpscr = host.nonSecureFpscr();
        },
        .fpcxt_s => {
            s.fpscr = host.nonSecureFpscr();
            s.control &= ~State.control_sfpa;
        },
        else => {},
    }
}
