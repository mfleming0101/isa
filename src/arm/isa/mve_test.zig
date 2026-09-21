//! Tests for the MVE vector instructions: the lane helpers in src/arm/isa/mve.zig
//! and the semantics in src/sem/arm/mve.zig. `Machine` is a minimal host with
//! 256 bytes of memory that answers every capability query as an Armv8.1-M
//! core with MVE and full floating point; each test steps one assembled word
//! and checks registers, memory, FPSCR and VPR. Run with `zig build test`.

const std = @import("std");
const State = @import("state.zig").State;
const step = @import("step.zig");
const free: step.Model.Costs = @splat(.{ .cycles = 0, .taken = 0 });
const instruction = @import("instruction.zig");
const Architecture = @import("architecture.zig").Architecture;
const decode = @import("decode.zig");
const mve = @import("mve.zig");
const fp = @import("fp.zig");

const Machine = struct {
    const Self = @This();

    bytes: [256]u8 = @splat(0),
    model: step.Model,
    vector: bool = true,

    /// Four implemented exception priority bits.
    pub fn priorityBits(_: *Self) u4 {
        return 4;
    }

    /// The architecture the model decodes for.
    pub fn architecture(self: *Self) Architecture {
        return self.model.decoding.architecture;
    }

    /// No Security Extension.
    pub fn security(_: *Self) bool {
        return false;
    }

    /// Double-precision arithmetic present.
    pub fn doublePrecision(_: *Self) bool {
        return true;
    }

    /// Half-precision arithmetic present.
    pub fn halfPrecision(_: *Self) bool {
        return true;
    }

    /// FPv5 instructions present.
    pub fn fpv5(_: *Self) bool {
        return true;
    }

    /// No PACBTI extension.
    pub fn pacbti(_: *Self) bool {
        return false;
    }

    /// The Non-secure floating-point context the FPCXT_NS rows move is present.
    pub fn treatAsSecure(_: *Self) bool {
        return true;
    }

    /// MVE present while vector is set.
    pub fn mve(self: *Self) bool {
        return self.vector;
    }

    /// FPCCR.ASPEN set: a context is created on first use.
    pub fn automaticFpState(_: *Self) bool {
        return true;
    }

    /// FPDSCR: zero with the fixed fields.
    pub fn defaultFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
    }

    /// The Non-secure FPSCR: zero with the fixed fields.
    pub fn nonSecureFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
    }

    /// No lazy floating-point frame pending.
    pub fn lazyFpFrame(_: *Self) ?u32 {
        return null;
    }

    /// A lazy frame would not hold the callee-saved registers.
    pub fn lazyFpCallee(_: *Self) bool {
        return false;
    }

    /// FPCCR.LSPEN set.
    pub fn lazyFpEnabled(_: *Self) bool {
        return true;
    }

    /// Ignores the lazy frame, since none is ever pending.
    pub fn setLazyFp(_: *Self, _: ?u32) void {}

    /// CP10 enabled.
    pub fn coprocessorEnabled(_: *Self) bool {
        return true;
    }

    /// CCR.UNALIGN_TRP clear.
    pub fn trapsUnaligned(_: *Self) bool {
        return false;
    }

    /// CCR.DIV_0_TRP clear.
    pub fn trapsDivideByZero(_: *Self) bool {
        return false;
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

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
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
};

fn reset() State {
    return .{ .fpscr = fp.ltpsize };
}

fn predicated(vpr: u32) State {
    return .{ .fpscr = fp.ltpsize, .control = State.control_fpca, .vpr = vpr };
}

fn machine() Machine {
    return .{ .model = .{ .decoding = decode.selectionOf(.armv8_1m_main), .costs = free } };
}

fn exec(s: *State, m: *Machine, code: u32) instruction.Outcome {
    return step.call(Machine, s, m, code, m.model.decoding.groups);
}

fn filled(m: *Machine) void {
    for (0..16) |i| std.mem.writeInt(u32, m.bytes[4 * i ..][0..4], @as(u32, 0x8172_6354) +% @as(u32, @intCast(i)) *% 0x0101_0101, .little);
}

test "a vector register is four of the floating-point registers and an element is a field of one, B1.4.1" {
    var s = reset();
    mve.setLane(&s, 1, 8, 5, 0xab);
    try std.testing.expectEqual(@as(u32, 0x0000_ab00), s.fp[5]);
    try std.testing.expectEqual(@as(u32, 0xab), mve.lane(&s, 1, 8, 5));
    mve.setLane(&s, 1, 8, 4, 0xcd);
    try std.testing.expectEqual(@as(u32, 0x0000_abcd), s.fp[5]);
    mve.setLane(&s, 1, 16, 3, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234_abcd), s.fp[5]);
    mve.setLane(&s, 7, 32, 3, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.fp[31]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), mve.lane(&s, 7, 32, 3));
}

test "a contiguous vector load fills every lane and a store empties it, C2.4.365" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual([_]u32{ 0x8172_6354, 0x8273_6455, 0x8374_6556, 0x8475_6657 }, s.fp[0..4].*);
    s.r[1] = 0x80;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed811f00));
    try std.testing.expectEqual(@as(u32, 0x8172_6354), m.peek(u32, 0x80).?);
    try std.testing.expectEqual(@as(u32, 0x8475_6657), m.peek(u32, 0x8c).?);
}

test "a widening vector load extends each element the way its data type names, C2.4.365" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed900e80));
    try std.testing.expectEqual([_]u32{ 0x0063_0054, 0xff81_0072, 0x0064_0055, 0xff82_0073 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfd900e80));
    try std.testing.expectEqual([_]u32{ 0x0063_0054, 0x0081_0072, 0x0064_0055, 0x0082_0073 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed9b0f00));
    try std.testing.expectEqual([_]u32{ 0x0000_6354, 0xffff_8172, 0x0000_6455, 0xffff_8273 }, s.fp[0..4].*);
}

test "a vector access whose address is not a multiple of the element size faults whatever CCR says, E2.1.292" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[0] = 1;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xed801f00));
    s.r[0] = 2;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed9b0f00));
    s.r[0] = 4;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed901f00));
}

