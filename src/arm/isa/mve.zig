//! Lane helpers for the Armv8.1-M MVE vector extension: the predicate and tail masks, the
//! lane accessors of a vector register, the saturating lane operations and the
//! floating-point lane conversions the semantics in src/sem/arm/mve.zig call while
//! executing a vector row.

const std = @import("std");
const State = @import("state.zig").State;
const fp = @import("fp.zig");

/// Mask of the P0 predicate field in VPR.
pub const p0: u32 = 0xffff;
/// Mask of the VPR block mask for beats 0 and 1.
pub const mask01: u32 = 0xf << 16;
/// Mask of the VPR block mask for beats 2 and 3.
pub const mask23: u32 = 0xf << 20;

/// Combines P0, the block masks and the tail count into a per-byte lane mask.
pub fn predicate(s: *const State) u32 {
    var out: u32 = s.vpr & p0;
    if (s.vpr & mask01 == 0) out |= 0x00ff;
    if (s.vpr & mask23 == 0) out |= 0xff00;
    const size = fp.tailSize(s);
    if (size < 4) out &= upTo(s.lr, @intCast(size));
    return out;
}

/// Byte mask covering the first count elements of the given size.
pub fn upTo(count: u32, size: u5) u32 {
    if (count > @as(u32, 16) >> size) return p0;
    return (@as(u32, 1) << @intCast(count << size)) - 1;
}

/// Writes the FPSCR.LTPSIZE field.
pub fn setTailSize(s: *State, size: u32) void {
    s.fpscr = (s.fpscr & ~fp.ltpsize_field) | (size << 16);
}

/// Whether element i's first byte is predicated on; that byte alone governs flags and accesses, C2.4.434.
pub fn active(mask: u32, comptime esize: u8, i: u32) bool {
    return mask >> @intCast(i * (esize / 8)) & 1 != 0;
}

/// Bits of element i's bytes the predicate leaves on.
pub fn bytesOn(mask: u32, comptime esize: u8, i: u32) u32 {
    return mask >> @intCast(i * (esize / 8)) & ((1 << (esize / 8)) - 1);
}

/// Writes only the bytes of element i the predicate leaves on, C2.4.304.
pub fn merge(s: *State, mask: u32, d: u3, comptime esize: u8, i: u32, value: u32) void {
    const on = bytesOn(mask, esize, i);
    if (on == (1 << (esize / 8)) - 1) return setLane(s, d, esize, i, value);
    inline for (0..esize / 8) |b| {
        if (on >> b & 1 != 0) setLane(s, d, 8, i * (esize / 8) + @as(u32, b), value >> (8 * b) & 0xff);
    }
}

/// Restores FPSCR flags raised by a lane whose first byte is predicated off, C2.4.303.
pub fn quiet(s: *State, mask: u32, comptime esize: u8, i: u32, flags: u32) void {
    if (!active(mask, esize, i)) s.fpscr = flags;
}

/// Steps the VPR block masks by one beat, inverting the P0 halves they ask for.
pub fn advance(s: *State) void {
    inline for ([_]u5{ 16, 20 }, [_]u32{ 0x00ff, 0xff00 }) |shift, half| {
        const state = (s.vpr >> shift) & 0xf;
        if (state != 0) {
            if (state != 8 and state & 8 != 0) s.vpr ^= half;
            s.vpr = (s.vpr & ~(@as(u32, 0xf) << shift)) | ((if (state == 8) @as(u32, 0) else (state << 1) & 0xf) << shift);
        }
    }
}

/// Reads element i of size esize from vector register d.
pub fn lane(s: *const State, d: u3, comptime esize: u8, i: u32) u32 {
    return part(whole(s, d), esize, i);
}

/// The four words of vector register d.
pub fn whole(s: *const State, d: u3) *const [4]u32 {
    return s.fp[@as(u32, d) * 4 ..][0..4];
}

