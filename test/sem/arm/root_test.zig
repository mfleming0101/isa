//! Behavioural tests of the Arm semantics driven through the generated Armv7-M decoder with a host
//! host over a small memory: the exclusive monitor across a load and store pair, CMP flag setting,
//! and the conditional branch offset. Covers what the per-row differential cannot see. Imported by
//! src/tests.zig.
const std = @import("std");
const decode = @import("arm_decode");
const sem = @import("../../../src/sem/arm/root.zig");

const Host = @import("../../../src/host/arm.zig").Host;
const groups: u32 = 0b111;

fn decodeWide(s: *sem.State, host: *Host, code: u32) sem.Outcome {
    return decode.executeWide(Host, s, host, code, groups).outcome;
}

fn run(s: *sem.State, memory: []u8, code: u32) sem.Outcome {
    var host: Host = .{ .memory = .{ .bytes = memory, .base = 0 } };
    return if (code > 0xffff) decode.executeWide(Host, s, &host, code, groups).outcome else decode.executeNarrow(Host, s, &host, code, groups).outcome;
}

test "a store exclusive passes only where the load exclusive that tagged the monitor still holds" {
    var memory: [64]u8 = @splat(0);
    var host: Host = .{ .memory = .{ .bytes = &memory, .base = 0 } };
    var s: sem.State = .{};
    s.r[1] = 16;
    s.r[2] = 0xa5a5_a5a5;

    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xe8412000));
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[16..20], .little));

    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xe8513f00));
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xe8412000));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0xa5a5_a5a5), std.mem.readInt(u32, memory[16..20], .little));

    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xe8513f00));
    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xf3bf8f2f));
    s.r[2] = 0x1234_5678;
    try std.testing.expectEqual(sem.Outcome.next, decodeWide(&s, &host, 0xe8412000));
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0xa5a5_a5a5), std.mem.readInt(u32, memory[16..20], .little));
}

test "cmp sets the four flags from a subtraction it does not write back" {
    var memory: [64]u8 = @splat(0);
    var s: sem.State = .{ .xpsr = 0 };

    s.r[2] = 5;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x2a05));
    try std.testing.expectEqual(@as(u32, 0x6000_0000), s.xpsr);
    try std.testing.expectEqual(@as(u32, 5), s.r[2]);

    s.r[2] = 7;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x2a05));
    try std.testing.expectEqual(@as(u32, 0x2000_0000), s.xpsr);

    s.r[2] = 3;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x2a05));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.xpsr);

    s.r[0] = 0x8000_0000;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0x2801));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), s.xpsr);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
}

test "bne branches on a clear Z to a halfword offset from two instructions on" {
    var memory: [64]u8 = @splat(0);
    var s: sem.State = .{};

    s.pc = 0x100;
    s.xpsr = sem.flag_z;
    try std.testing.expectEqual(sem.Outcome.next, run(&s, &memory, 0xd103));
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);

    s.xpsr = 0;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xd103));
    try std.testing.expectEqual(@as(u32, 0x10a), s.pc);

    s.pc = 0x100;
    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xd1fe));
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);

    try std.testing.expectEqual(sem.Outcome.branched, run(&s, &memory, 0xd180));
    try std.testing.expectEqual(@as(u32, 4), s.pc);
}