test "a vector load writes its base back before or after the access, and only when asked, C2.4.365" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[0] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x8576_6758), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xedb01f04));
    try std.testing.expectEqual(@as(u32, 0x20), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x897a_6b5c), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec301f04));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x897a_6b5c), s.fp[0]);
}

test "a core without the extension has no vector instructions at all, B1.4" {
    var s = reset();
    var m = machine();
    m.vector = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xed801f00));
    try std.testing.expectEqual(@as(u32, 0), s.fp[0]);
}

fn vectors(s: *State) void {
    for ([_]u32{ 0x0102_0304, 0x1112_1314, 0xf1f2_f3f4, 0x8182_8384 }, 0..) |v, i| s.fp[4 + i] = v;
    for ([_]u32{ 0x0001_0203, 0x0405_0607, 0x0809_0a0b, 0xfefd_fcfb }, 0..) |v, i| s.fp[8 + i] = v;
}

test "every lane of the destination takes the same operation over the matching lanes, C2.4.283" {
    var s = reset();
    var m = machine();
    vectors(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 0x0103_0507, 0x1517_191b, 0xf9fb_fdff, 0x8080_807f }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef020844));
    try std.testing.expectEqual([_]u32{ 0x0103_0507, 0x1517_191b, 0xf9fb_fdff, 0x7f7f_7f7f }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff220844));
    try std.testing.expectEqual([_]u32{ 0x0101_0101, 0x0d0d_0d0d, 0xe9e9_e9e9, 0x8284_8689 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220954));
    try std.testing.expectEqual([_]u32{ 0x0a10_110c, 0x9354_fd8c, 0x168c_037c, 0x65e0_e26c }, s.fp[0..4].*);
}

test "an element whose bytes the predicate disagrees about takes only the bytes it names, C2.4.304 C2.4.347" {
    var s = predicated(0x0088_0001);
    var m = machine();
    vectors(&s);
    s.fp[0..4].* = @splat(0xdead_beef);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 0xdead_be07, 0xdead_beef, 0xdead_beef, 0xdead_beef }, s.fp[0..4].*);
    s.vpr = 0x0088_0001;
    s.fp[0..4].* = @splat(0xdead_beef);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff020154));
    try std.testing.expectEqual([_]u32{ 0xdead_be07, 0xdead_beef, 0xdead_beef, 0xdead_beef }, s.fp[0..4].*);
    s.vpr = 0x0088_0002;
    s.fp[0..4].* = @splat(0xdead_beef);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 0xdead_05ef, 0xdead_beef, 0xdead_beef, 0xdead_beef }, s.fp[0..4].*);
}

test "the bitwise vector operations take no size, because every lane is the same word, C2.4.288" {
    var s = reset();
    var m = machine();
    vectors(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef020154));
    try std.testing.expectEqual(@as(u32, 0x0000_0200), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220154));
    try std.testing.expectEqual(@as(u32, 0x0103_0307), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff020154));
    try std.testing.expectEqual(@as(u32, 0x0103_0107), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef120154));
    try std.testing.expectEqual(@as(u32, 0x0102_0104), s.fp[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef320154));
    try std.testing.expectEqual(@as(u32, 0xfffe_fffc), s.fp[0]);
}

test "VMOV moves two 32-bit lanes and two general-purpose registers together, the first register with the lower lane, C2.4.400 C2.4.401" {
    var s = reset();
    var m = machine();
    s.fp[0..4].* = .{ 0x1010_1010, 0x1111_1111, 0x1212_1212, 0x1313_1313 };
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec040f03));
    try std.testing.expectEqual(@as(u32, 0x1010_1010), s.r[3]);
    try std.testing.expectEqual(@as(u32, 0x1212_1212), s.r[4]);
    s.r[2] = 0xaaaa;
    s.r[3] = 0xbbbb;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec130f12));
    try std.testing.expectEqual([_]u32{ 0x1010_1010, 0xaaaa, 0x1212_1212, 0xbbbb }, s.fp[0..4].*);
}

test "VDUP puts one general-purpose register in every lane, C2.4.303" {
    var s = reset();
    var m = machine();
    s.r[1] = 0x0f1e_2d3c;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea01b10));
    try std.testing.expectEqual([_]u32{0x0f1e_2d3c} ** 4, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea01b30));
    try std.testing.expectEqual([_]u32{0x2d3c_2d3c} ** 4, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee01b10));
    try std.testing.expectEqual([_]u32{0x3c3c_3c3c} ** 4, s.fp[0..4].*);
}

fn compared(s: *State) void {
    for ([_]u32{ 1, 2, 3, 4 }, 0..) |v, i| s.fp[4 + i] = v;
    for ([_]u32{ 1, 5, 3, 0 }, 0..) |v, i| s.fp[8 + i] = v;
}

test "a comparison puts its answer for a lane in every byte the lane covers, C2.4.319" {
    var s = reset();
    var m = machine();
    compared(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230f04));
    try std.testing.expectEqual(@as(u32, 0x0000_0f0f), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230f84));
    try std.testing.expectEqual(@as(u32, 0x0000_f0f0), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe231f84));
    try std.testing.expectEqual(@as(u32, 0x0000_00f0), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe231f05));
    try std.testing.expectEqual(@as(u32, 0x0000_f000), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe130f04));
    try std.testing.expectEqual(@as(u32, 0x0000_cfcf), s.vpr);
    s.r[3] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230f43));
    try std.testing.expectEqual(@as(u32, 0x0000_0f00), s.vpr);
}

test "the register the core reserves reads as zero rather than as the program counter, C2.4.319" {
    var s = reset();
    var m = machine();
    compared(&s);
    s.pc = 0x1000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230f4f));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230fcf));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), s.vpr);
}

test "VPT opens a block over what follows it and closes when the block runs out, C2.4.430" {
    var s = reset();
    var m = machine();
    compared(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe630f04));
    try std.testing.expectEqual(@as(u32, 0x0088_0f0f), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 2, 0, 6, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x0000_0f0f), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 2, 7, 6, 4 }, s.fp[0..4].*);
}

