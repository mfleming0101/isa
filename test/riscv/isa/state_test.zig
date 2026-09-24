//! Tests of `State`: x0 reads zero however it is written and every other register keeps its value,
//! section 2.1.
const std = @import("std");
const State = @import("../../../src/riscv/isa/state.zig").State;

test "x0 reads as zero however often it is written, section 2.1" {
    var s: State = .{};
    s.set(0, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0), s.get(0));
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);
}

test "every other register keeps what it is given, section 2.1" {
    var s: State = .{};
    s.set(1, 0xdead_beef);
    s.set(31, 7);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.get(1));
    try std.testing.expectEqual(@as(u32, 7), s.get(31));
    try std.testing.expectEqual(@as(u32, 0), s.get(30));
}
