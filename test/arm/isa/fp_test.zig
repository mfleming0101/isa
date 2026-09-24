//! Tests for the floating-point instructions: the arithmetic in src/arm/isa/fp.zig
//! and the semantics in src/sem/arm/fp.zig. `Machine` is a minimal host with
//! 160 bytes of memory whose fields switch CP10 access, the Security Extension,
//! automatic and lazy context state, half and double precision and MVE; each
//! test steps one assembled word and checks registers, memory and FPSCR. Run
//! with `zig build test`.

const std = @import("std");
const State = @import("../../../src/arm/isa/state.zig").State;
const step = @import("../../../src/arm/isa/step.zig");
const free: step.Model.Costs = @splat(.{ .cycles = 0, .taken = 0 });
const instruction = @import("../../../src/arm/isa/instruction.zig");
const Architecture = @import("../../../src/arm/isa/architecture.zig").Architecture;
const fp = @import("../../../src/arm/isa/fp.zig");
const decode = @import("../../../src/arm/isa/decode.zig");

const Machine = struct {
    const Self = @This();

    bytes: [160]u8 = @splat(0),
    enabled: bool = true,
    secure_extension: bool = false,
    aspen: bool = true,
    vector: bool = true,
    lspen: bool = true,
    callee: bool = false,
    owed: ?u32 = null,
    model: step.Model,
    halves: bool,
    doubles: bool = true,

    /// Four implemented exception priority bits.
    pub fn priorityBits(_: *Self) u4 {
        return 4;
    }

    /// The architecture the model decodes for.
    pub fn architecture(self: *Self) Architecture {
        return self.model.decoding.architecture;
    }

    /// Security Extension present while secure_extension is set.
    pub fn security(self: *Self) bool {
        return self.secure_extension;
    }

    /// FPCCR.ASPEN as aspen says.
    pub fn automaticFpState(self: *Self) bool {
        return self.aspen;
    }

    /// FPDSCR: zero with the fixed fields.
    pub fn defaultFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
    }

    /// The Non-secure FPSCR: zero with the fixed fields.
    pub fn nonSecureFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
    }

    /// Double-precision arithmetic present while doubles is set.
    pub fn doublePrecision(self: *Self) bool {
        return self.doubles;
    }

    /// Half-precision arithmetic present while halves is set.
    pub fn halfPrecision(self: *Self) bool {
        return self.halves;
    }

    /// FPv5 instructions present.
    pub fn fpv5(_: *Self) bool {
        return true;
    }

    /// The pending lazy frame address, owed.
    pub fn lazyFpFrame(self: *Self) ?u32 {
        return self.owed;
    }

    /// Whether a lazy frame holds the callee-saved registers, callee.
    pub fn lazyFpCallee(self: *Self) bool {
        return self.callee;
    }

    /// FPCCR.LSPEN as lspen says.
    pub fn lazyFpEnabled(self: *Self) bool {
        return self.lspen;
    }

    /// Records the pending lazy frame in owed.
    pub fn setLazyFp(self: *Self, frame: ?u32) void {
        self.owed = frame;
    }

    /// The Non-secure floating-point context the FPCXT_NS rows move is present.
    pub fn treatAsSecure(_: *Self) bool {
        return true;
    }

    /// MVE present while vector is set.
    pub fn mve(self: *Self) bool {
        return self.vector;
    }

    /// PACBTI present on Armv8.1-M.
    pub fn pacbti(self: *Self) bool {
        return self.model.decoding.architecture == .armv8_1m_main;
    }

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    /// Ignores the access address the core reports.
    pub fn touch(_: *Self, _: u32) void {}

    /// Ignores the mask write the core reports.
    pub fn signal(_: *Self, _: step.Signal) void {}

    /// Host requirement: nothing re-arms here.
    pub fn rearm(_: *Self) void {}

    /// Ignores WFE and WFI.
    pub fn sleep(_: *Self, _: step.Wait) void {}

    /// Ignores SEV.
    pub fn event(_: *Self) void {}

    /// CCR.UNALIGN_TRP clear.
    pub fn trapsUnaligned(_: *Self) bool {
        return false;
    }

    /// CCR.DIV_0_TRP clear.
    pub fn trapsDivideByZero(_: *Self) bool {
        return false;
    }

    /// CP10 enabled while enabled is set.
    pub fn coprocessorEnabled(self: *Self) bool {
        return self.enabled;
    }

    /// The memory bytes from address onward, or empty past the end.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        _ = self.slice(address, a.bytes) orelse return &.{};
        return self.bytes[address..];
    }

    /// Faults every access the span could not serve.
    pub fn access(_: *Self, _: u32, comptime _: anytype, _: u32) error{DataFault}!u32 {
        return error.DataFault;
    }

    fn peek(self: *Self, comptime T: type, address: u32) ?T {
        return std.mem.readInt(T, self.slice(address, @sizeOf(T)) orelse return null, .little);
    }

    fn poke(self: *Self, comptime T: type, address: u32, value: T) ?void {
        std.mem.writeInt(T, self.slice(address, @sizeOf(T)) orelse return null, value, .little);
    }
};

fn machine(p: Architecture, halves: bool) Machine {
    return .{ .model = .{ .decoding = decode.selectionOf(p), .costs = free }, .halves = halves };
}

fn exec(s: *State, m: *Machine, code: u32) instruction.Outcome {
    return step.call(Machine, s, m, code, m.model.decoding.groups);
}

const half = exec;

const one: u32 = 0x3f80_0000;
const two_and_a_half: u32 = 0x4020_0000;
const minus_one_and_a_half: u32 = 0xbfc0_0000;

test "the FPU refuses every instruction while CPACR leaves CP10 disabled, B3.2.20" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    m.enabled = false;
    s.fp[2] = one;
    s.fp[3] = two_and_a_half;
    try std.testing.expectEqual(.no_coprocessor, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    m.enabled = true;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x4060_0000), s.fp[1]);
}

test "the single-precision arithmetic writes the split-encoded destination, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = two_and_a_half;
    s.fp[3] = minus_one_and_a_half;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(s.fp[1])));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a61));
    try std.testing.expectEqual(@as(f32, 4.0), @as(f32, @bitCast(s.fp[1])));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee610a21));
    try std.testing.expectEqual(@as(f32, -3.75), @as(f32, @bitCast(s.fp[1])));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee610a61));
    try std.testing.expectEqual(@as(f32, 3.75), @as(f32, @bitCast(s.fp[1])));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeec10a21));
    try std.testing.expectEqual(@as(f32, -1.0 / 0.6), @as(f32, @bitCast(s.fp[1])));
}

test "VABS and VNEG touch only the sign bit and VSQRT rounds to nearest, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = minus_one_and_a_half;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef00ac1));
    try std.testing.expectEqual(@as(u32, 0x3fc0_0000), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef10a41));
    try std.testing.expectEqual(@as(u32, 0x3fc0_0000), s.fp[1]);
    s.fp[2] = 0x4110_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef10ac1));
    try std.testing.expectEqual(@as(f32, 3.0), @as(f32, @bitCast(s.fp[1])));
}