/// Extracts element i of size esize from four words.
pub fn part(v: *const [4]u32, comptime esize: u8, i: u32) u32 {
    const word = v[i / (32 / esize)];
    if (esize == 32) return word;
    return (word >> @intCast(i % (32 / esize) * esize)) & ((@as(u32, 1) << esize) - 1);
}

/// Writes element i of size esize in vector register d.
pub fn setLane(s: *State, d: u3, comptime esize: u8, i: u32, value: u32) void {
    const at = &s.fp[@as(u32, d) * 4 + i / (32 / esize)];
    if (esize == 32) {
        at.* = value;
        return;
    }
    const shift: u5 = @intCast(i % (32 / esize) * esize);
    const mask = ((@as(u32, 1) << esize) - 1) << shift;
    at.* = (at.* & ~mask) | ((value << shift) & mask);
}

fn sized(comptime size: u8) *const [2]u8 {
    return switch (size) {
        8 => "00",
        16 => "01",
        32 => "10",
        else => "11",
    };
}

/// Sign-extends an msize-bit value to 32 bits.
pub fn extend(comptime msize: u8, raw: u32) u32 {
    const bit = @as(u32, 1) << (msize - 1);
    return (raw ^ bit) -% bit;
}

/// Lane operations the integer three-operand instructions perform.
pub const Op = enum { add, sub, mul, bitand, bic, orr, orn, eor, min, max, abd, hadd, rhadd, hsub, qadd, qsub };

/// Reads an esize-bit lane as a signed or unsigned 64-bit integer.
pub fn widened(comptime esize: u8, comptime signed: bool, value: u32) i64 {
    const raw: std.meta.Int(.unsigned, esize) = @truncate(value);
    return if (signed) @as(std.meta.Int(.signed, esize), @bitCast(raw)) else raw;
}

/// Applies an integer lane operation, flagging saturation for VQADD and VQSUB.
pub fn apply(comptime op: Op, comptime esize: u8, comptime signed: bool, a: u32, b: u32, saturated: *bool) u32 {
    switch (op) {
        .bitand => return a & b,
        .bic => return a & ~b,
        .orr => return a | b,
        .orn => return a | ~b,
        .eor => return a ^ b,
        else => {},
    }
    const x = widened(esize, signed, a);
    const y = widened(esize, signed, b);
    const low: i64 = if (signed) -(@as(i64, 1) << (esize - 1)) else 0;
    const high: i64 = (@as(i64, 1) << (esize - @intFromBool(signed))) - 1;
    const value: i64 = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .min => @min(x, y),
        .max => @max(x, y),
        .abd => @intCast(@abs(x - y)),
        .hadd => (x + y) >> 1,
        .rhadd => (x + y + 1) >> 1,
        .hsub => (x - y) >> 1,
        .qadd, .qsub => clamped(if (op == .qadd) x + y else x - y, low, high, saturated),
        else => unreachable,
    };
    return @truncate(@as(u64, @bitCast(value)));
}

/// Clamps value into [low, high], setting saturated when it lay outside.
pub fn clamped(value: anytype, low: @TypeOf(value), high: @TypeOf(value), saturated: *bool) @TypeOf(value) {
    if (value < low or value > high) saturated.* = true;
    return @min(@max(value, low), high);
}

/// Representable range of an esize-bit signed or unsigned lane.
pub fn Bounds(comptime esize: u8, comptime signed: bool) type {
    return struct {
        /// Lowest representable value.
        pub const low: i64 = if (signed) -(@as(i64, 1) << (esize - 1)) else 0;
        /// Highest representable value.
        pub const high: i64 = (@as(i64, 1) << (if (signed) esize - 1 else esize)) - 1;
    };
}