test "the else arm of a block runs where the then arm did not, C2.4.430" {
    var s = reset();
    var m = machine();
    compared(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe639f84));
    try std.testing.expectEqual(@as(u32, 0x00cc_00f0), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff220844));
    try std.testing.expectEqual([_]u32{ 0, 0xffff_fffd, 0, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x0088_ff0f), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 2, 0xffff_fffd, 6, 4 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x0000_ff0f), s.vpr);
}

test "VPST opens a block over the predicate P0 already holds, and VPNOT inverts it, C2.4.429" {
    var s = reset();
    var m = machine();
    compared(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe230f04));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe710f4d));
    try std.testing.expectEqual(@as(u32, 0x0088_0f0f), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220954));
    try std.testing.expectEqual([_]u32{ 1, 0, 9, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe310f4d));
    try std.testing.expectEqual(@as(u32, 0x0000_f0f0), s.vpr);
}

test "VPSEL takes each byte from the source the predicate names, C2.4.428" {
    var s = predicated(0x0000_5a0f);
    var m = machine();
    for ([_]u32{ 0x0102_0304, 0x1112_1314, 0x2122_2324, 0x3132_3334 }, 0..) |v, i| s.fp[4 + i] = v;
    for ([_]u32{ 0xa1a2_a3a4, 0xb1b2_b3b4, 0xc1c2_c3c4, 0xd1d2_d3d4 }, 0..) |v, i| s.fp[8 + i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe330f05));
    try std.testing.expectEqual([_]u32{ 0x0102_0304, 0xb1b2_b3b4, 0x21c2_23c4, 0xd132_d334 }, s.fp[0..4].*);
}

test "VCTP marks the elements a loop tail leaves behind, C2.4.322" {
    var s = reset();
    var m = machine();
    s.r[3] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf023e801));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.vpr);
    s.r[3] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf023e801));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), s.vpr);
    s.r[3] = 9;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf023e801));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), s.vpr);
    s.r[3] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf003e801));
    try std.testing.expectEqual(@as(u32, 0x0000_001f), s.vpr);
    s.r[3] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf033e801));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.vpr);
}

test "VMSR and VMRS reach the P0 predicate field on its own, leaving the block masks alone, C2.4.407 C2.4.406" {
    var s = predicated(0x00ff_0000);
    var m = machine();
    s.r[2] = 0xabcd_1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeed2a10));
    try std.testing.expectEqual(@as(u32, 0x00ff_1234), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeefd1a10));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), s.r[1]);
}

test "the whole of VPR is privileged where its P0 field is not, C2.4.406 C2.4.407" {
    var s = predicated(0x0000_1234);
    s.control |= State.control_npriv;
    var m = machine();
    s.r[1] = 0x00ff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeec1a10));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), s.vpr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeefc1a10));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    s.r[1] = 0x00ff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeed1a10));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), s.vpr);
    s.control &= ~State.control_npriv;
    s.r[1] = 0x00ff_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeec1a10));
    try std.testing.expectEqual(@as(u32, 0x00ff_0000), s.vpr);
}

test "a masked lane of a vector load is zeroed rather than read, C2.4.365" {
    var s = predicated(0x0088_000f);
    var m = machine();
    filled(&m);
    s.fp[0..4].* = @splat(0xdead_beef);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xed901f00));
    try std.testing.expectEqual([_]u32{ 0x8172_6354, 0, 0, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x0000_000f), s.vpr);
}

test "a loop start with tail predication counts elements and names how wide they are, C2.4.492" {
    var s = reset();
    var m = machine();
    s.r[0] = 10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf020e001));
    try std.testing.expectEqual(@as(u32, 10), s.lr);
    try std.testing.expectEqual(@as(u32, 2 << 16), s.fpscr & fp.ltpsize_field);
    try std.testing.expectEqual(State.control_fpca, s.control & State.control_fpca);
    s.r[3] = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf003e001));
    try std.testing.expectEqual(@as(u32, 7), s.lr);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.ltpsize_field);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf00fe001));
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & fp.ltpsize_field);
}

test "a while loop whose count is zero branches past the body and names no size, C2.4.492" {
    var s = reset();
    var m = machine();
    s.pc = 0x10;
    s.lr = 0x1234;
    s.r[0] = 0;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf010c003));
    try std.testing.expectEqual(@as(u32, 0x18), s.pc);
    try std.testing.expectEqual(@as(u32, 0x1234), s.lr);
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & fp.ltpsize_field);
    s.r[0] = 6;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf010c003));
    try std.testing.expectEqual(@as(u32, 6), s.lr);
    try std.testing.expectEqual(@as(u32, 1 << 16), s.fpscr & fp.ltpsize_field);
}

test "LETP takes a whole vector off the count, and the pass that would take it past zero is the last, C2.4.103" {
    var s = reset();
    var m = machine();
    s.r[0] = 40;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf000e001));
    s.pc = 0x10;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf01fc003));
    try std.testing.expectEqual(@as(u32, 24), s.lr);
    try std.testing.expectEqual(@as(u32, 0x10), s.pc);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf01fc003));
    try std.testing.expectEqual(@as(u32, 8), s.lr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf01fc003));
    try std.testing.expectEqual(@as(u32, 8), s.lr);
    try std.testing.expectEqual(fp.ltpsize, s.fpscr & fp.ltpsize_field);
}

test "the last pass of a tail-predicated loop leaves the lanes past the count alone, B5.5.1" {
    var s = reset();
    var m = machine();
    compared(&s);
    s.r[0] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf020e001));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220844));
    try std.testing.expectEqual([_]u32{ 2, 7, 0, 0 }, s.fp[0..4].*);
    s.r[3] = 4;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf023e801));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.vpr);
}

fn sample(s: *State) void {
    for ([_]u32{ 0x7f80_0100, 0x8000_7fff, 0xfffe_0002, 0x1234_5678 }, 0..) |v, i| s.fp[4 + i] = v;
    for ([_]u32{ 0x0180_7f01, 0x7fff_8000, 0x0002_fffe, 0x8765_4321 }, 0..) |v, i| s.fp[8 + i] = v;
}