test "VCMP sets the FPSCR flags for less, equal, greater and unordered, and VMRS copies them to APSR, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    for ([_][3]u32{
        .{ one, two_and_a_half, 0x8000_0000 },
        .{ two_and_a_half, two_and_a_half, 0x6000_0000 },
        .{ two_and_a_half, one, 0x2000_0000 },
        .{ 0x7fc0_0000, one, 0x3000_0000 },
    }) |triple| {
        s.fp[1] = triple[0];
        s.fp[2] = triple[1];
        try std.testing.expectEqual(.next, exec(&s, &m, 0xeef40a41));
        try std.testing.expectEqual(triple[2], s.fpscr & fp.nzcv);
        try std.testing.expectEqual(.next, exec(&s, &m, 0xeef1fa10));
        try std.testing.expectEqual(triple[2], s.xpsr & fp.nzcv);
    }
    s.fp[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef50a40));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & fp.nzcv);
}

test "the conversions saturate at the ends of the integer range and answer zero for a NaN, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    for ([_][2]u32{
        .{ 0x4110_0000, 9 },
        .{ 0xc110_0000, @bitCast(@as(i32, -9)) },
        .{ 0x7f80_0000, 0x7fff_ffff },
        .{ 0xff80_0000, 0x8000_0000 },
        .{ 0x7fc0_0000, 0 },
    }) |pair| {
        s.fp[2] = pair[0];
        try std.testing.expectEqual(.next, exec(&s, &m, 0xeefd0ac1));
        try std.testing.expectEqual(pair[1], s.fp[1]);
    }
    s.fp[2] = @bitCast(@as(i32, -9));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef80ac1));
    try std.testing.expectEqual(@as(f32, -9.0), @as(f32, @bitCast(s.fp[1])));
    s.fp[2] = 9;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef80a41));
    try std.testing.expectEqual(@as(f32, 9.0), @as(f32, @bitCast(s.fp[1])));
}

test "VMOV carries an eight-bit immediate through VFPExpandImm and moves whole words to and from the core, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    try std.testing.expectEqual(@as(u32, 0x3f80_0000), fp.expandImm(f32, 0x70));
    try std.testing.expectEqual(@as(u32, 0xc060_0000), fp.expandImm(f32, 0x8c));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef70a00));
    try std.testing.expectEqual(@as(u32, 0x3f80_0000), s.fp[1]);
    s.r[2] = 0xdead_beef;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee002a90));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.fp[1]);
    s.fp[1] = 0x1234_5678;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee102a90));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), s.r[2]);
}

test "VMOV moves a register pair as two singles and as one double, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.r[2] = 0x1111_1111;
    s.r[3] = 0x2222_2222;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec432a30));
    try std.testing.expectEqual(@as(u32, 0x1111_1111), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), s.fp[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec432b11));
    try std.testing.expectEqual(@as(u32, 0x1111_1111), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), s.fp[3]);
    s.fp[2] = 0xaaaa_aaaa;
    s.fp[3] = 0xbbbb_bbbb;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec532b11));
    try std.testing.expectEqual(@as(u32, 0xaaaa_aaaa), s.r[2]);
    try std.testing.expectEqual(@as(u32, 0xbbbb_bbbb), s.r[3]);
}

test "VLDR and VSTR carry the sign in U, and the block forms walk the register file, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    std.mem.writeInt(u32, m.bytes[0x20..0x24], 0xcafe_f00d, .little);
    s.r[2] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedd20a00));
    try std.testing.expectEqual(@as(u32, 0xcafe_f00d), s.fp[1]);
    s.r[2] = 0x30;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed520a04));
    try std.testing.expectEqual(@as(u32, 0xcafe_f00d), s.fp[1]);
    s.fp[1] = 0x0102_0304;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedc20a02));
    try std.testing.expectEqual(@as(u32, 0x0102_0304), m.peek(u32, 0x38).?);
    s.r[2] = 0x40;
    for (0..4) |i| std.mem.writeInt(u32, m.bytes[0x40 + 4 * i ..][0..4], @intCast(i + 1), .little);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecf20a04));
    try std.testing.expectEqual([_]u32{ 1, 2, 3, 4 }, s.fp[1..5].*);
    try std.testing.expectEqual(@as(u32, 0x50), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed620a04));
    try std.testing.expectEqual(@as(u32, 0x40), s.r[2]);
    try std.testing.expectEqual(@as(u32, 1), m.peek(u32, 0x40).?);
}

test "VMSR writes FPSCR whole and VMRS reads it back, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.r[1] = 0x00c0_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee11a10));
    try std.testing.expectEqual(@as(u32, 0x00c0_0000), s.fpscr);
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef11a10));
    try std.testing.expectEqual(@as(u32, 0x00c0_0000), s.r[1]);
}

test "a block transfer whose count runs past s31 stops at the end of the register file, A7.7.250" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    for (0..32) |i| std.mem.writeInt(u32, m.bytes[4 * i ..][0..4], @intCast(i + 1), .little);
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec91_0aff));
    try std.testing.expectEqual(@as(u32, 1), s.fp[0]);
    try std.testing.expectEqual(@as(u32, 32), s.fp[31]);
}

fn flags(s: *State, m: *Machine, code: u32, x: u32, y: u32) u32 {
    s.fpscr &= ~@as(u32, 0x9f);
    s.fp[0] = x;
    s.fp[1] = y;
    std.debug.assert(exec(s, m, code) == .next);
    return s.fpscr & 0x9f;
}

test "arithmetic records the cumulative exceptions it raises in FPSCR, A2.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    const add = 0xee301a20;
    const mul = 0xee201a20;
    const div = 0xee801a20;
    const sqrt = 0xeeb11ac0;
    try std.testing.expectEqual(@as(u32, 0x14), flags(&s, &m, add, 0x7f7fffff, 0x7f7fffff));
    try std.testing.expectEqual(@as(u32, 0x10), flags(&s, &m, add, one, 0x30000000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, add, 0x7f800000, 0xff800000));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, add, one, one));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, add, one, 0x7fc00000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, add, one, 0x7fa00000));
    try std.testing.expectEqual(@as(u32, 0x18), flags(&s, &m, mul, 0x00800001, 0x3f000000));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, mul, 0x00800000, 0x3f000000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, mul, 0, 0x7f800000));
    try std.testing.expectEqual(@as(u32, 0x02), flags(&s, &m, div, one, 0));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, div, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, div, 0x7f800000, 0));
    try std.testing.expectEqual(@as(u32, 0x10), flags(&s, &m, div, one, 0x40400000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, sqrt, 0xbf800000, 0));
    try std.testing.expectEqual(@as(u32, 0x10), flags(&s, &m, sqrt, 0x40000000, 0));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, sqrt, 0x80000000, 0));
}

test "a conversion records the same cumulative exceptions as the arithmetic, A2.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    const to_signed = 0xeebd1ac0;
    const to_half = 0xeeb31a40;
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, to_signed, 0x7fc00000, 0));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, to_signed, 0x50000000, 0));
    try std.testing.expectEqual(@as(u32, 0x10), flags(&s, &m, to_signed, 0x3fc00000, 0));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, to_signed, 0x40000000, 0));
    try std.testing.expectEqual(@as(u32, 0x14), flags(&s, &m, to_half, 0x50000000, 0));
    try std.testing.expectEqual(@as(u32, 0x18), flags(&s, &m, to_half, 0x33000000, 0));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, to_half, one, 0));
    try std.testing.expectEqual(@as(u32, 0x10), flags(&s, &m, to_half, 0x3fc00001, 0));
}