/// Shifts a lane by a signed amount with optional rounding and saturation into rsize bits.
pub noinline fn slid(comptime esize: u8, comptime rsize: u8, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, comptime unsigned: bool, value: u32, amount: i32, flag: *bool) u32 {
    const bounds = Bounds(rsize, signed and !unsigned);
    const x = widened(esize, signed, value);
    const capped = @min(@max(amount, -(@as(i32, esize) + 1)), @as(i32, esize));
    if (capped <= 0) {
        const places: u6 = @intCast(-capped);
        const right = (if (rounding) x + ((@as(i64, 1) << places) >> 1) else x) >> places;
        return @truncate(@as(u64, @bitCast(if (saturating) clamped(right, bounds.low, bounds.high, flag) else right)));
    }
    const places: u6 = @intCast(capped);
    if (!saturating) return @truncate(@as(u64, @bitCast(x)) << places);
    const low = -((-bounds.low) >> places);
    if (x < low or x > bounds.high >> places) {
        flag.* = true;
        return @truncate(@as(u64, @bitCast(if (x < low) bounds.low else bounds.high)));
    }
    return @truncate(@as(u64, @bitCast(x << places)));
}

/// One-source lane operations: VABS, VNEG, VQABS, VQNEG, VCLS, VCLZ and VMVN.
pub const Single = enum { abs, neg, qabs, qneg, cls, clz, mvn };

/// Integer VPT and VCMP comparison conditions.
pub const Condition = enum { eq, cs, ne, hi, ge, gt, lt, le };

/// Whether the condition holds between two esize-bit lanes.
pub fn holds(condition: Condition, comptime esize: u8, a: u32, b: u32) bool {
    const Unsigned = std.meta.Int(.unsigned, esize);
    const Signed = std.meta.Int(.signed, esize);
    const x: Unsigned = @truncate(a);
    const y: Unsigned = @truncate(b);
    return switch (condition) {
        .eq => x == y,
        .ne => x != y,
        .cs => x >= y,
        .hi => x > y,
        .ge => @as(Signed, @bitCast(x)) >= @as(Signed, @bitCast(y)),
        .gt => @as(Signed, @bitCast(x)) > @as(Signed, @bitCast(y)),
        .lt => @as(Signed, @bitCast(x)) < @as(Signed, @bitCast(y)),
        .le => @as(Signed, @bitCast(x)) <= @as(Signed, @bitCast(y)),
    };
}

/// Reads core register t, with r15 reading as zero.
pub fn scalarOf(s: *const State, t: u4) u32 {
    return if (t == 15) 0 else s.get(t);
}

const Lane = struct { text: []const u8, pattern: *const [32]u8 };

fn arith(comptime u: u8, comptime pair: *const [2]u8, comptime code: *const [4]u8, comptime four: u8) *const [32]u8 {
    return "111" ++ &[_]u8{u} ++ "111100" ++ pair ++ "nnn0ddd0" ++ code ++ "010" ++ &[_]u8{four} ++ "mmm0";
}

const Three = struct { name: []const u8, code: *const [4]u8, four: u8 };

const threes = [_]Three{
    .{ .name = "vmin", .code = "0110", .four = '1' },
    .{ .name = "vmax", .code = "0110", .four = '0' },
    .{ .name = "vabd", .code = "0111", .four = '0' },
    .{ .name = "vhadd", .code = "0000", .four = '0' },
    .{ .name = "vrhadd", .code = "0001", .four = '0' },
    .{ .name = "vhsub", .code = "0010", .four = '0' },
    .{ .name = "vqadd", .code = "0000", .four = '1' },
    .{ .name = "vqsub", .code = "0010", .four = '1' },
};