test "the three-register set reads its operands as the sign bit of the encoding says, C2.4.281" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef120044));
    try std.testing.expectEqual([_]u32{ 0x4080_4000, 0xffff_ffff, 0x0000_0000, 0xcccc_4ccc }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff020144));
    try std.testing.expectEqual([_]u32{ 0x4080_4001, 0x8080_8080, 0x8080_8080, 0x4d4d_4d4d }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220744));
    try std.testing.expectEqual([_]u32{ 0x7dff_81ff, 0xffff_0001, 0x0004_fffc, 0x8acf_1357 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff120654));
    try std.testing.expectEqual([_]u32{ 0x0180_0100, 0x7fff_7fff, 0x0002_0002, 0x1234_4321 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "the saturating pair say so where the cut loses something, C2.4.291" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef020054));
    try std.testing.expectEqual([_]u32{ 0x7f80_7f01, 0xffff_ffff, 0xff00_ff00, 0x997f_7f7f }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fpscr = fp.ltpsize;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb40744));
    try std.testing.expectEqual([_]u32{ 0x0180_7f01, 0x7fff_7fff, 0x0002_0002, 0x789b_4321 }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "the one-source set answers for each lane on its own, C2.4.276" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb00444));
    try std.testing.expectEqual([_]u32{ 0x0600_0006, 0x0007_0007, 0x0705_0706, 0x0000_0001 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb804c4));
    try std.testing.expectEqual([_]u32{ 7, 1, 14, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb005c4));
    try std.testing.expectEqual([_]u32{ 0xfe7f_80fe, 0x8000_7fff, 0xfffd_0001, 0x789a_bcde }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "VREV turns each group of elements end for end, C2.4.442" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb000c4));
    try std.testing.expectEqual([_]u32{ 0x017f_8001, 0x0080_ff7f, 0xfeff_0200, 0x2143_6587 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb40044));
    try std.testing.expectEqual([_]u32{ 0x8000_7fff, 0x7f01_0180, 0x4321_8765, 0xfffe_0002 }, s.fp[0..4].*);
}

test "the scalar forms read one general-purpose register for every lane, C2.4.281" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.r[4] = 0x81;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee231e64));
    try std.testing.expectEqual([_]u32{ 0x3f80_8100, 0x8040_7f7f, 0xfefe_0102, 0x2c5f_9278 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe021f64));
    try std.testing.expectEqual([_]u32{ 0, 0x0000_007e, 0x7e7d_0000, 0 }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "the multiply-accumulate pair differ in which of the three operands is the scalar, C2.4.380 C2.4.384" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.r[4] = 0x81;
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee030e44));
    try std.testing.expectEqual([_]u32{ 0x0000_0001, 0xffff_7f7f, 0x7f00_ff00, 0x9999_9999 }, s.fp[0..4].*);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee131e44));
    try std.testing.expectEqual([_]u32{ 0x4081_0181, 0x8081_8081, 0x007d_007d, 0x9b05_8df9 }, s.fp[0..4].*);
}

test "the immediate shifts read the element width out of the immediate field, C2.4.451" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef8f0052));
    try std.testing.expectEqual([_]u32{ 0x3fc0_0000, 0xc000_3fff, 0xffff_0001, 0x091a_2b3c }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef8f0252));
    try std.testing.expectEqual([_]u32{ 0x40c0_0100, 0xc000_4000, 0x00ff_0001, 0x091a_2b3c }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff9b0052));
    try std.testing.expectEqual([_]u32{ 0x03fc_0008, 0x0400_03ff, 0x07ff_0000, 0x0091_02b3 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "a saturating immediate shift clamps to the range its result is read in, C2.4.419 C2.4.421" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef890752));
    try std.testing.expectEqual([_]u32{ 0x7f80_0200, 0x8000_7ffe, 0xfefc_0004, 0x2468_7f7f }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fpscr &= ~fp.qc;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff890652));
    try std.testing.expectEqual([_]u32{ 0xfe00_0200, 0x0000_fe00, 0x0000_0004, 0x2468_acf0 }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "VSLI and VSRI leave the bits the shift did not reach where they were, C2.4.437 C2.4.446" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffa50552));
    try std.testing.expectEqual([_]u32{ 0xf000_2001, 0x000f_ffe0, 0xffc0_005e, 0x468a_cf01 }, s.fp[0..4].*);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff9b0452));
    try std.testing.expectEqual([_]u32{ 0x03fc_7808, 0x7c00_83ff, 0x07ff_f800, 0x8091_42b3 }, s.fp[0..4].*);
}

test "a shift by a register reads the amount as a signed byte, so one name shifts either way, C2.4.417" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef040442));
    try std.testing.expectEqual([_]u32{ 0xfeff_0000, 0x0000_00ff, 0xfff8_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef040552));
    try std.testing.expectEqual([_]u32{ 0x7f00_7f00, 0x8000_00ff, 0xfff8_0001, 0x007f_7f7f }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "the scalar shift takes one amount for every lane and shifts the destination in place, C2.4.418" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[4..8].*;
    s.r[4] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee351ee4));
    try std.testing.expectEqual([_]u32{ 0x7fff_0800, 0x8000_7fff, 0xfff0_0010, 0x7fff_7fff }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fp[0..4].* = s.fp[4..8].*;
    s.r[4] = 0xf9;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe3b1e64));
    try std.testing.expectEqual([_]u32{ 0x00ff_0002, 0x0100_0100, 0x01ff_fc00, 0x0024_68ad }, s.fp[0..4].*);
}

test "VBRSR turns the low bits of each element around and clears the rest, C2.4.283" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.r[4] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe031e64));
    try std.testing.expectEqual([_]u32{ 0x1f00_1000, 0x0000_1f1f, 0x1f0f_0008, 0x0905_0d03 }, s.fp[0..4].*);
}

test "VSHLC shifts the whole register as one number and carries through Rdm, C2.4.436" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[4..8].*;
    s.r[4] = 0x5a5a_5a5a;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea50fc4));
    try std.testing.expectEqual([_]u32{ 0xf000_201a, 0x000f_ffef, 0xffc0_0050, 0x468a_cf1f }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 2), s.r[4]);
}