test "VCMPE raises Invalid Operation for a quiet NaN where VCMP does not, A7.7.230 A7.7.231" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    const cmp = 0xeeb40a60;
    const cmpe = 0xeeb40ae0;
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, cmp, one, 0x7fc00000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, cmpe, one, 0x7fc00000));
    try std.testing.expectEqual(@as(u32, 0x01), flags(&s, &m, cmp, one, 0x7fa00000));
    try std.testing.expectEqual(@as(u32, 0x00), flags(&s, &m, cmpe, one, one));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & fp.nzcv);
}

test "inexactness is decided from the operation itself, so a sum whose true result needs more bits than a double holds still raises IXC, A2.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = 0x7f7f_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x7f7f_ffff), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 0;
    s.fp[3] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "the arithmetic rounds the way FPSCR.RMode asks and not always to nearest, A2.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = 0x3300_0000;
    for ([_][2]u32{ .{ 0, 0x3f80_0000 }, .{ 1 << 22, 0x3f80_0001 }, .{ 2 << 22, 0x3f80_0000 }, .{ 3 << 22, 0x3f80_0000 } }) |pair| {
        s.fpscr = pair[0];
        try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
        try std.testing.expectEqual(pair[1], s.fp[1]);
        try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    }
    s.fpscr = 2 << 22;
    s.fp[2] = 0xbf80_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a61));
    try std.testing.expectEqual(@as(u32, 0xbf80_0001), s.fp[1]);
    s.fpscr = 2 << 22;
    s.fp[2] = one;
    s.fp[3] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a61));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.fp[1]);
}

test "FPSCR.FZ reads a denormal operand as zero and flushes a denormal result to zero, A2.5.4" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv7em, false);
    s.fpscr = 1 << 24;
    s.fp[2] = one;
    s.fp[3] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(one, s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
    s.fpscr = 1 << 24;
    s.fp[3] = 0x7f7f_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeec10a21));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x08), s.fpscr & 0x9f);
    s.fpscr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeec10a21));
    try std.testing.expectEqual(@as(u32, 0x0020_0000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
}

test "FPSCR.DN answers the default NaN rather than propagating the operand NaN, A2.5.4" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = 0x7f80_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x7fc0_0001), s.fp[1]);
    s.fpscr = 1 << 25;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x7fc0_0000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
}

test "MRS reads CONTROL.FPCA, the bit a context switch uses to decide whether the task owns the S registers, B1.4.4" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef8014));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef8014));
    try std.testing.expectEqual(@as(u32, 4), s.r[0]);
}

fn double(s: *State, i: u5, value: u64) void {
    s.fp[2 * i] = @truncate(value);
    s.fp[2 * i + 1] = @truncate(value >> 32);
}

fn doubled(s: *const State, i: u5) u64 {
    return @as(u64, s.fp[2 * i + 1]) << 32 | s.fp[2 * i];
}

test "the double-precision arithmetic keeps the whole 64-bit format and flags it the same way, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 1, 0x3ff0_0000_0000_0000);
    double(&s, 3, 0x7fef_ffff_ffff_ffff);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee312b03));
    try std.testing.expectEqual(@as(u64, 0x7fef_ffff_ffff_ffff), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 1 << 22;
    double(&s, 3, 0x3ca0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee312b03));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0001), doubled(&s, 2));
    s.fpscr = 0;
    double(&s, 3, 0x7fef_ffff_ffff_ffff);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee812b03));
    try std.testing.expectEqual(@as(u64, 0x0004_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 3, 0x4010_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb12bc3));
    try std.testing.expectEqual(@as(u64, 0x4000_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb72b00));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb02bc3));
    try std.testing.expectEqual(@as(u64, 0x4010_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb12b43));
    try std.testing.expectEqual(@as(u64, 0xc010_0000_0000_0000), doubled(&s, 2));
}

test "a fused multiply that underflows keeps the sign of the exact result rather than the sign a cancelling sum would take, A2.8.2" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 1, 0x0000_0000_0000_0001);
    double(&s, 3, 0x3fe0_0000_0000_0000);
    double(&s, 2, 0);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea12b43));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 1, 0x3ff0_0000_0000_0000);
    double(&s, 3, 0x3ff0_0000_0000_0000);
    double(&s, 2, 0x3ff0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea12b43));
    try std.testing.expectEqual(@as(u64, 0), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    s.fpscr = 2 << 22;
    double(&s, 2, 0x3ff0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea12b43));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), doubled(&s, 2));
}

test "the double-precision compares drive the FPSCR condition flags and separate the quiet NaN from the signalling one, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 2, 0x3ff0_0000_0000_0000);
    double(&s, 3, 0x3ff0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb42b43));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & 0xf000_0000);
    double(&s, 3, 0x4000_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb42b43));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.fpscr & 0xf000_0000);
    s.fpscr = 0;
    double(&s, 3, 0x7ff8_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb42b43));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), s.fpscr & 0xf000_0000);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb42bc3));
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 3, 0x7ff4_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb42b43));
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 2, 0);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb52b40));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & 0xf000_0000);
}

test "the compare against zero names any of the sixteen double registers, because Vd is four bits wide, A7.7.226" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 8, 0);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb58b40));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & 0xf000_0000);
    s.fpscr = 0;
    double(&s, 15, 0x8000_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb5fbc0));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.fpscr & 0xf000_0000);
}

test "the double-precision conversions carry the whole 32-bit integer range and saturate outside it, A7.5.3" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[3] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb82be1));
    try std.testing.expectEqual(@as(u64, 0xbff0_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb82b61));
    try std.testing.expectEqual(@as(u64, 0x41ef_ffff_ffe0_0000), doubled(&s, 2));
    double(&s, 3, 0x7e37_e43c_8800_759c);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebd1bc3));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 3, 0x3fe0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebd1b43));
    try std.testing.expectEqual(@as(u32, 0), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
}

test "narrowing a double to a single flushes a tiny result only when FPSCR.FZ asks for it, A2.7.5" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 3, 0x3730_0000_0000_0001);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb71bc3));
    try std.testing.expectEqual(@as(u32, 0x200), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
    s.fpscr = 1 << 24;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb71bc3));
    try std.testing.expectEqual(@as(u32, 0), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x08), s.fpscr & 0x9f);
    s.fpscr = 0;
    s.fp[3] = 0x3f80_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb72ae1));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "the double-precision transfers move whole 64-bit lanes and step the base by two words a register, A7.7.229" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    std.mem.writeInt(u64, m.bytes[16..24], 0x3ff0_0000_0000_0000, .little);
    std.mem.writeInt(u64, m.bytes[24..32], 0x4000_0000_0000_0000, .little);
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed912b02));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed012b02));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), std.mem.readInt(u64, m.bytes[0..8], .little));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecb12b06));
    try std.testing.expectEqual(@as(u32, 32), s.r[1]);
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 3));
    try std.testing.expectEqual(@as(u64, 0x4000_0000_0000_0000), doubled(&s, 4));
    double(&s, 2, 0x4008_0000_0000_0000);
    double(&s, 3, 0x4010_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed212b04));
    try std.testing.expectEqual(@as(u32, 16), s.r[1]);
    try std.testing.expectEqual(@as(u64, 0x4008_0000_0000_0000), std.mem.readInt(u64, m.bytes[16..24], .little));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec812b04));
    try std.testing.expectEqual(@as(u32, 16), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed312b04));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 2));
}

