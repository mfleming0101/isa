const std = @import("std");
const isa = @import("isa");

test "udiv is Armv7-M; a Cortex-M0 has no divider" {
    const decode = isa.generated.arm_decode;
    const udiv_r0_r1_r2: u32 = 0xfbb1_f0f2;
    const m0 = comptime isa.arm.decode.only(&.{.v6m});
    const m4 = comptime isa.arm.decode.only(&.{ .v6m, .v7m, .main, .dsp });

    var ram = [_]u8{0} ** 64;
    var host: @import("host").arm.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.arm.State = .{};
    s.r[1] = 6;
    s.r[2] = 3;

    try std.testing.expectEqual(.undefined, decode.executeWide(@TypeOf(host), &s, &host, udiv_r0_r1_r2, m0).outcome);
    try std.testing.expectEqual(.next, decode.executeWide(@TypeOf(host), &s, &host, udiv_r0_r1_r2, m4).outcome);
    try std.testing.expectEqual(2, s.r[0]);
}

test "mul is the M extension" {
    const decode = isa.generated.riscv_decode;
    const mul_a0_a1_a2: u32 = 0x02c5_8533;
    const rv32i = comptime isa.riscv.decode.only(&.{.rv32i});
    const rv32im = comptime isa.riscv.decode.only(&.{ .rv32i, .m });

    var ram = [_]u8{0} ** 64;
    var host: @import("host").riscv.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.riscv.State = .{};
    s.x[11] = 6;
    s.x[12] = 7;

    try std.testing.expectEqual(.illegal, decode.executeWide(@TypeOf(host), &s, &host, mul_a0_a1_a2, rv32i).outcome);
    try std.testing.expectEqual(.next, decode.executeWide(@TypeOf(host), &s, &host, mul_a0_a1_a2, rv32im).outcome);
    try std.testing.expectEqual(42, s.x[10]);
}
