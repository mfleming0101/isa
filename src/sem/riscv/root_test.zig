//! Tests of the handler table through the generated decode tree over the host: a handful of
//! RV32I and RV32C rows executed end to end, and that a code a row's constraint rejects is claimed
//! by that row or undefined.
const std = @import("std");
const decode = @import("riscv_decode");
const sem = @import("root.zig");

const Host = @import("../../host/riscv.zig").Host;
const allowed = @import("../../riscv/isa/decode.zig").every;

fn run(s: *sem.State, memory: []u8, code: u32) sem.Outcome {
    var host: Host = .{ .memory = .{ .bytes = memory, .base = 0 } };
    const done = if (code & 3 == 3) decode.executeWide(Host, s, &host, code, allowed) else decode.executeNarrow(Host, s, &host, code, allowed);
    return done.outcome;
}

test "lui places its twenty-bit immediate above bit eleven" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x0020_0137));
    try std.testing.expectEqual(@as(u32, 0x0020_0000), s.x[2]);

    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xffff_f0b7));
    try std.testing.expectEqual(@as(u32, 0xffff_f000), s.x[1]);

    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xffff_f037));
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);
}

test "c.add adds rs2 into rd" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    s.x[10] = 7;
    s.x[11] = 5;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x95aa));
    try std.testing.expectEqual(@as(u32, 12), s.x[11]);

    s.x[31] = 0x8000_0000;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x9ffe));
    try std.testing.expectEqual(@as(u32, 0), s.x[31]);
}

test "c.swsp stores rs2 at the scaled offset from sp" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    s.x[2] = 8;
    s.x[11] = 0xdead_beef;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xc22e));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), std.mem.readInt(u32, memory[12..16], .little));

    s.x[2] = 0;
    s.x[31] = 0x1234_5678;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xdffe));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, memory[252..256], .little));

    s.x[2] = 0xffff_fff0;
    try std.testing.expectEqual(sem.Outcome.data_fault, run(&s, &memory, 0xc006));
}

test "c.lwsp loads rd from the scaled offset from sp" {
    var memory: [320]u8 = @splat(0);
    std.mem.writeInt(u32, memory[12..16], 0x0bad_f00d, .little);
    std.mem.writeInt(u32, memory[252..256], 0x1234_5678, .little);
    var s: sem.State = .{};

    s.x[2] = 8;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x4612));
    try std.testing.expectEqual(@as(u32, 0x0bad_f00d), s.x[12]);

    s.x[2] = 0;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x5ffe));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), s.x[31]);

    s.x[2] = 0xffff_fff0;
    try std.testing.expectEqual(sem.Outcome.data_fault, run(&s, &memory, 0x4082));
}

test "c.bnez branches on a non-zero primed register" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    s.pc = 0x100;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xfd65));
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);

    s.x[10] = 1;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xfd65));
    try std.testing.expectEqual(@as(u32, 0xf8), s.pc);

    s.pc = 0x100;
    s.x[8] = 1;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xec7d));
    try std.testing.expectEqual(@as(u32, 0x1fe), s.pc);

    s.pc = 0x100;
    s.x[15] = 1;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xf381));
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "c.mv copies rs2 into rd and discards a write to x0" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    s.x[11] = 0xdead_beef;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x852e));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.x[10]);

    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x802e));
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);
}

test "c.jr and c.jalr jump to rs1 with bit zero cleared, and c.jalr links the next parcel" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    s.pc = 0x100;
    s.x[1] = 0x241;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0x8082));
    try std.testing.expectEqual(@as(u32, 0x240), s.pc);
    try std.testing.expectEqual(@as(u32, 0x241), s.x[1]);

    s.pc = 0x100;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0x9082));
    try std.testing.expectEqual(@as(u32, 0x240), s.pc);
    try std.testing.expectEqual(@as(u32, 0x102), s.x[1]);

    s.pc = 0x100;
    s.x[10] = 0x330;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0x8502));
    try std.testing.expectEqual(@as(u32, 0x330), s.pc);

    s.pc = 0x100;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0x9502));
    try std.testing.expectEqual(@as(u32, 0x330), s.pc);
    try std.testing.expectEqual(@as(u32, 0x102), s.x[1]);
}

test "a code its row's spec constraint rejects is the row that claims it, or undefined" {
    var memory: [320]u8 = @splat(0);
    var s: sem.State = .{};

    try std.testing.expectEqual(sem.Outcome.breakpoint, run(&s, &memory, 0x9002));
    try std.testing.expectEqual(sem.Outcome.illegal, run(&s, &memory, 0x8002));
    try std.testing.expectEqual(sem.Outcome.illegal, run(&s, &memory, 0x4002));
}