test "a unit with no double-precision arithmetic still carries the D-register transfers, which are FPv4-SP encodings, A7.7.235 A7.7.236 A7.7.252" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    m.doubles = false;
    std.mem.writeInt(u32, m.bytes[0x40..0x44], 0x1111_1111, .little);
    std.mem.writeInt(u32, m.bytes[0x44..0x48], 0x2222_2222, .little);
    s.r[1] = 0x40;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed911b00));
    try std.testing.expectEqual(@as(u32, 0x1111_1111), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), s.fp[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed811b02));
    try std.testing.expectEqual(@as(?u32, 0x2222_2222), m.peek(u32, 0x4c));
    s.set(13, 0x80);
    s.fp[16] = 0xaaaa_aaaa;
    s.fp[17] = 0xbbbb_bbbb;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed2d8b02));
    try std.testing.expectEqual(@as(u32, 0x78), s.get(13));
    s.fp[16] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecbd8b02));
    try std.testing.expectEqual(@as(u32, 0xaaaa_aaaa), s.fp[16]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecb12b04));
    try std.testing.expectEqual(@as(u32, 0x50), s.r[1]);
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xee312b03));
}

test "VMAXNM and VMINNM answer the number when the other operand is a quiet NaN and give a zero the sign both operands agree on, A7.7.243" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = 0xc000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a21));
    try std.testing.expectEqual(@as(u32, one), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a61));
    try std.testing.expectEqual(@as(u32, 0xc000_0000), s.fp[1]);
    s.fp[3] = 0x7fc0_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a21));
    try std.testing.expectEqual(@as(u32, one), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    s.fp[3] = 0x7f80_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a21));
    try std.testing.expectEqual(@as(u32, 0x7fc0_0001), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    s.fp[2] = 0;
    s.fp[3] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a21));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfec10a61));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.fp[1]);
    double(&s, 1, 0x3ff0_0000_0000_0000);
    double(&s, 3, 0x7ff8_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe812b43));
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "VRINT rounds to an integral value, only VRINTX reports the rounding as inexact, and a negative fraction keeps its sign, A7.7.253" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = 0x40200000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef80a41));
    try std.testing.expectEqual(@as(u32, 0x40400000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef90a41));
    try std.testing.expectEqual(@as(u32, 0x40000000), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef70a41));
    try std.testing.expectEqual(@as(u32, 0x40000000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 0;
    s.fp[2] = 0xbe99999a;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef90a41));
    try std.testing.expectEqual(@as(u32, 0x80000000), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefb0a41));
    try std.testing.expectEqual(@as(u32, 0xbf800000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    s.fp[2] = 0x7f800001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef80a41));
    try std.testing.expectEqual(@as(u32, 0x7fc00001), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 3, 0x4004000000000000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfeb92b43));
    try std.testing.expectEqual(@as(u64, 0x4000000000000000), doubled(&s, 2));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb62bc3));
    try std.testing.expectEqual(@as(u64, 0x4000000000000000), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "VCVTA, VCVTN, VCVTP and VCVTM carry their own rounding mode rather than the one FPSCR holds, A7.7.226" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fpscr = 3 << 22;
    s.fp[2] = 0x40200000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefc0ac1));
    try std.testing.expectEqual(@as(u32, 3), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 3 << 22;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefd0ac1));
    try std.testing.expectEqual(@as(u32, 2), s.fp[1]);
    s.fp[2] = 0xbf000000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefc0ac1));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfeff0a41));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x11), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 3, 0x4004000000000000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefe0bc3));
    try std.testing.expectEqual(@as(u32, 3), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfefd0b43));
    try std.testing.expectEqual(@as(u32, 2), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
}

test "VSEL takes the APSR flags rather than the FPSCR ones and copies the register it picks without touching a NaN, A7.7.259" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = one;
    s.fp[3] = 0x7f800001;
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe410a21));
    try std.testing.expectEqual(@as(u32, 0x7f800001), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    s.xpsr = 1 << 30;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe410a21));
    try std.testing.expectEqual(@as(u32, one), s.fp[1]);
    s.xpsr = 1 << 28;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe510a21));
    try std.testing.expectEqual(@as(u32, one), s.fp[1]);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe610a21));
    try std.testing.expectEqual(@as(u32, one), s.fp[1]);
    s.xpsr = 1 << 31;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe610a21));
    try std.testing.expectEqual(@as(u32, 0x7f800001), s.fp[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe710a21));
    try std.testing.expectEqual(@as(u32, 0x7f800001), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    double(&s, 1, 0x3ff0000000000000);
    double(&s, 3, 0x4000000000000000);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe212b03));
    try std.testing.expectEqual(@as(u64, 0x3ff0000000000000), doubled(&s, 2));
}

test "the fixed-point conversions scale by the immediate, truncate toward zero on the way in and round to nearest on the way out, A7.7.227" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = 0x40200000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebe1a66));
    try std.testing.expectEqual(@as(u32, 20), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeba1a66));
    try std.testing.expectEqual(@as(u32, 0x40200000), s.fp[2]);
    s.fpscr = 1 << 22;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebe1a48));
    try std.testing.expectEqual(@as(u32, 2), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 0;
    s.fp[2] = 0xbf800000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebe1a66));
    try std.testing.expectEqual(@as(u32, 0xffff_fff8), s.fp[2]);
    s.fp[2] = 0xbf800000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebf1a66));
    try std.testing.expectEqual(@as(u32, 0), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 2 << 22;
    s.fp[2] = 0x501502f9;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeba1aef));
    try std.testing.expectEqual(@as(u32, 0x4e202a06), s.fp[2]);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 2, 0x4004000000000000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeebe2bee));
    try std.testing.expectEqual(@as(u64, 20), doubled(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

const half_one: u32 = 0x0000_3c00;
const half_two_and_a_half: u32 = 0x0000_4100;
const half_minus_one_and_a_half: u32 = 0x0000_be00;

test "the half-precision arithmetic reads and writes the low half of the split-encoded register, C2.4.297" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0xdead_0000 | half_two_and_a_half;
    s.fp[3] = 0xbeef_0000 | half_minus_one_and_a_half;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee710921));
    try std.testing.expectEqual(@as(u32, 0x0000_3c00), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xee710961));
    try std.testing.expectEqual(@as(u32, 0x0000_4400), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xee610921));
    try std.testing.expectEqual(@as(u32, 0x0000_c380), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xee610961));
    try std.testing.expectEqual(@as(u32, 0x0000_4380), s.fp[1]);
}

test "the half-precision destination clears the top half rather than keeping it, C2.4.297" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0x1234_5678;
    s.fp[2] = half_one;
    s.fp[3] = half_one;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee710921));
    try std.testing.expectEqual(@as(u32, 0x0000_4000), s.fp[1]);
}

test "VABS.F16 and VNEG.F16 touch the half sign bit and VSQRT.F16 rounds to nearest, C2.4.298 C2.4.399" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = half_minus_one_and_a_half;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef009c1));
    try std.testing.expectEqual(@as(u32, 0x0000_3e00), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef10941));
    try std.testing.expectEqual(@as(u32, 0x0000_3e00), s.fp[1]);
    s.fp[2] = 0x0000_4900;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef109c1));
    try std.testing.expectEqual(@as(u32, 0x0000_4253), s.fp[1]);
}

