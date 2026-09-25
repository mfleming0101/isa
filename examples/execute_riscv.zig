const std = @import("std");
const isa = @import("isa");

test "addi a0, zero, 1 on an RV32 reference host" {
    const decode = isa.generated.riscv_decode;

    var ram = [_]u8{0} ** 64;
    var host: @import("host").riscv.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.riscv.State = .{};
    const done = decode.executeWide(@TypeOf(host), &s, &host, 0x00100513, isa.riscv.decode.every);

    try std.testing.expectEqual(.next, done.outcome);
    try std.testing.expectEqual(1, s.x[10]);
}
