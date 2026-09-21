//! Tests of the core state helpers: stack pointer selection through CONTROL.SPSEL,
//! branchTo splitting the T bit from the address, the flag setters, and the alignment
//! a stack pointer write enforces.
const std = @import("std");
const State = @import("state.zig").State;

test "the stack pointer is MSP or PSP as CONTROL.SPSEL selects, B1.4.1" {
    var s: State = .{ .msp = 0x2000_1000, .psp = 0x2000_2000 };
    try std.testing.expectEqual(@as(u32, 0x2000_1000), s.sp());
    s.control = State.control_spsel;
    try std.testing.expectEqual(@as(u32, 0x2000_2000), s.sp());
}

test "branchTo takes the T bit from bit 0 of the address and the program counter from the rest, A2.3.1" {
    var s: State = .{ .xpsr = State.flag_c };
    s.branchTo(0x11);
    try std.testing.expectEqual(@as(u32, 0x10), s.pc);
    try std.testing.expectEqual(State.flag_c | State.flag_t, s.xpsr);
    s.branchTo(0x20);
    try std.testing.expectEqual(@as(u32, 0x20), s.pc);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
}

test "setNZ writes N and Z from the result and leaves C and V" {
    var s: State = .{ .xpsr = State.flag_c | State.flag_v | State.flag_t };
    s.setNZ(0);
    try std.testing.expectEqual(State.flag_z | State.flag_c | State.flag_v | State.flag_t, s.xpsr);
    s.setNZ(0x8000_0000);
    try std.testing.expectEqual(State.flag_n | State.flag_c | State.flag_v | State.flag_t, s.xpsr);
}

test "setNZCV writes the four flags" {
    var s: State = .{ .xpsr = State.flag_t };
    s.setNZCV(0, true, true);
    try std.testing.expectEqual(State.flag_z | State.flag_c | State.flag_v | State.flag_t, s.xpsr);
    s.setNZCV(0x8000_0000, false, false);
    try std.testing.expectEqual(State.flag_n | State.flag_t, s.xpsr);
}

test "a write to sp through either stack pointer drops bits 1 and 0, which read as zero, B1.4.1" {
    var s: State = .{};
    s.setSp(0x2000_2007);
    try std.testing.expectEqual(@as(u32, 0x2000_2004), s.msp);
    try std.testing.expectEqual(@as(u32, 0x2000_2004), s.sp());
    s.control = State.control_spsel;
    s.set(13, 0x2000_1ffe);
    try std.testing.expectEqual(@as(u32, 0x2000_1ffc), s.psp);
    try std.testing.expectEqual(@as(u32, 0x2000_2004), s.msp);
}
