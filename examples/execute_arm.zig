const std = @import("std");
const isa = @import("isa");

test "movs r0, #1 on an Armv7-M reference host" {
    const decode = isa.generated.arm_decode;

    var ram = [_]u8{0} ** 64;
    var host: @import("host").arm.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.arm.State = .{};
    const done = decode.executeNarrow(@TypeOf(host), &s, &host, 0x2001, isa.arm.decode.selectionOf(.armv7m).groups);

    try std.testing.expectEqual(.next, done.outcome);
    try std.testing.expectEqual(1, s.r[0]);
}