const lanes = blk: {
    var out: []const Lane = &.{};
    for ([_]u8{ 8, 16, 32 }) |size| {
        out = out ++ &[_]Lane{
            .{ .text = std.fmt.comptimePrint("vadd.i{d} q{{d}}, q{{n}}, q{{m}}", .{size}), .pattern = arith('0', sized(size), "1000", '0') },
            .{ .text = std.fmt.comptimePrint("vsub.i{d} q{{d}}, q{{n}}, q{{m}}", .{size}), .pattern = arith('1', sized(size), "1000", '0') },
            .{ .text = std.fmt.comptimePrint("vmul.i{d} q{{d}}, q{{n}}, q{{m}}", .{size}), .pattern = arith('0', sized(size), "1001", '1') },
        };
    }
    out = out ++ &[_]Lane{
        .{ .text = "vand q{d}, q{n}, q{m}", .pattern = arith('0', "00", "0001", '1') },
        .{ .text = "vbic q{d}, q{n}, q{m}", .pattern = arith('0', "01", "0001", '1') },
        .{ .text = "{vorr}", .pattern = arith('0', "10", "0001", '1') },
        .{ .text = "vorn q{d}, q{n}, q{m}", .pattern = arith('0', "11", "0001", '1') },
        .{ .text = "veor q{d}, q{n}, q{m}", .pattern = arith('1', "00", "0001", '1') },
    };
    for (threes) |three| {
        for ([_]bool{ true, false }) |signed| {
            for ([_]u8{ 8, 16, 32 }) |size| {
                out = out ++ &[_]Lane{.{
                    .text = std.fmt.comptimePrint("{s}.{c}{d} q{{d}}, q{{n}}, q{{m}}", .{ three.name, @as(u8, if (signed) 's' else 'u'), size }),
                    .pattern = arith(if (signed) '0' else '1', sized(size), three.code, three.four),
                }};
            }
        }
    }
    break :blk out;
};

/// Expands an 8-bit vector immediate through cmode into the two words VMOV, VMVN, VORR and VBIC use.
pub fn expandedWord(cmode: u4, inverted: bool, imm8: u8) [2]u32 {
    const kind: u32 = cmode >> 1;
    const value: u32 = switch (@as(u3, @truncate(kind))) {
        0, 1, 2, 3 => @as(u32, imm8) << @intCast(kind * 8),
        4, 5 => @as(u32, imm8) *% (@as(u32, 0x0001_0001) << @intCast((kind & 1) * 8)),
        6 => if (cmode & 1 == 0) @as(u32, imm8) << 8 | 0xff else @as(u32, imm8) << 16 | 0xffff,
        7 => if (cmode & 1 == 1) precise(imm8) else @as(u32, imm8) *% 0x0101_0101,
    };
    if (cmode != 14 or !inverted) return .{ value, value };
    return .{ spread(imm8), spread(imm8 >> 4) };
}

fn spread(nibble: u8) u32 {
    var out: u32 = 0;
    for (0..4) |i| out |= @as(u32, if (nibble >> @intCast(i) & 1 != 0) 0xff else 0) << @intCast(i * 8);
    return out;
}

fn precise(imm8: u8) u32 {
    const above: u32 = imm8 >> 6 & 1;
    return @as(u32, imm8 >> 7) << 31 | (above ^ 1) << 30 | (above * 0x1f) << 25 | @as(u32, imm8 & 0x3f) << 19;
}

/// The float type of an esize-bit lane.
pub fn Float(comptime esize: u8) type {
    return if (esize == 16) f16 else f32;
}

/// Reads an esize-bit lane as a float, flushing a denormal as FPSCR asks.
pub fn real(s: *State, comptime esize: u8, value: u32) Float(esize) {
    return fp.admitted(s, Float(esize), @bitCast(@as(std.meta.Int(.unsigned, esize), @truncate(value))));
}

/// The bit pattern of an esize-bit float lane.
pub fn bitsOf(comptime esize: u8, value: Float(esize)) u32 {
    return @as(std.meta.Int(.unsigned, esize), @bitCast(value));
}

/// Evaluates a floating-point VPT condition index over two values.
pub fn ordered(comptime T: type, index: u3, x: T, y: T) bool {
    return switch (index) {
        0 => x == y,
        1 => !(x == y),
        4 => x >= y,
        5 => !(x >= y),
        6 => x > y,
        else => !(x > y),
    };
}