test "the widening moves take every other element and may shift what they widen, C2.4.286 C2.4.435" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea80f42));
    try std.testing.expectEqual([_]u32{ 0xff80_0000, 0x0000_ffff, 0xfffe_0002, 0x0034_0078 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfeb51f42));
    try std.testing.expectEqual([_]u32{ 0x000f_f000, 0x0010_0000, 0x001f_ffc0, 0x0002_4680 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee310e03));
    try std.testing.expectEqual([_]u32{ 0x8000_0000, 0x0000_ff00, 0xfe00_0200, 0x3400_7800 }, s.fp[0..4].*);
}

test "the narrowing moves land in every other element and leave the rest alone, C2.4.289 C2.4.402" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe350e83));
    try std.testing.expectEqual([_]u32{ 0x0180_0100, 0x7fff_7fff, 0x0002_0002, 0x8765_5678 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee331e03));
    try std.testing.expectEqual([_]u32{ 0x7f80_7f01, 0x80ff_7f00, 0xfe02_02fe, 0x7f65_7f21 }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee350e83));
    try std.testing.expectEqual([_]u32{ 0x0180_ffff, 0x7fff_0000, 0x0002_0000, 0x8765_ffff }, s.fp[0..4].*);
}

test "the narrowing shifts cut to half the width they read, C2.4.443 C2.4.425" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee8d0fc3));
    try std.testing.expectEqual([_]u32{ 0x01f0_7f20, 0x7f00_80ff, 0x00ff_ff00, 0x8746_43cf }, s.fp[0..4].*);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe9b1fc3));
    try std.testing.expectEqual([_]u32{ 0x0008_7f01, 0x0400_8000, 0xf000_fffe, 0xa2b4_4321 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee8d0f42));
    try std.testing.expectEqual([_]u32{ 0x017f_7f20, 0x7f80_807f, 0x00ff_ff00, 0x877f_437f }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe9b1fc2));
    try std.testing.expectEqual([_]u32{ 0xffff_7f01, 0x0000_8000, 0x0000_fffe, 0xffff_4321 }, s.fp[0..4].*);
}

test "one selector says which element width the immediate byte fills and where it sits, C2.4.287" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef810a52));
    try std.testing.expectEqual([_]u32{ 0x1200_1200, 0x1200_1200, 0x1200_1200, 0x1200_1200 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef810c72));
    try std.testing.expectEqual([_]u32{ 0xffff_ed00, 0xffff_ed00, 0xffff_ed00, 0xffff_ed00 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff820e75));
    try std.testing.expectEqual([_]u32{ 0x00ff_00ff, 0xff00_ff00, 0x00ff_00ff, 0xff00_ff00 }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef810e52));
    try std.testing.expectEqual([_]u32{ 0x1212_1212, 0x1212_1212, 0x1212_1212, 0x1212_1212 }, s.fp[0..4].*);
}

test "the odd selectors join the immediate to what the destination holds, C2.4.408 C2.4.282" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef810552));
    try std.testing.expectEqual([_]u32{ 0x0192_7f01, 0x7fff_8000, 0x0012_fffe, 0x8777_4321 }, s.fp[0..4].*);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef810972));
    try std.testing.expectEqual([_]u32{ 0x0180_7f01, 0x7fed_8000, 0x0000_ffec, 0x8765_4321 }, s.fp[0..4].*);
}

test "the adding reductions answer in one register, or in a pair, and may join what it held, C2.4.306 C2.4.305" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef14f02));
    try std.testing.expectEqual(@as(u32, 0x0000_0111), s.r[4]);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef54f22));
    try std.testing.expectEqual(@as(u32, 0x0002_fb5f), s.r[4]);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea94f02));
    try std.testing.expectEqual([_]u32{ 0x11b2_d779, 0 }, s.r[4..6].*);
}

test "the extremes start from the register they answer in, read as one element, C2.4.373 C2.4.378" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee64f82));
    try std.testing.expectEqual(@as(u32, 0xffff_8000), s.r[4]);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfee24f02));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.r[4]);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeee84f82));
    try std.testing.expectEqual(@as(u32, 0x0000_1234), s.r[4]);
    s.r[4] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee924f05));
    try std.testing.expectEqual(@as(u32, 0x0003_ac61), s.r[4]);
}

test "VMAXA meets each element of the destination with the distance of the source from zero, C2.4.369" {
    var s = reset();
    var m = machine();
    sample(&s);
    s.fp[0..4].* = s.fp[8..12].*;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee330e83));
    try std.testing.expectEqual([_]u32{ 0x7f80_7f01, 0x80ff_8001, 0x0102_fffe, 0x8765_5678 }, s.fp[0..4].*);
}

test "the dual accumulating reductions take the elements in pairs, C2.4.381 C2.4.387 C2.4.382" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef24e04));
    try std.testing.expectEqual(@as(u32, 0x8f58_68f4), s.r[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeef25e04));
    try std.testing.expectEqual(@as(u32, 0x9b4a_d995), s.r[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfef24e05));
    try std.testing.expectEqual(@as(u32, 0x0000_d3f6), s.r[4]);
    s.r[4] = 0x1234;
    s.r[5] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea34e24));
    try std.testing.expectEqual([_]u32{ 0x30c2_20a8, 0xb82c_75c9 }, s.r[4..6].*);
}

test "the rounding reduction keeps eight bits more than the pair, one beat at a time, C2.4.463" {
    var s = reset();
    var m = machine();
    sample(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeea24f04));
    try std.testing.expectEqual([_]u32{ 0xc930_c20e, 0xffb8_2c75 }, s.r[4..6].*);
}

test "a gather reads one address per element out of a vector, C2.4.366" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[1] = 0;
    for ([_]u32{ 0x0604_0200, 0x0e0c_0a08, 0x1614_1210, 0x1e1c_1a18 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc910e04));
    try std.testing.expectEqual([_]u32{ 0x7355_7254, 0x7557_7456, 0x7759_7658, 0x795b_785a }, s.fp[0..4].*);
    for ([_]u32{ 0x0009_0003, 0x0015_000f, 0x0021_001b, 0x002d_0027 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec910e84));
    try std.testing.expectEqual([_]u32{ 0x0065_ff81, 0x0068_ff84, 0x006b_ff87, 0x006e_ff8a }, s.fp[0..4].*);
    for ([_]u32{ 5, 13, 29, 45 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec910f04));
    try std.testing.expectEqual([_]u32{ 0x64, 0x66, 0x6a, 0x6e }, s.fp[0..4].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc910f15));
    try std.testing.expectEqual([_]u32{ 0x8374, 0x8778, 0x8f80, 0 }, s.fp[0..4].*);
    for ([_]u32{ 4, 12, 28, 44 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc910f44));
    try std.testing.expectEqual([_]u32{ 0x8273_6455, 0x8475_6657, 0x8879_6a5b, 0x8c7d_6e5f }, s.fp[0..4].*);
}

