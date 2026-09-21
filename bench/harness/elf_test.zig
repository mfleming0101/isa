//! Tests of the ELF loader and section-size reader against synthesised images and objects: the
//! dropped thumb bit and vector-table stack pointer, zeroed bss, refused oversize segments, refused
//! foreign machines, section attribution by flags rather than name, and section tables past the end
//! of the object.

const std = @import("std");
const elf = @import("elf.zig");

fn synthesise(machine: u16, entry: u32, body: []const u8, bss_size: u32, out: []u8) []u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 1;
    out[5] = 1;
    std.mem.writeInt(u16, out[16..18], 2, .little);
    std.mem.writeInt(u16, out[18..20], machine, .little);
    std.mem.writeInt(u32, out[24..28], entry, .little);
    std.mem.writeInt(u32, out[28..32], 52, .little);
    std.mem.writeInt(u16, out[42..44], 32, .little);
    std.mem.writeInt(u16, out[44..46], 2, .little);

    const body_at = 52 + 64;
    @memcpy(out[body_at..][0..body.len], body);

    const text = out[52..][0..32];
    std.mem.writeInt(u32, text[0..4], 1, .little);
    std.mem.writeInt(u32, text[4..8], body_at, .little);
    std.mem.writeInt(u32, text[8..12], 0, .little);
    std.mem.writeInt(u32, text[16..20], @intCast(body.len), .little);
    std.mem.writeInt(u32, text[20..24], @intCast(body.len), .little);
    std.mem.writeInt(u32, text[24..28], 5, .little);

    const bss = out[52 + 32 ..][0..32];
    std.mem.writeInt(u32, bss[0..4], 1, .little);
    std.mem.writeInt(u32, bss[8..12], 0x1000, .little);
    std.mem.writeInt(u32, bss[20..24], bss_size, .little);
    std.mem.writeInt(u32, bss[24..28], 6, .little);

    return out[0 .. body_at + body.len];
}

test "an arm image loads, drops the thumb bit and takes sp from the vector table" {
    var file: [256]u8 = undefined;
    var body: [12]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 0x00300000, .little);
    std.mem.writeInt(u32, body[4..8], 0x00000009, .little);
    std.mem.writeInt(u32, body[8..12], 0xdeadbeef, .little);

    var memory: [0x2000]u8 = undefined;
    const loaded = try elf.load(synthesise(0x28, 9, &body, 0x40, &file), &memory, 0);

    try std.testing.expectEqual(elf.Loaded{
        .arch = .armv7m,
        .entry = 8,
        .sp = 0x00300000,
    }, loaded);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, memory[8..12], .little));
}

test "a bss segment is zeroed rather than read from the file" {
    var file: [256]u8 = undefined;
    var memory: [0x2000]u8 = undefined;
    @memset(&memory, 0xaa);
    _ = try elf.load(synthesise(0xf3, 0, &.{ 1, 2, 3, 4 }, 0x40, &file), &memory, 0);

    try std.testing.expectEqualSlices(u8, &@as([0x40]u8, @splat(0)), memory[0x1000..][0..0x40]);
}

test "a segment that does not fit is refused rather than truncated" {
    var file: [256]u8 = undefined;
    var memory: [0x100]u8 = undefined;
    try std.testing.expectError(error.DoesNotFit, elf.load(synthesise(0xf3, 0, &.{ 1, 2 }, 0x40, &file), &memory, 0));
}

test "a foreign machine is refused" {
    var file: [256]u8 = undefined;
    var memory: [0x2000]u8 = undefined;
    try std.testing.expectError(error.UnsupportedArch, elf.load(synthesise(0x3e, 0, &.{ 1, 2 }, 0, &file), &memory, 0));
}

fn withSections(out: []u8, entries: []const struct { kind: u32, flags: u32, size: u32 }) []u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 1;
    out[5] = 1;
    std.mem.writeInt(u32, out[32..36], 64, .little);
    std.mem.writeInt(u16, out[46..48], 40, .little);
    std.mem.writeInt(u16, out[48..50], @intCast(entries.len), .little);

    for (entries, 0..) |entry, i| {
        const it = out[64 + i * 40 ..][0..40];
        std.mem.writeInt(u32, it[4..8], entry.kind, .little);
        std.mem.writeInt(u32, it[8..12], entry.flags, .little);
        std.mem.writeInt(u32, it[20..24], entry.size, .little);
    }
    return out[0 .. 64 + entries.len * 40];
}

test "sections are attributed by allocation, writability and execute, not by name" {
    var file: [512]u8 = undefined;
    const got = try elf.sizes(withSections(&file, &.{
        .{ .kind = 1, .flags = 0x6, .size = 100 },
        .{ .kind = 1, .flags = 0x2, .size = 20 },
        .{ .kind = 1, .flags = 0x3, .size = 8 },
        .{ .kind = 8, .flags = 0x3, .size = 4096 },
        .{ .kind = 1, .flags = 0x0, .size = 9999 },
    }));

    try std.testing.expectEqual(elf.Sizes{ .text = 100, .rodata = 20, .data = 8, .bss = 4096 }, got);
}

test "a section table beyond the end of the object is refused rather than overflowing" {
    var file: [512]u8 = undefined;
    @memset(&file, 0);
    @memcpy(file[0..4], "\x7fELF");
    file[4] = 2;
    std.mem.writeInt(u64, file[40..48], 0xffff_ffff_ffff_fff0, .little);
    std.mem.writeInt(u16, file[58..60], 64, .little);
    std.mem.writeInt(u16, file[60..62], 1, .little);
    try std.testing.expectError(error.NotElf, elf.sizes(file[0..128]));
}
