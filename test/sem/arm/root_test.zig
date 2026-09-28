//! Behavioural tests of the Arm semantics driven through the generated decoder with a host over a
//! small memory: the exclusive monitor across a load and store pair, CMP flag setting, the
//! conditional branch offset, the generated register masks, and the class of each multiply and
//! PACBTI alias. Covers what the per-row differential cannot see. Imported by tests.zig.
const std = @import("std");
const decode = @import("arm_decode");
const sem = @import("../../../src/sem/arm/root.zig");
const meta = @import("arm_meta");
const masks = @import("../../../src/arm/isa/masks.zig");

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

test "the generated written mask marks the registers a row writes" {
    const add = 0x3301; // adds r3, #1
    const ldr = 0x6823; // ldr r3, [r4]
    const str = 0x6023; // str r3, [r4]
    const udiv = 0xfbb1_f3f2; // udiv r3, r1, r2
    try std.testing.expectEqual(@as(u16, 1 << 3), masksOf(add, groups).written);
    try std.testing.expectEqual(@as(u16, 1 << 3), masksOf(ldr, groups).written);
    try std.testing.expectEqual(@as(u16, 0), masksOf(str, groups).written);
    try std.testing.expectEqual(@as(u16, 1 << 3), masksOf(udiv, groups).written);
}

test "the generated address mask names the base and offset registers of a load or store and nothing else" {
    const ldr = 0x6823; // ldr r3, [r4]
    const ldr_reg = 0x58a3; // ldr r3, [r4, r2]
    const add = 0x1842; // adds r2, r0, r1
    try std.testing.expectEqual(@as(u16, 1 << 4), masksOf(ldr, groups).addressed);
    try std.testing.expectEqual(@as(u16, 1 << 4 | 1 << 2), masksOf(ldr_reg, groups).addressed);
    try std.testing.expectEqual(@as(u16, 0), masksOf(add, groups).addressed);
}

test "the generated source mask leaves out the accumulator of a multiply" {
    const muls = 0x436b; // muls r3, r5, r3
    const mla = 0xfb05_3305; // mla r3, r5, r5, r3
    const mul = 0xfb03_f005; // mul r0, r3, r5
    try std.testing.expectEqual(@as(u16, 1 << 3 | 1 << 5), masksOf(muls, groups).sources);
    try std.testing.expectEqual(@as(u16, 1 << 5), masksOf(mla, groups).sources);
    try std.testing.expectEqual(@as(u16, 1 << 3 | 1 << 5), masksOf(mul, groups).sources);
}

const Masks = struct { text: []const u8, code: u32, written: []const u4, addressed: []const u4, sources: []const u4 };

fn bitsOf(list: []const u4) u16 {
    var out: u16 = 0;
    for (list) |r| out |= @as(u16, 1) << r;
    return out;
}

fn masksOf(code: u32, set: decode.Groups) masks.Masks {
    const row = if (code > 0xffff) decode.indexWide(code, set) else decode.indexNarrow(code, set);
    return masks.of(&meta.entries[meta.entryOf(row, code)], code);
}

fn expectMasks(cases: []const Masks) !void {
    const every = @import("../../../src/arm/isa/decode.zig").every;
    for (cases) |c| {
        const m = masksOf(c.code, every);
        const got = [_]u16{ m.written, m.addressed, m.sources };
        const want = [_]u16{ bitsOf(c.written), bitsOf(c.addressed), bitsOf(c.sources) };
        if (!std.mem.eql(u16, &got, &want)) {
            std.debug.print("{s}: written, addressed, sources {any}, want {any}\n", .{ c.text, got, want });
            return error.TestUnexpectedResult;
        }
    }
}