test "a gather of doublewords reads one address for every pair of words, C2.4.366" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[1] = 0;
    for ([_]u32{ 8, 0, 24, 0 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc910fd4));
    try std.testing.expectEqual([_]u32{ 0x8374_6556, 0x8475_6657, 0x8778_695a, 0x8879_6a5b }, s.fp[0..4].*);
}

test "a masked element of a gather is left at zero rather than left alone, C2.4.366" {
    var s = predicated(0x0088_000f);
    var m = machine();
    filled(&m);
    s.r[1] = 0;
    s.fp[0..4].* = @splat(0xdead_beef);
    for ([_]u32{ 4, 12, 28, 44 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc910f44));
    try std.testing.expectEqual([_]u32{ 0x8273_6455, 0, 0, 0 }, s.fp[0..4].*);
}

test "a scatter writes one address per element, and the vector base may keep what it worked out, C2.4.486 C2.4.366" {
    var s = reset();
    var m = machine();
    s.r[1] = 0;
    for ([_]u32{ 0, 4, 8, 12 }, 8..) |v, i| s.fp[i] = v;
    for ([_]u32{ 0x1111_1111, 0x2222_2222, 0x3333_3333, 0x4444_4444 }, 0..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xec810f44));
    try std.testing.expectEqual(@as(u32, 0x1111_1111), m.peek(u32, 0).?);
    try std.testing.expectEqual(@as(u32, 0x4444_4444), m.peek(u32, 12).?);
    filled(&m);
    for ([_]u32{ 0, 4, 8, 12 }, 8..) |v, i| s.fp[i] = v;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfdb41e02));
    try std.testing.expectEqual([_]u32{ 0x8374_6556, 0x8475_6657, 0x8576_6758, 0x8677_6859 }, s.fp[0..4].*);
    try std.testing.expectEqual([_]u32{ 8, 12, 16, 20 }, s.fp[8..12].*);
}

test "the counting duplications leave the count where the next one carries on from, C2.4.358 C2.4.344" {
    var s = reset();
    var m = machine();
    s.r[2] = 16;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee030f6f));
    try std.testing.expectEqual([_]u32{ 0x1614_1210, 0x1e1c_1a18, 0x2624_2220, 0x2e2c_2a28 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x30), s.r[2]);
    s.r[2] = 4;
    s.r[5] = 12;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee130fe4));
    try std.testing.expectEqual([_]u32{ 0x0008_0004, 0x0004_0000, 0x0000_0008, 0x0008_0004 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
}

test "the interleaving loads take one field per register out of a run of memory, C2.4.360 C2.4.361" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc911e00));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc911e20));
    try std.testing.expectEqual([_]u32{ 0x7355_7254, 0x7557_7456, 0x7759_7658, 0x795b_785a }, s.fp[0..4].*);
    try std.testing.expectEqual([_]u32{ 0x8264_8163, 0x8466_8365, 0x8668_8567, 0x886a_8769 }, s.fp[4..8].*);
    for ([_]u32{ 0xfc911f01, 0xfc911f21, 0xfc911f41, 0xfc911f61 }) |code| try std.testing.expectEqual(.next, exec(&s, &m, code));
    try std.testing.expectEqual([_]u32{ 0x8172_6354, 0x8576_6758, 0x897a_6b5c, 0x8d7e_6f60 }, s.fp[0..4].*);
    try std.testing.expectEqual([_]u32{ 0x8475_6657, 0x8879_6a5b, 0x8c7d_6e5f, 0x9081_7263 }, s.fp[12..16].*);
}

test "the interleaving stores put the fields back and write the base on the last quarter, C2.4.480" {
    var s = reset();
    var m = machine();
    filled(&m);
    s.r[1] = 0;
    for ([_]u32{ 0xfc911f01, 0xfc911f21, 0xfc911f41, 0xfc911f61 }) |code| try std.testing.expectEqual(.next, exec(&s, &m, code));
    m.bytes = @splat(0);
    for ([_]u32{ 0xfc811f01, 0xfc811f21, 0xfc811f41, 0xfca11f61 }) |code| try std.testing.expectEqual(.next, exec(&s, &m, code));
    for (0..16) |i| try std.testing.expectEqual(@as(u32, 0x8172_6354) +% @as(u32, @intCast(i)) *% 0x0101_0101, m.peek(u32, @intCast(4 * i)).?);
    try std.testing.expectEqual(@as(u32, 64), s.r[1]);
}

fn sources(s: *State) void {
    s.fp[0..4].* = .{ 0x1234_5678, 0xfedc_ba98, 0x8000_0000, 0x7fff_ffff };
    s.fp[4..8].* = .{ 0x0123_4567, 0x89ab_cdef, 0x8000_8000, 0x7fff_8000 };
    s.fp[8..12].* = .{ 0x03fe_0107, 0xf802_0e81, 0x8000_7fff, 0xff05_fb1f };
}

