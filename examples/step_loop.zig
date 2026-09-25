const std = @import("std");
const isa = @import("isa");

test "the Arm step loop fetches, decodes, executes and charges one instruction" {
    const step = isa.arm.step;
    var ram = [_]u8{ 0x01, 0x20, 0x00, 0xbe } ++ [_]u8{0} ** 60; // movs r0, #1; bkpt #0
    var host: @import("host").arm.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.arm.State = .{};
    const costs: step.Model.Costs = @splat(.{ .cycles = 1, .taken = 2 });
    const model: step.Model = .{ .decoding = isa.arm.decode.selectionOf(.armv7m), .costs = costs };

    const first = step.step(@TypeOf(host), null, &s, &host, model);
    try std.testing.expectEqual(null, first.halt());
    try std.testing.expectEqual(.data_processing, first.class);
    try std.testing.expectEqual(1, first.cycles);
    try std.testing.expectEqual(2, s.pc);
    try std.testing.expectEqual(1, s.r[0]);

    const second = step.step(@TypeOf(host), null, &s, &host, model);
    try std.testing.expectEqual(.breakpoint, second.halt());
}

test "the RISC-V step loop does the same with a groups word" {
    const step = isa.riscv.step;
    var ram = [_]u8{ 0x13, 0x05, 0x10, 0x00, 0x73, 0x00, 0x10, 0x00 } ++ [_]u8{0} ** 56; // addi a0, zero, 1; ebreak
    var host: @import("host").riscv.Host = .{ .memory = .{ .bytes = &ram, .base = 0 } };
    var s: isa.riscv.State = .{};
    const costs: step.Model.Costs = @splat(.{ .cycles = 1, .taken = 2 });
    const model: step.Model = .{ .decoding = comptime isa.riscv.decode.only(&.{ .rv32i, .m, .c, .zicsr }), .costs = costs };

    const first = step.step(@TypeOf(host), null, &s, &host, model);
    try std.testing.expectEqual(null, first.halt());
    try std.testing.expectEqual(4, s.pc);
    try std.testing.expectEqual(1, s.x[10]);

    const second = step.step(@TypeOf(host), null, &s, &host, model);
    try std.testing.expectEqual(.breakpoint, second.halt());
}