test "VMOV.F16 immediate expands the eight bits into the half format, C2.4.398" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef70900));
    try std.testing.expectEqual(half_one, s.fp[1]);
}

test "VCMP.F16 writes the FPSCR flags and the ordered form raises IOC on a quiet NaN, C2.4.318" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = half_one;
    s.fp[3] = half_two_and_a_half;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb41961));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.fpscr & fp.nzcv);
    s.fp[3] = 0x0000_7e00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb41961));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), s.fpscr & fp.nzcv);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 1);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb419e1));
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 1);
}

test "FPSCR.FZ16 flushes a half denormal without the input denormal flag FZ raises, B4.8.1" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0000_0001;
    s.fp[3] = 0x0000_0001;
    s.fpscr = 1 << 19;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee710921));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & (1 << 7));
    s.fpscr = 1 << 24;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee710921));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), s.fp[1]);
}

test "half-precision arithmetic is undefined without the half-precision extension, D1.2.24" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, false);
    try std.testing.expectEqual(.undefined, step.call(Machine, &s, &m, 0xee710921, m.model.decoding.groups));
}

test "FPSCR.LTPSIZE holds what VMSR writes where there is a vector extension to hold a loop, and a fixed four where there is not, B4.4.1" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    m.vector = false;
    s.set(3, 0xffff_ffff);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeee13a10));
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & (0x7 << 16));
    s.set(3, 0);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeee13a10));
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & (0x7 << 16));
    m.vector = true;
    s.set(3, 0x0002_0000);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeee13a10));
    try std.testing.expectEqual(@as(u32, 0x2 << 16), s.fpscr & (0x7 << 16));
    var seven = machine(.armv7em, false);
    var t: State = .{};
    t.set(3, 0xffff_ffff);
    try std.testing.expectEqual(.next, exec(&t, &seven, 0xeee13a10));
    try std.testing.expectEqual(@as(u32, 0x7 << 16), t.fpscr & (0x7 << 16));
}

test "a fused multiply of an infinity by a zero raises IOC and yields the default NaN even when the addend is a quiet NaN, E2.1.155" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.fp[2] = 0xff80_0000;
    s.fp[3] = 0x0000_0000;
    s.fp[1] = 0x7fd5_5000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee10a21));
    try std.testing.expectEqual(@as(u32, 0x7fc0_0000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 1);
    s.fpscr = 0;
    s.fp[1] = 0x7f80_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee10a21));
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 1);
    try std.testing.expectEqual(@as(u32, 0x7fc0_0001), s.fp[1]);
}

test "the half-precision integer conversions write the whole register and read the low half, C2.4.322" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0xdead_4900;
    s.fp[1] = 0x1234_5678;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefd09c1));
    try std.testing.expectEqual(@as(u32, 10), s.fp[1]);
    s.fp[2] = 7;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef80941));
    try std.testing.expectEqual(@as(u32, 0x0000_4700), s.fp[1]);
}

test "VRINT.F16 and the directed VCVT.F16 forms follow the mode named by the instruction, C2.4.319 C2.4.421" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0000_3e00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfefb0941));
    try std.testing.expectEqual(@as(u32, 0x0000_3c00), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeef70941));
    try std.testing.expectEqual(@as(u32, 0x0000_4000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 4), s.fpscr & (1 << 4));
    try std.testing.expectEqual(.next, half(&s, &m, 0xfefd09c1));
    try std.testing.expectEqual(@as(u32, 2), s.fp[1]);
}

test "VMAXNM.F16 and VMINNM.F16 return the number beside a quiet NaN and pick the zero sign, C2.4.393" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0000_7e00;
    s.fp[3] = 0x0000_4000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfec10921));
    try std.testing.expectEqual(@as(u32, 0x0000_4000), s.fp[1]);
    s.fp[2] = 0x0000_0000;
    s.fp[3] = 0x0000_8000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfec10921));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xfec10961));
    try std.testing.expectEqual(@as(u32, 0x0000_8000), s.fp[1]);
}

test "VSEL.F16 copies a half without rounding it or touching the flags, C2.4.437" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0000_0001;
    s.fp[3] = 0x0000_7e00;
    s.fpscr = 1 << 19;
    s.xpsr = 0x4000_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfe410921));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 19), s.fpscr);
}

test "the half-precision fixed-point conversions scale exactly rather than through the half format, C2.4.324" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0x0000_3c00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefa09cf));
    try std.testing.expectEqual(@as(u32, 0x0000_6b80), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefe09ed));
    try std.testing.expectEqual(@as(u32, 0x0001_e000), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 1);
}

test "VMOV.F16 moves the low half between a core register and a half register, C2.4.399" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0xdead_3c00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee100990));
    try std.testing.expectEqual(@as(u32, 0x0000_3c00), s.get(0));
    s.set(0, 0xffff_beef);
    s.fp[1] = 0x1234_5678;
    try std.testing.expectEqual(.next, half(&s, &m, 0xee000990));
    try std.testing.expectEqual(@as(u32, 0x0000_beef), s.fp[1]);
}

test "VINS keeps the low half and VMOVX reads the high half into a cleared register, C2.4.359 C2.4.405" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[0] = 0x0000_3c00;
    s.fp[1] = 0xffff_4000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfeb00ae0));
    try std.testing.expectEqual(@as(u32, 0x4000_3c00), s.fp[0]);
    s.fp[1] = 0xffff_bc00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xfeb00a60));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), s.fp[0]);
}

test "VLDR.16 and VSTR.16 scale the offset by two and move sixteen bits, C2.4.375 C2.4.447" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    try std.testing.expectEqual(@as(?void, {}), m.poke(u32, 8, 0x1234_5678));
    s.set(1, 8);
    s.fp[0] = 0xffff_ffff;
    try std.testing.expectEqual(.next, half(&s, &m, 0xed910900));
    try std.testing.expectEqual(@as(u32, 0x0000_5678), s.fp[0]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xed910901));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), s.fp[0]);
    s.fp[0] = 0xdead_abcd;
    try std.testing.expectEqual(.next, half(&s, &m, 0xed810900));
    try std.testing.expectEqual(@as(u32, 0x1234_abcd), m.peek(u32, 8).?);
}

test "FPSCR.AHP reads the half format without infinities or NaNs, E2.1.164" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fpscr = 1 << 26;
    s.fp[2] = 0x0000_7c00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb20a41));
    try std.testing.expectEqual(@as(u32, 0x4780_0000), s.fp[0]);
    s.fpscr = 0;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb20a41));
    try std.testing.expectEqual(@as(u32, 0x7f80_0000), s.fp[0]);
}

test "FPSCR.AHP saturates instead of overflowing and turns a NaN into a zero with IOC, E2.1.150" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fpscr = 1 << 26;
    s.fp[2] = 0x7f80_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30a41));
    try std.testing.expectEqual(@as(u32, 0x0000_7fff), s.fp[0] & 0xffff);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 1);
    s.fpscr = 1 << 26;
    s.fp[2] = 0xffc0_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30a41));
    try std.testing.expectEqual(@as(u32, 0x0000_8000), s.fp[0] & 0xffff);
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 1);
    s.fpscr = 1 << 26;
    s.fp[2] = 0x4780_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30a41));
    try std.testing.expectEqual(@as(u32, 0x0000_7c00), s.fp[0] & 0xffff);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 1);
}