test "the multiplies that keep the high half cut after the doubling and the rounding, C2.4.411 C2.4.457" {
    var s = reset();
    var m = machine();
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee030e05));
    try std.testing.expectEqual([_]u32{ 0x00ff_0002, 0x03ff_fd08, 0x4000_c000, 0xffff_0200 }, s.fp[0..4].*);
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe131e05));
    try std.testing.expectEqual([_]u32{ 0x0005_0047, 0x855f_0bab, 0x4000_4000, 0x7f82_7d90 }, s.fp[0..4].*);
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef220b44));
    try std.testing.expectEqual([_]u32{ 0x0009_15a0, 0x0763_5c67, 0x7fff_0001, 0xff05_fc19 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "a widening multiply reads every second element and answers in twice the width, C2.4.412 C2.4.413" {
    var s = reset();
    var m = machine();
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee230e04));
    try std.testing.expectEqual([_]u32{ 0x3c6e_4cd1, 0x0004_8ad0, 0xbfff_8000, 0x3fff_8000 }, s.fp[0..4].*);
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee231e04));
    try std.testing.expectEqual([_]u32{ 0xe8b3_d76f, 0x03b1_ae33, 0x8270_8000, 0xff82_fe0c }, s.fp[0..4].*);
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee330e04));
    try std.testing.expectEqual([_]u32{ 0x1ec2_0135, 0x0156_776f, 0x0000_0000, 0x0303_0000 }, s.fp[0..4].*);
    sources(&s);
    s.r[5] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe321f65));
    try std.testing.expectEqual([_]u32{ 0x0000_0000, 0x7654_3211, 0x0000_0000, 0x8000_8000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "a widening multiply records saturation only for the lanes the predicate leaves on, C2.4.440" {
    var s = predicated(0x0088_00f0);
    var m = machine();
    s.fp[4..8].* = .{ 0, 0, 0x8000_0000, 0 };
    s.r[1] = 0x8000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee32_1f61));
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
    s.vpr = 0x0088_0f00;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee32_1f61));
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "the exchanging dual multiply answers in the upper element of each pair and leaves the other, C2.4.435" {
    var s = reset();
    var m = machine();
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee121e04));
    try std.testing.expectEqual([_]u32{ 0x022c_5678, 0xf5b7_ba98, 0x0001_0000, 0xfc1a_ffff }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.qc);
}

test "the doubling accumulates differ in which operand the register stands for, C2.4.436 C2.4.437" {
    var s = reset();
    var m = machine();
    sources(&s);
    s.r[5] = 0x8000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee021e65));
    try std.testing.expectEqual([_]u32{ 0x000e_2e60, 0x0117_1b0d, 0x7f00_0000, 0x7e00_0100 }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
    s.fpscr = fp.ltpsize;
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee120e45));
    try std.testing.expectEqual([_]u32{ 0x1111_1111, 0x7531_eca9, 0x0000_7fff, 0x0000_7fff }, s.fp[0..4].*);
    try std.testing.expectEqual(fp.qc, s.fpscr & fp.qc);
}

test "the complex add crosses each pair and takes one of them away, C2.4.312 C2.4.325" {
    var s = reset();
    var m = machine();
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe221f04));
    try std.testing.expectEqual([_]u32{ 0xf925_53e8, 0x85ad_cce8, 0x7f06_7b1f, 0xffff_0001 }, s.fp[0..4].*);
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee020f04));
    try std.testing.expectEqual([_]u32{ 0xff10_2633, 0xc5d9_a7f0, 0xc040_bfc0, 0x4200_cf02 }, s.fp[0..4].*);
}

test "the carrying add and subtract run one carry through all four words, C2.4.301 C2.4.469" {
    var s = reset();
    var m = machine();
    sources(&s);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe321f04));
    try std.testing.expectEqual([_]u32{ 0xfd25_4460, 0x91a9_bf6d, 0x0000_0000, 0x80f9_84e1 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & fp.nzcv);
    sources(&s);
    s.fpscr = fp.ltpsize | 1 << 29;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee320f04));
    try std.testing.expectEqual([_]u32{ 0x0521_466f, 0x81ad_dc70, 0x0001_0000, 0x7f05_7b20 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 1 << 29), s.fpscr & fp.nzcv);
}

fn floats(s: *State, m: *Machine, source: *const [4]u32) void {
    _ = exec(s, m, 0xffb9_07c2);
    s.fpscr = fp.ltpsize;
    s.fp[0..4].* = .{ 0x3fc0_0000, 0xbf80_0000, 0x0080_0000, 0x7fc0_0000 };
    s.fp[4..8].* = source.*;
    s.fp[8..12].* = .{ 0x4000_0000, 0x3f00_0000, 0x7f7f_ffff, 0x8000_0000 };
}

const ordinary = [4]u32{ 0x3f80_0000, 0xc049_0fdb, 0x7f7f_ffff, 0x0000_0001 };
const strange = [4]u32{ 0x7f80_0000, 0xff80_0000, 0x7fa0_0000, 0x0000_ffff };

test "the vector arithmetic is the scalar arithmetic run once per element, C2.4.303 C2.4.409 C2.4.297" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef02_0d44));
    try std.testing.expectEqual([_]u32{ 0x4040_0000, 0xc029_0fdb, 0x7f80_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x94), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff02_0d54));
    try std.testing.expectEqual([_]u32{ 0x4000_0000, 0xbfc9_0fdb, 0x7f80_0000, 0x8000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x94), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff22_0d44));
    try std.testing.expectEqual([_]u32{ 0x3f80_0000, 0x4069_0fdb, 0x0000_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
}

test "the multiply-accumulates are fused and name which operand the scalar stands for, C2.4.350 C2.4.351" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef02_0c54));
    try std.testing.expectEqual([_]u32{ 0x4060_0000, 0xc024_87ee, 0x7f80_0000, 0x7fc0_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x94), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    s.r[4] = 0x4049_0fdb;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee33_1e44));
    try std.testing.expectEqual([_]u32{ 0x4094_87ee, 0x40c9_0fdb, 0x40e4_87ed, 0x7fc0_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x90), s.fpscr & 0x9f);
}

test "a signalling NaN answers with the default one because the vector modes are the standard ones, C2.4.303" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &strange);
    s.fp[8..12].* = ordinary;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef02_0d44));
    try std.testing.expectEqual([_]u32{ 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x81), s.fpscr & 0x9f);
}

test "the vector modes are the standard ones whatever FPSCR holds, and FPSCR keeps what it held, E2.1.395" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    s.fpscr = fp.ltpsize | 0x00c0_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xef02_0d44));
    try std.testing.expectEqual([_]u32{ 0x4040_0000, 0xc029_0fdb, 0x7f80_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x00c0_0000), s.fpscr & 0x03c0_0000);
    try std.testing.expectEqual(@as(u32, 0x94), s.fpscr & 0x9f);
}