test "the generated masks see r8 and up, sp, lr and pc bases, and the MVE register pairs" {
    try expectMasks(&.{
        .{ .text = "ldr.w r0, [r8, #-4]", .code = 0xf858_0c04, .written = &.{0}, .addressed = &.{8}, .sources = &.{8} },
        .{ .text = "ldr.w r0, [r8, r1]", .code = 0xf858_0001, .written = &.{0}, .addressed = &.{ 1, 8 }, .sources = &.{ 1, 8 } },
        .{ .text = "ldr.w r0, [lr, #-4]", .code = 0xf85e_0c04, .written = &.{0}, .addressed = &.{14}, .sources = &.{14} },
        .{ .text = "ldr r0, [sp, #4]", .code = 0x9801, .written = &.{0}, .addressed = &.{13}, .sources = &.{13} },
        .{ .text = "str r0, [sp, #4]", .code = 0x9001, .written = &.{}, .addressed = &.{13}, .sources = &.{ 0, 13 } },
        .{ .text = "ldr r0, [pc, #4]", .code = 0x4801, .written = &.{0}, .addressed = &.{15}, .sources = &.{15} },
        .{ .text = "add sp, #8", .code = 0xb002, .written = &.{13}, .addressed = &.{}, .sources = &.{13} },
        .{ .text = "add r0, sp, #4", .code = 0xa801, .written = &.{0}, .addressed = &.{}, .sources = &.{13} },
        .{ .text = "bx lr", .code = 0x4770, .written = &.{}, .addressed = &.{}, .sources = &.{14} },
        .{ .text = "asrl r0, r1, #1", .code = 0xea50_016f, .written = &.{ 0, 1 }, .addressed = &.{}, .sources = &.{ 0, 1 } },
        .{ .text = "lsll r2, r5, r4", .code = 0xea52_450d, .written = &.{ 2, 5 }, .addressed = &.{}, .sources = &.{ 2, 4, 5 } },
        .{ .text = "sqrshr r3, r4", .code = 0xea53_4f2d, .written = &.{3}, .addressed = &.{}, .sources = &.{ 3, 4 } },
        .{ .text = "vshlc q0, r2, #1", .code = 0xeea1_0fc2, .written = &.{2}, .addressed = &.{}, .sources = &.{2} },
    });
}

test "the generated written mask holds writeback bases, loaded lists, and the SP or LR a push, pop or link implies" {
    try expectMasks(&.{
        .{ .text = "ldr.w r0, [r1], #4", .code = 0xf851_0b04, .written = &.{ 0, 1 }, .addressed = &.{1}, .sources = &.{1} },
        .{ .text = "ldr.w r8, [r9, #4]!", .code = 0xf859_8f04, .written = &.{ 8, 9 }, .addressed = &.{9}, .sources = &.{9} },
        .{ .text = "ldr.w pc, [sp], #4", .code = 0xf85d_fb04, .written = &.{ 13, 15 }, .addressed = &.{13}, .sources = &.{13} },
        .{ .text = "str.w r0, [r1, #-4]!", .code = 0xf841_0d04, .written = &.{1}, .addressed = &.{1}, .sources = &.{ 0, 1 } },
        .{ .text = "strd r0, r1, [r2, #8]!", .code = 0xe9e2_0102, .written = &.{2}, .addressed = &.{2}, .sources = &.{ 0, 1, 2 } },
        .{ .text = "ldrd r0, r1, [r2]", .code = 0xe9d2_0100, .written = &.{ 0, 1 }, .addressed = &.{2}, .sources = &.{2} },
        .{ .text = "ldm r1!, {r2, r3}", .code = 0xc90c, .written = &.{ 1, 2, 3 }, .addressed = &.{1}, .sources = &.{1} },
        .{ .text = "ldm r1, {r1, r2, r3}", .code = 0xc90e, .written = &.{ 1, 2, 3 }, .addressed = &.{1}, .sources = &.{1} },
        .{ .text = "stm r1!, {r2, r3}", .code = 0xc10c, .written = &.{1}, .addressed = &.{1}, .sources = &.{ 1, 2, 3 } },
        .{ .text = "ldm.w r0!, {r4-r11}", .code = 0xe8b0_0ff0, .written = &.{ 0, 4, 5, 6, 7, 8, 9, 10, 11 }, .addressed = &.{0}, .sources = &.{0} },
        .{ .text = "push {r4, lr}", .code = 0xb510, .written = &.{13}, .addressed = &.{13}, .sources = &.{ 4, 13, 14 } },
        .{ .text = "pop {r4, pc}", .code = 0xbd10, .written = &.{ 4, 13, 15 }, .addressed = &.{13}, .sources = &.{13} },
        .{ .text = "push.w {r4-r11, lr}", .code = 0xe92d_4ff0, .written = &.{13}, .addressed = &.{13}, .sources = &.{ 4, 5, 6, 7, 8, 9, 10, 11, 13, 14 } },
        .{ .text = "pop.w {r4-r11, pc}", .code = 0xe8bd_8ff0, .written = &.{ 4, 5, 6, 7, 8, 9, 10, 11, 13, 15 }, .addressed = &.{13}, .sources = &.{13} },
        .{ .text = "bl", .code = 0xf000_f800, .written = &.{14}, .addressed = &.{}, .sources = &.{} },
        .{ .text = "blx r3", .code = 0x4798, .written = &.{14}, .addressed = &.{}, .sources = &.{3} },
    });
}