test "narrowing to a half raises OFC only when the mode in force carries past the exponent range, E2.1.169" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x477f_f000;
    s.fpscr = 2 << 22;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30a41));
    try std.testing.expectEqual(@as(u32, 0x0000_7bff), s.fp[0] & 0xffff);
    try std.testing.expectEqual(@as(u32, 1 << 4), s.fpscr & ((1 << 4) | (1 << 2)));
    s.fpscr = 2 << 22;
    s.fp[2] = 0x7f00_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30a41));
    try std.testing.expectEqual(@as(u32, 0x0000_7bff), s.fp[0] & 0xffff);
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 2)), s.fpscr & ((1 << 4) | (1 << 2)));
}

test "VCVTB and VCVTT carry a half to and from double precision, C2.4.320" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0000_3c00;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb22b41));
    try std.testing.expectEqual(@as(u32, 0x3ff0_0000), s.fp[5]);
    try std.testing.expectEqual(@as(u32, 0), s.fp[4]);
    s.fp[2] = 0;
    s.fp[3] = 0xc008_0000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeeb30b41));
    try std.testing.expectEqual(@as(u32, 0x0000_c200), s.fp[0]);
}

test "overflow raises OFC only when the rounded magnitude leaves the exponent range, E2.1.169" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv7em, false);
    s.fp[2] = 0x7f7f_ffff;
    s.fp[3] = 0x7300_0000;
    s.fpscr = 2 << 22;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x7f7f_ffff), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 4), s.fpscr & ((1 << 4) | (1 << 2)));
    s.fpscr = 2 << 22;
    s.fp[3] = 0x7f7f_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0x7f7f_ffff), s.fp[1]);
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 2)), s.fpscr & ((1 << 4) | (1 << 2)));
}

test "an addition within an ulp of the largest finite value still reports its rounding, A2.5.2" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv7em, false);
    s.fp[2] = 0x73c0_0000;
    s.fp[3] = 0xff7f_ffff;
    s.fpscr = 3 << 22;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee710a21));
    try std.testing.expectEqual(@as(u32, 0xff7f_fffd), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 4), s.fpscr & (1 << 4));
}

test "an integer too large for the half format overflows rather than converting silently, E2.1.169" {
    var s: State = .{};
    var h = machine(.armv8_1m_main, true);
    s.fp[2] = 0x0010_0000;
    try std.testing.expectEqual(.next, half(&s, &h, 0xeef80941));
    try std.testing.expectEqual(@as(u32, 0x0000_7c00), s.fp[1]);
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 2)), s.fpscr & ((1 << 4) | (1 << 2)));
}

test "a fixed-point source too small for the half format underflows and one too large overflows to infinity whatever the mode, C2.4.324" {
    var s: State = .{};
    var h = machine(.armv8_1m_main, true);
    s.fp[1] = 1;
    s.fpscr = 0;
    try std.testing.expectEqual(.next, half(&s, &h, 0xeefb09c0));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 3)), s.fpscr & ((1 << 4) | (1 << 3)));
    s.fp[1] = 0x7fff_ffff;
    s.fpscr = 2 << 22;
    try std.testing.expectEqual(.next, half(&s, &h, 0xeefa09ef));
    try std.testing.expectEqual(@as(u32, 0x0000_7c00), s.fp[1]);
    try std.testing.expectEqual(@as(u32, (1 << 4) | (1 << 2)), s.fpscr & ((1 << 4) | (1 << 2)));
}

test "FZ16 flushing a fixed-point conversion reports underflow alone rather than underflow and inexact, B4.8.1" {
    var s: State = .{ .control = State.control_fpca };
    var h = machine(.armv8_1m_main, true);
    s.fp[1] = 1;
    s.fpscr = 1 << 19;
    try std.testing.expectEqual(.next, half(&s, &h, 0xeefb09c0));
    try std.testing.expectEqual(@as(u32, 0), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 3), s.fpscr & ((1 << 4) | (1 << 3)));
}

fn veneer(m: *Machine) void {
    m.secure_extension = true;
}

test "VSCCLRM clears the registers a Secure veneer must not leak, and only those, C2.4.470" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    for (&s.fp, 0..) |*r, i| r.* = @intCast(i + 1);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecdf0a0f));
    try std.testing.expectEqual(@as(u32, 1), s.fp[0]);
    for (1..16) |i| try std.testing.expectEqual(@as(u32, 0), s.fp[i]);
    try std.testing.expectEqual(@as(u32, 17), s.fp[16]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec9f0b20));
    for (s.fp) |r| try std.testing.expectEqual(@as(u32, 0), r);
}

test "VSCCLRM names registers past the bank without touching what is not there, C2.4.470" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    s.fp[31] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec9f0a40));
    try std.testing.expectEqual(@as(u32, 0), s.fp[31]);
    s.fp[0] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecdf0b02));
    try std.testing.expectEqual(one, s.fp[0]);
}

test "VSCCLRM is undefined outside Secure state and on a core without the Security Extension, C2.4.470" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    s.fp[1] = one;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xecdf0a0f));
    try std.testing.expectEqual(one, s.fp[1]);
    s.secure = true;
    m.secure_extension = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xecdf0a0f));
    try std.testing.expectEqual(one, s.fp[1]);
}

test "VSCCLRM leaves the registers and VPR alone while no Secure floating-point context is active, and needs the unit enabled once one is, C2.4.470" {
    var s: State = .{ .secure = true };
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    m.enabled = false;
    s.fp[0] = one;
    s.vpr = 0x5555;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec9f0a01));
    try std.testing.expectEqual(one, s.fp[0]);
    try std.testing.expectEqual(@as(u32, 0x5555), s.vpr);
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_fpca);
    s.control |= State.control_sfpa;
    try std.testing.expectEqual(.no_coprocessor, exec(&s, &m, 0xec9f0a01));
    try std.testing.expectEqual(one, s.fp[0]);
    m.enabled = true;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec9f0a01));
    try std.testing.expectEqual(@as(u32, 0), s.fp[0]);
    try std.testing.expectEqual(@as(u32, 0), s.vpr);
    try std.testing.expect(s.control & State.control_fpca != 0);
}

test "an Armv7-M context takes the four rounding and flush fields from FPDSCR and leaves the flags alone, B1.5.7 A2.5.3" {
    var s: State = .{ .fpscr = 0xf040_009f };
    var m = machine(.armv7em, false);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb0_0a41));
    try std.testing.expectEqual(@as(u32, 0xf000_009f), s.fpscr);
    var v8: State = .{ .fpscr = 0xf040_009f };
    var eight = machine(.armv8m_main, false);
    try std.testing.expectEqual(.next, exec(&v8, &eight, 0xeeb0_0a41));
    try std.testing.expectEqual(eight.defaultFpscr(), v8.fpscr);
}

fn secure(p: Architecture) Machine {
    var m = machine(p, false);
    m.secure_extension = true;
    return m;
}

