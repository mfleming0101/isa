//! Behavioural tests of the Arm semantics driven through the generated Armv7-M decoder with a host
//! host over a small memory: the exclusive monitor across a load and store pair, CMP flag setting,
//! and the conditional branch offset. Covers what the per-row differential cannot see. Imported by
//! src/tests.zig.
const std = @import("std");
const decode = @import("arm_decode");
const sem = @import("../../../src/sem/arm/root.zig");

const Host = @import("../../../host/arm.zig").Host;
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

const Coded = struct { text: []const u8, code: u32 };

fn expectClass(class: sem.Class, cases: []const Coded) !void {
    const every = @import("../../../src/arm/isa/decode.zig").every;
    for (cases) |c| {
        var buffer: [64]u8 = undefined;
        var text = std.Io.Writer.fixed(&buffer);
        try @import("arm_disasm").write(&text, c.code, 0, every);
        try std.testing.expectEqualStrings(c.text, text.buffered());
        var memory: [16]u8 = @splat(0);
        var host: Host = .{ .memory = .{ .bytes = &memory, .base = 0 } };
        var s: sem.State = .{};
        const done = if (c.code > 0xffff) decode.executeWide(Host, &s, &host, c.code, every) else decode.executeNarrow(Host, &s, &host, c.code, every);
        try std.testing.expectEqual(class, done.class);
    }
}

test "every multiply row and multiply alias answers the multiply class" {
    try expectClass(.multiply, &.{
        .{ .text = "muls r3, r5, r3", .code = 0x436b },
        .{ .text = "mla r0, r1, r2, r3", .code = 0xfb01_3002 },
        .{ .text = "mul.w r0, r1, r2", .code = 0xfb01_f002 },
        .{ .text = "mls r0, r1, r2, r3", .code = 0xfb01_3012 },
        .{ .text = "smull r0, r1, r2, r3", .code = 0xfb82_0103 },
        .{ .text = "umull r0, r1, r2, r3", .code = 0xfba2_0103 },
        .{ .text = "smlal r0, r1, r2, r3", .code = 0xfbc2_0103 },
        .{ .text = "umlal r0, r1, r2, r3", .code = 0xfbe2_0103 },
        .{ .text = "smlabb r0, r1, r2, r3", .code = 0xfb11_3002 },
        .{ .text = "smulbb r0, r1, r2", .code = 0xfb11_f002 },
        .{ .text = "smlabt r0, r1, r2, r3", .code = 0xfb11_3012 },
        .{ .text = "smulbt r0, r1, r2", .code = 0xfb11_f012 },
        .{ .text = "smlatb r0, r1, r2, r3", .code = 0xfb11_3022 },
        .{ .text = "smultb r0, r1, r2", .code = 0xfb11_f022 },
        .{ .text = "smlatt r0, r1, r2, r3", .code = 0xfb11_3032 },
        .{ .text = "smultt r0, r1, r2", .code = 0xfb11_f032 },
        .{ .text = "smlawb r0, r1, r2, r3", .code = 0xfb31_3002 },
        .{ .text = "smulwb r0, r1, r2", .code = 0xfb31_f002 },
        .{ .text = "smlawt r0, r1, r2, r3", .code = 0xfb31_3012 },
        .{ .text = "smulwt r0, r1, r2", .code = 0xfb31_f012 },
        .{ .text = "smlad r0, r1, r2, r3", .code = 0xfb21_3002 },
        .{ .text = "smuad r0, r1, r2", .code = 0xfb21_f002 },
        .{ .text = "smladx r0, r1, r2, r3", .code = 0xfb21_3012 },
        .{ .text = "smuadx r0, r1, r2", .code = 0xfb21_f012 },
        .{ .text = "smlsd r0, r1, r2, r3", .code = 0xfb41_3002 },
        .{ .text = "smusd r0, r1, r2", .code = 0xfb41_f002 },
        .{ .text = "smlsdx r0, r1, r2, r3", .code = 0xfb41_3012 },
        .{ .text = "smusdx r0, r1, r2", .code = 0xfb41_f012 },
        .{ .text = "smmla r0, r1, r2, r3", .code = 0xfb51_3002 },
        .{ .text = "smmul r0, r1, r2", .code = 0xfb51_f002 },
        .{ .text = "smmlar r0, r1, r2, r3", .code = 0xfb51_3012 },
        .{ .text = "smmulr r0, r1, r2", .code = 0xfb51_f012 },
        .{ .text = "smmls r0, r1, r2, r3", .code = 0xfb61_3002 },
        .{ .text = "smmlsr r0, r1, r2, r3", .code = 0xfb61_3012 },
        .{ .text = "smlalbb r0, r1, r2, r3", .code = 0xfbc2_0183 },
        .{ .text = "smlalbt r0, r1, r2, r3", .code = 0xfbc2_0193 },
        .{ .text = "smlaltb r0, r1, r2, r3", .code = 0xfbc2_01a3 },
        .{ .text = "smlaltt r0, r1, r2, r3", .code = 0xfbc2_01b3 },
        .{ .text = "smlald r0, r1, r2, r3", .code = 0xfbc2_01c3 },
        .{ .text = "smlaldx r0, r1, r2, r3", .code = 0xfbc2_01d3 },
        .{ .text = "smlsld r0, r1, r2, r3", .code = 0xfbd2_01c3 },
        .{ .text = "smlsldx r0, r1, r2, r3", .code = 0xfbd2_01d3 },
        .{ .text = "umaal r0, r1, r2, r3", .code = 0xfbe2_0163 },
    });
}

test "the PACBTI aliases in the SMMLA, SMMLAR and SMMLS encodings keep the data-processing class" {
    try expectClass(.data_processing, &.{
        .{ .text = "autg r3, r1, r2", .code = 0xfb51_3f02 },
        .{ .text = "bxaut r3, r1, r2", .code = 0xfb51_3f12 },
        .{ .text = "pacg r0, r1, r2", .code = 0xfb61_f002 },
    });
}