test "the generated masks of an alias whose field holds 15 name no r15" {
    try expectMasks(&.{
        .{ .text = "cmp.w r0, r1", .code = 0xebb0_0f01, .written = &.{}, .addressed = &.{}, .sources = &.{ 0, 1 } },
        .{ .text = "tst.w r0, #1", .code = 0xf010_0f01, .written = &.{}, .addressed = &.{}, .sources = &.{0} },
        .{ .text = "teq r0, r1", .code = 0xea90_0f01, .written = &.{}, .addressed = &.{}, .sources = &.{ 0, 1 } },
        .{ .text = "pld [r0]", .code = 0xf890_f000, .written = &.{}, .addressed = &.{0}, .sources = &.{0} },
        .{ .text = "mov.w r0, r1", .code = 0xea4f_0001, .written = &.{0}, .addressed = &.{}, .sources = &.{1} },
        .{ .text = "mov.w r0, #1", .code = 0xf04f_0001, .written = &.{0}, .addressed = &.{}, .sources = &.{} },
        .{ .text = "bfc r0, #0, #8", .code = 0xf36f_0007, .written = &.{0}, .addressed = &.{}, .sources = &.{0} },
        .{ .text = "mul.w r0, r1, r2", .code = 0xfb01_f002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "smulbb r0, r1, r2", .code = 0xfb11_f002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "smmul r0, r1, r2", .code = 0xfb51_f002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
    });
}

test "the generated source mask holds two-address and read-modify-write destinations and store data, not accumulators" {
    try expectMasks(&.{
        .{ .text = "adds r3, #1", .code = 0x3301, .written = &.{3}, .addressed = &.{}, .sources = &.{3} },
        .{ .text = "lsrs r1, r2", .code = 0x40d1, .written = &.{1}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "ands r1, r2", .code = 0x4011, .written = &.{1}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "adcs r0, r1", .code = 0x4148, .written = &.{0}, .addressed = &.{}, .sources = &.{ 0, 1 } },
        .{ .text = "add r8, r1", .code = 0x4488, .written = &.{8}, .addressed = &.{}, .sources = &.{ 1, 8 } },
        .{ .text = "mov r8, r1", .code = 0x4688, .written = &.{8}, .addressed = &.{}, .sources = &.{1} },
        .{ .text = "lsls r1, r2, #1", .code = 0x0051, .written = &.{1}, .addressed = &.{}, .sources = &.{2} },
        .{ .text = "movt r0, #1", .code = 0xf2c0_0001, .written = &.{0}, .addressed = &.{}, .sources = &.{0} },
        .{ .text = "bfi r0, r1, #0, #8", .code = 0xf361_0007, .written = &.{0}, .addressed = &.{}, .sources = &.{ 0, 1 } },
        .{ .text = "str r3, [r4]", .code = 0x6023, .written = &.{}, .addressed = &.{4}, .sources = &.{ 3, 4 } },
        .{ .text = "strex r0, r2, [r1]", .code = 0xe841_2000, .written = &.{0}, .addressed = &.{1}, .sources = &.{ 1, 2 } },
        .{ .text = "vmov s0, r0", .code = 0xee00_0a10, .written = &.{}, .addressed = &.{}, .sources = &.{0} },
        .{ .text = "vmov r0, r1, d0", .code = 0xec51_0b10, .written = &.{ 0, 1 }, .addressed = &.{}, .sources = &.{} },
        .{ .text = "mla r0, r1, r2, r3", .code = 0xfb01_3002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "umlal r0, r1, r2, r3", .code = 0xfbe2_0103, .written = &.{ 0, 1 }, .addressed = &.{}, .sources = &.{ 2, 3 } },
        .{ .text = "umull r0, r1, r2, r3", .code = 0xfba2_0103, .written = &.{ 0, 1 }, .addressed = &.{}, .sources = &.{ 2, 3 } },
    });
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

test "the generated source mask leaves out DSP multiply accumulators and keeps every operand of a PACBTI alias" {
    try expectMasks(&.{
        .{ .text = "smlabb r0, r1, r2, r3", .code = 0xfb11_3002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
        .{ .text = "umaal r0, r1, r2, r3", .code = 0xfbe2_0163, .written = &.{ 0, 1 }, .addressed = &.{}, .sources = &.{ 2, 3 } },
        .{ .text = "autg r3, r1, r2", .code = 0xfb51_3f02, .written = &.{}, .addressed = &.{}, .sources = &.{ 1, 2, 3 } },
        .{ .text = "pacg r0, r1, r2", .code = 0xfb61_f002, .written = &.{0}, .addressed = &.{}, .sources = &.{ 1, 2 } },
    });
}