test "VLSTM defers the Secure context to the frame it names, and the next instruction writes it, C2.4.368" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    m.callee = true;
    s.r[1] = 8;
    for (&s.fp, 0..) |*r, i| r.* = @intCast(i + 1);
    s.fpscr = 0x2000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(@as(?u32, 8), m.owed);
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_fpca);
    try std.testing.expectEqual(@as(u32, 1), s.fp[0]);
    try std.testing.expectEqual(@as(u32, 0), m.peek(u32, 8).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb00a40));
    try std.testing.expectEqual(@as(?u32, null), m.owed);
    try std.testing.expectEqual(@as(u32, 1), m.peek(u32, 8).?);
    try std.testing.expectEqual(@as(u32, 16), m.peek(u32, 8 + 60).?);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), m.peek(u32, 8 + 0x40).?);
    for (&s.fp) |r| try std.testing.expectEqual(@as(u32, 0), r);
    try std.testing.expect(s.control & State.control_fpca != 0);
}

test "with FPCCR_S.TS clear the deferred write leaves the registers where they were, E2.1.332" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    s.r[1] = 8;
    for (&s.fp, 0..) |*r, i| r.* = @intCast(i + 1);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeb00a40));
    try std.testing.expectEqual(@as(u32, 1), m.peek(u32, 8).?);
    try std.testing.expectEqual(@as(u32, 16), m.peek(u32, 8 + 60).?);
    for (&s.fp, 0..) |r, i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), r);
}

test "VLSTM faults on a misaligned frame whether or not the write is deferred, C2.4.368" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    s.r[1] = 4;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(@as(?u32, null), m.owed);
    m.lspen = false;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xec210a00));
}

test "VLSTM writes the frame itself where lazy preservation is disabled, C2.4.368" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    m.lspen = false;
    m.callee = true;
    s.r[1] = 8;
    for (&s.fp, 0..) |*r, i| r.* = @intCast(i + 1);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(@as(?u32, null), m.owed);
    try std.testing.expectEqual(@as(u32, 1), m.peek(u32, 8).?);
    try std.testing.expectEqual(@as(u32, 16), m.peek(u32, 8 + 60).?);
    for (s.fp) |r| try std.testing.expectEqual(@as(u32, 0), r);
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_fpca);
}

test "VLLDM takes back what VLSTM deferred without reading, and reloads the frame otherwise, C2.4.367" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    s.r[1] = 8;
    m.owed = 8;
    s.fp[0] = one;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec310a00));
    try std.testing.expectEqual(@as(?u32, null), m.owed);
    try std.testing.expectEqual(one, s.fp[0]);
    try std.testing.expect(s.control & State.control_fpca != 0);
    for (0..17) |i| _ = m.poke(u32, 8 + 4 * @as(u32, @intCast(i)), @intCast(i + 100));
    s.fp[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec310a00));
    try std.testing.expectEqual(@as(u32, 100), s.fp[0]);
    try std.testing.expectEqual(@as(u32, 115), s.fp[15]);
    try std.testing.expectEqual(@as(u32, 116), s.fpscr & ~fp.ltpsize);
}

test "VLSTM and VLLDM are a NOP without a Secure context and UNDEFINED outside Secure state, C2.4.367 C2.4.368" {
    var s: State = .{ .secure = true };
    var m = secure(.armv8m_main);
    s.r[1] = 8;
    s.fp[0] = one;
    for ([_]u32{ 0xec210a00, 0xec310a00 }) |code| {
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(@as(?u32, null), m.owed);
        try std.testing.expectEqual(one, s.fp[0]);
        try std.testing.expectEqual(@as(u32, 0), s.control);
    }
    s.secure = false;
    s.control = State.control_sfpa;
    for ([_]u32{ 0xec210a00, 0xec310a00 }) |code| try std.testing.expectEqual(.undefined, exec(&s, &m, code));
}

test "VLSTM and VLLDM fault on a frame that is not doubleword aligned, C2.4.367 C2.4.368" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    m.lspen = false;
    s.r[1] = 4;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xec310a00));
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec210a00));
}

test "FLDMIAX transfers half of its length in registers and advances the base by all of it, C2.4.63" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    s.r[1] = 8;
    for (0..8) |i| _ = m.poke(u32, 8 + 4 * @as(u32, @intCast(i)), @intCast(i + 1));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xecb10b07));
    try std.testing.expectEqual(@as(u32, 1), s.fp[0]);
    try std.testing.expectEqual(@as(u32, 6), s.fp[5]);
    try std.testing.expectEqual(@as(u32, 0), s.fp[6]);
    try std.testing.expectEqual(@as(u32, 8 + 28), s.r[1]);
}

test "the vector predication register is the only state the extension adds, and a core without it has none, C2.4.316" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.r[1] = 0xffff_1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeec1a10));
    try std.testing.expectEqual(@as(u32, 0xffff_1234), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeefc0a10));
    try std.testing.expectEqual(@as(u32, 0xffff_1234), s.r[0]);
    m.vector = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xeefc0a10));
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xeeec1a10));
}

test "the lazy frame carries the vector predication register, and VSCCLRM clears it, C2.4.368 C2.4.470" {
    var s: State = .{ .secure = true, .control = State.control_sfpa };
    var m = secure(.armv8m_main);
    m.lspen = false;
    m.callee = true;
    s.r[1] = 8;
    s.vpr = 0x5555;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec210a00));
    try std.testing.expectEqual(@as(u32, 0x5555), m.peek(u32, 8 + 0x44).?);
    try std.testing.expectEqual(@as(u32, 0), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec310a00));
    try std.testing.expectEqual(@as(u32, 0x5555), s.vpr);
}

test "a floating-point context the core creates for itself starts from FPDSCR, B4.4.1" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fpscr = 0x0002_0000 | (2 << 22);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee300a20));
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & fp.ltpsize_field);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & (3 << 22));
    s.fpscr = 0x0002_0000 | (2 << 22);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee300a20));
    try std.testing.expectEqual(@as(u32, 0x0002_0000 | (2 << 22)), s.fpscr & ~@as(u32, 0x9f));
}

test "a Secure instruction that finds SFPA clear starts a context of its own, and a context the core creates carries no predicate over, E2.1.127" {
    var s: State = .{ .secure = true, .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    m.secure_extension = true;
    s.fpscr = 0x00c0_0000 | fp.ltpsize;
    s.vpr = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee300a20));
    try std.testing.expectEqual(fp.ltpsize, s.fpscr);
    try std.testing.expectEqual(@as(u32, 0), s.vpr);
    try std.testing.expect(s.control & State.control_sfpa != 0);
    var handler: State = .{ .vpr = 0x00ff_1234 };
    try std.testing.expectEqual(.next, exec(&handler, &m, 0xee300a20));
    try std.testing.expectEqual(@as(u32, 0), handler.vpr);
}

test "FPSCR.LTPSIZE reads as four while the core holds no floating-point context, B5.5.1" {
    var s: State = .{ .fpscr = 2 << 16 };
    try std.testing.expectEqual(@as(u32, 4), fp.tailSize(&s));
    s.control = State.control_fpca;
    try std.testing.expectEqual(@as(u32, 2), fp.tailSize(&s));
}

test "the sixteen-bit fixed-point conversions carry the low half of the register, C2.4.324" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0x0000_1000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefa0942));
    try std.testing.expectEqual(@as(u32, 0x0000_3c00), s.fp[1]);
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefe0942));
    try std.testing.expectEqual(@as(u32, 0x0000_1000), s.fp[1]);
    s.fp[1] = 0xdead_ffff;
    s.fpscr = 0;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefa0942));
    try std.testing.expectEqual(@as(u32, 0x0000_8c00), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x1f);
    s.fp[1] = 0xdead_ffff;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefb0942));
    try std.testing.expectEqual(@as(u32, 0x0000_4c00), s.fp[1]);
    try std.testing.expectEqual(@as(u32, 1 << 4), s.fpscr & 0x1f);
}