test "negating and taking the absolute value are the sign bit alone, C2.4.417 C2.4.299" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb9_07c2));
    try std.testing.expectEqual([_]u32{ 0xbf80_0000, 0x4049_0fdb, 0xff7f_ffff, 0x8000_0001 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    floats(&s, &m, &strange);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffb5_0742));
    try std.testing.expectEqual([_]u32{ 0x7f80_0000, 0x7f80_0000, 0x7fa0_0000, 0x0000_7fff }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "an unordered pair passes the two comparisons written as negations and fails the other four, C2.4.318" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    s.vpr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee33_1f84));
    try std.testing.expectEqual(@as(u32, 0x00ff), s.vpr);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
    floats(&s, &m, &strange);
    s.fp[8..12].* = ordinary;
    s.vpr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee33_1f84));
    try std.testing.expectEqual(@as(u32, 0x0ff0), s.vpr);
    try std.testing.expectEqual(@as(u32, 0x81), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    s.r[5] = 0x4049_0fdb;
    s.vpr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee33_0f45));
    try std.testing.expectEqual(@as(u32, 0), s.vpr);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
}

test "the extremes answer with the number rather than the larger pattern, C2.4.371 C2.4.376" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xff02_0f54));
    try std.testing.expectEqual([_]u32{ 0x4000_0000, 0x3f00_0000, 0x7f7f_ffff, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee3f_0e83));
    try std.testing.expectEqual([_]u32{ 0x3fc0_0000, 0x4049_0fdb, 0x7f7f_ffff, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
}

test "a reduction turns every NaN into the default one before comparing, so one lane cannot carry, C2.4.372" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &strange);
    s.r[5] = 0xbf80_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeee_5f02));
    try std.testing.expectEqual(@as(u32, 0x7f80_0000), s.r[5]);
    try std.testing.expectEqual(@as(u32, 0x81), s.fpscr & 0x9f);
    floats(&s, &m, &strange);
    s.r[5] = 0xbf80_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeeec_5f82));
    try std.testing.expectEqual(@as(u32, 0xbf80_0000), s.r[5]);
    try std.testing.expectEqual(@as(u32, 0x81), s.fpscr & 0x9f);
}

const ties = [4]u32{ 0x3fc0_0000, 0x4020_0000, 0xbfc0_0000, 0xc020_0000 };
const counted = [4]u32{ 0x0000_0001, 0xffff_ffff, 0x7fff_ffff, 0x8000_0000 };

test "each rounding mode names itself rather than reading FPSCR, C2.4.328 C2.4.331" {
    var s = reset();
    var m = machine();
    for ([_]u32{ 0xffbb_0742, 0xffbb_0142, 0xffbb_0042, 0xffbb_0242 }, [_][4]u32{
        .{ 0x0000_0001, 0x0000_0002, 0xffff_ffff, 0xffff_fffe },
        .{ 0x0000_0002, 0x0000_0002, 0xffff_fffe, 0xffff_fffe },
        .{ 0x0000_0002, 0x0000_0003, 0xffff_fffe, 0xffff_fffd },
        .{ 0x0000_0002, 0x0000_0003, 0xffff_ffff, 0xffff_fffe },
    }) |code, want| {
        floats(&s, &m, &ties);
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(want, s.fp[0..4].*);
        try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
    }
}

test "a fixed-point conversion counts its fraction bits down from the element width, C2.4.325" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ties);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xefbf_0f52));
    try std.testing.expectEqual([_]u32{ 0x0000_0003, 0x0000_0005, 0xffff_fffd, 0xffff_fffb }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    floats(&s, &m, &counted);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xffbb_0642));
    try std.testing.expectEqual([_]u32{ 0x3f80_0000, 0xbf80_0000, 0x4f00_0000, 0xcf00_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x10), s.fpscr & 0x9f);
}

test "rounding to an integral number says it was inexact only where the name asks, C2.4.455" {
    var s = reset();
    var m = machine();
    for ([_]u32{ 0xffba_0442, 0xffba_04c2, 0xffba_05c2 }, [_][4]u32{
        .{ 0x4000_0000, 0x4000_0000, 0xc000_0000, 0xc000_0000 },
        .{ 0x4000_0000, 0x4000_0000, 0xc000_0000, 0xc000_0000 },
        .{ 0x3f80_0000, 0x4000_0000, 0xbf80_0000, 0xc000_0000 },
    }, [_]u32{ 0, 0x10, 0 }) |code, want, flags| {
        floats(&s, &m, &ties);
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(want, s.fp[0..4].*);
        try std.testing.expectEqual(flags, s.fpscr & 0x9f);
    }
}

test "the half against single conversions keep the half they are not asked for, C2.4.327" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ties);
    s.fp[0..4].* = .{ 0x1111_2222, 0x3333_4444, 0x5555_6666, 0x7777_8888 };
    try std.testing.expectEqual(.next, exec(&s, &m, 0xee3f_0e03));
    try std.testing.expectEqual([_]u32{ 0x1111_3e00, 0x3333_4100, 0x5555_be00, 0x7777_c100 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
    floats(&s, &m, &ties);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe3f_1e03));
    try std.testing.expectEqual([_]u32{ 0x3ff8_0000, 0x4004_0000, 0xbff8_0000, 0xc004_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0), s.fpscr & 0x9f);
}

test "the complex multiply takes one term per element and the rotation says which, C2.4.321 C2.4.316" {
    var s = reset();
    var m = machine();
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe32_0e04));
    try std.testing.expectEqual([_]u32{ 0x4000_0000, 0x3f00_0000, 0x7f80_0000, 0x8000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x14), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfe32_0e05));
    try std.testing.expectEqual([_]u32{ 0x3fc9_0fdb, 0xc0c9_0fdb, 0x0000_0000, 0x0000_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc32_0844));
    try std.testing.expectEqual([_]u32{ 0x4060_0000, 0xbf00_0000, 0x7f80_0000, 0x7fc0_0000 }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x14), s.fpscr & 0x9f);
    floats(&s, &m, &ordinary);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfc92_0844));
    try std.testing.expectEqual([_]u32{ 0x3f00_0000, 0xbf92_1fb6, 0x7f7f_ffff, 0x7f7f_ffff }, s.fp[0..4].*);
    try std.testing.expectEqual(@as(u32, 0x80), s.fpscr & 0x9f);
}