test "a fixed-point conversion whose fraction count runs past the width scales the other way, C2.4.324" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.fp[1] = 0x0000_1000;
    try std.testing.expectEqual(.next, half(&s, &m, 0xeefa0968));
    try std.testing.expectEqual(@as(u32, 0x0000_7000), s.fp[1]);
    var w = machine(.armv7em, false);
    s.fp[1] = 0x0000_1000;
    try std.testing.expectEqual(.next, exec(&s, &w, 0xeefa0a68));
    try std.testing.expectEqual(@as(u32, 0x4600_0000), s.fp[1]);
}

test "an arithmetic answers with the NaN the manual ranks first rather than the one the host hands back, E2.1.166" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 0, 0xfff8_0000_0000_0002);
    double(&s, 2, 0x7ff0_0000_0000_0003);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee301b02));
    try std.testing.expectEqual(@as(u64, 0x7ff8_0000_0000_0003), doubled(&s, 1));
    try std.testing.expectEqual(@as(u32, 1), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 2, 0x3ff0_0000_0000_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee301b02));
    try std.testing.expectEqual(@as(u64, 0xfff8_0000_0000_0002), doubled(&s, 1));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "VNMLS negates the accumulator NaN it answers with where VMLA keeps it, C2.4.420 C2.4.379" {
    var s: State = .{};
    var m = machine(.armv7em, false);
    double(&s, 0, 0x0000_0000_3ff0_0000);
    double(&s, 2, 0x0000_0000_3ff0_0000);
    double(&s, 1, 0xffff_ffff_7fef_ffff);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee101b02));
    try std.testing.expectEqual(@as(u64, 0x7fff_ffff_7fef_ffff), doubled(&s, 1));
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
    s.fpscr = 0;
    double(&s, 1, 0xffff_ffff_7fef_ffff);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee001b02));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_7fef_ffff), doubled(&s, 1));
    try std.testing.expectEqual(@as(u32, 0x18), s.fpscr & 0x9f);
}

test "VMOV moves a word between a general-purpose register and one lane of a vector, and the byte and halfword lanes extend as the size letter says, C2.4.393 C2.4.402" {
    var s: State = .{};
    var m = machine(.armv8_1m_main, true);
    s.r[3] = 0xcafe_babe;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee24_3b10));
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), s.fp[9]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee34_3b10));
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), s.r[3]);
    s.fp[0] = 0;
    s.r[3] = 0x1234_8001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee00_3b70));
    try std.testing.expectEqual(@as(u32, 0x8001_0000), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee10_3b70));
    try std.testing.expectEqual(@as(u32, 0xffff_8001), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee90_3b70));
    try std.testing.expectEqual(@as(u32, 0x0000_8001), s.r[3]);
    s.r[3] = 0xffff_ffa5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee40_3b30));
    try std.testing.expectEqual(@as(u32, 0x8001_a500), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee50_3b30));
    try std.testing.expectEqual(@as(u32, 0xffff_ffa5), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeed0_3b30));
    try std.testing.expectEqual(@as(u32, 0x0000_00a5), s.r[3]);
}

test "the word lane belongs to the floating-point extension of Armv7-M, and only the byte and halfword lanes need MVE, C2.4.393" {
    var s: State = .{};
    var m = machine(.armv7em, true);
    s.r[3] = 0x0123_4567;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee05_3b10));
    try std.testing.expectEqual(@as(u32, 0x0123_4567), s.fp[10]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee15_3b10));
    try std.testing.expectEqual(@as(u32, 0x0123_4567), s.r[3]);
}

test "VLDR and VSTR move a system register straight to and from memory, and the offset, pre-index and post-index forms all write back what the manual says, C2.4.364 C2.4.484" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fpscr = 0x00c4_0000;
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed81_2f80));
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), m.peek(u32, 8).?);
    try std.testing.expectEqual(@as(u32, 8), s.r[1]);
    s.fpscr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed91_2f80));
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), s.fpscr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeda1_2f81));
    try std.testing.expectEqual(@as(u32, 12), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), m.peek(u32, 12).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeca1_2f82));
    try std.testing.expectEqual(@as(u32, 20), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), m.peek(u32, 12).?);
    s.r[1] = 24;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed01_2f81));
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), m.peek(u32, 20).?);
}

test "the flag half of FPSCR, the predication register and the lane predicate each move only their own bits, C2.4.364 C2.4.484" {
    var s: State = .{ .control = State.control_fpca };
    var m = machine(.armv8_1m_main, true);
    s.fpscr = 0xf8c4_0000;
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed81_4f80));
    try std.testing.expectEqual(@as(u32, 0xf800_0000), m.peek(u32, 8).?);
    s.fpscr = 0x00c4_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed91_4f80));
    try std.testing.expectEqual(@as(u32, 0xf8c4_0000), s.fpscr);
    s.vpr = 0x0f0f_1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedc1_8f80));
    try std.testing.expectEqual(@as(u32, 0x0f0f_1234), m.peek(u32, 8).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedc1_af81));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), m.peek(u32, 12).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedd1_af81));
    try std.testing.expectEqual(@as(u32, 0x0f0f_1234), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedd1_8f81));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), s.vpr);
}

test "VMRS and VMSR reach the flags and the two context payloads the Armv8.1-M reg field names, C2.4.406 C2.4.407" {
    var s: State = .{ .secure = true, .control = State.control_fpca | State.control_sfpa };
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    s.fpscr = 0x08c4_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef21a10));
    try std.testing.expectEqual(@as(u32, 0x0800_0000), s.r[1]);
    s.r[1] = 0xf000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee21a10));
    try std.testing.expectEqual(@as(u32, 0xf0c4_0000), s.fpscr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeff2a10));
    try std.testing.expectEqual(@as(u32, 0x80c4_0000), s.r[2]);
    try std.testing.expectEqual(m.nonSecureFpscr(), s.fpscr);
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_sfpa);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeef2a10));
    try std.testing.expectEqual(@as(u32, 0x00c4_0000), s.fpscr);
    try std.testing.expectEqual(State.control_sfpa, s.control & State.control_sfpa);
    s.secure = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xeeff2a10));
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xeefe2a10));
}

test "the floating-point context payload carries SFPA in its top bit and resets FPSCR to the Non-secure default when it is stored, C2.4.364 C2.4.484" {
    var s: State = .{ .secure = true, .control = State.control_fpca | State.control_sfpa };
    var m = machine(.armv8_1m_main, true);
    veneer(&m);
    s.fpscr = 0x08c4_0000;
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedc1_ef80));
    try std.testing.expectEqual(@as(u32, 0x88c4_0000), m.peek(u32, 8).?);
    try std.testing.expectEqual(m.nonSecureFpscr(), s.fpscr);
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_sfpa);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedd1_ef80));
    try std.testing.expectEqual(@as(u32, 0x08c4_0000), s.fpscr);
    try std.testing.expectEqual(State.control_sfpa, s.control & State.control_sfpa);
    s.secure = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xedc1_ef80));
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xedc1_cf80));
}
