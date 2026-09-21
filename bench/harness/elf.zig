//! Minimal ELF reader for the harness. `load` copies a little-endian Arm or RISC-V ELF32
//! executable's PT_LOAD segments into flat memory and returns its entry and stack pointer; `sizes`
//! sums the allocated sections of an ELF32 or ELF64 object by kind, which is how the size probe's
//! text, rodata, data and bss columns are measured.

const std = @import("std");
const facade = @import("facade.zig");

/// Why an image or object was refused.
pub const Error = error{ NotElf, UnsupportedClass, UnsupportedArch, DoesNotFit };

/// The architecture, entry point and initial stack pointer an image loads with.
pub const Loaded = struct {
    arch: facade.Arch,
    entry: u32,
    sp: u32,
};

/// Copies the image's PT_LOAD segments into zeroed memory at base and returns its entry state.
pub fn load(image: []const u8, memory: []u8, base: u32) Error!Loaded {
    if (image.len < 52 or !std.mem.eql(u8, image[0..4], "\x7fELF")) return error.NotElf;
    if (image[4] != 1 or image[5] != 1) return error.UnsupportedClass;

    const arch: facade.Arch = switch (std.mem.readInt(u16, image[18..20], .little)) {
        0x28 => .armv7m,
        0xf3 => .rv32imc,
        else => return error.UnsupportedArch,
    };
    const entry = std.mem.readInt(u32, image[24..28], .little);
    const phoff = std.mem.readInt(u32, image[28..32], .little);
    const phentsize = std.mem.readInt(u16, image[42..44], .little);
    const phnum = std.mem.readInt(u16, image[44..46], .little);

    @memset(memory, 0);
    for (0..phnum) |i| {
        const at = phoff + i * phentsize;
        if (at + 32 > image.len) return error.NotElf;
        const header = image[at..][0..32];
        if (std.mem.readInt(u32, header[0..4], .little) != 1) continue;

        const offset = std.mem.readInt(u32, header[4..8], .little);
        const vaddr = std.mem.readInt(u32, header[8..12], .little);
        const filesz = std.mem.readInt(u32, header[16..20], .little);
        const memsz = std.mem.readInt(u32, header[20..24], .little);

        const into = vaddr -% base;
        if (@as(u64, into) + @max(filesz, memsz) > memory.len) return error.DoesNotFit;
        if (@as(u64, offset) + filesz > image.len) return error.NotElf;
        @memcpy(memory[into..][0..filesz], image[offset..][0..filesz]);
    }

    return .{
        .arch = arch,
        .entry = if (arch == .armv7m) entry & ~@as(u32, 1) else entry,
        .sp = if (arch == .armv7m) std.mem.readInt(u32, memory[0..4], .little) else 0,
    };
}

/// Byte totals of the allocated sections, split by kind.
pub const Sizes = struct {
    text: u64 = 0,
    rodata: u64 = 0,
    data: u64 = 0,
    bss: u64 = 0,
};

/// Sums an ELF32 or ELF64 object's allocated sections into text, rodata, data and bss.
pub fn sizes(object: []const u8) Error!Sizes {
    if (object.len < 64 or !std.mem.eql(u8, object[0..4], "\x7fELF")) return error.NotElf;
    const wide = switch (object[4]) {
        1 => false,
        2 => true,
        else => return error.UnsupportedClass,
    };

    const shoff: u64 = if (wide) std.mem.readInt(u64, object[40..48], .little) else std.mem.readInt(u32, object[32..36], .little);
    const shentsize = std.mem.readInt(u16, if (wide) object[58..60] else object[46..48], .little);
    const shnum = std.mem.readInt(u16, if (wide) object[60..62] else object[48..50], .little);
    if (shnum == 0) return error.NotElf;

    const header = struct {
        fn at(bytes: []const u8, base: u64, entsize: u16, index: usize) Error![]const u8 {
            const start = base + index * entsize;
            if (start > bytes.len or entsize > bytes.len - start) return error.NotElf;
            return bytes[@intCast(start)..][0..entsize];
        }
    };

    var out: Sizes = .{};
    for (0..shnum) |i| {
        const it = try header.at(object, shoff, shentsize, i);
        const kind = std.mem.readInt(u32, it[4..8], .little);
        const flags: u64 = if (wide) std.mem.readInt(u64, it[8..16], .little) else std.mem.readInt(u32, it[8..12], .little);
        const size: u64 = if (wide) std.mem.readInt(u64, it[32..40], .little) else std.mem.readInt(u32, it[20..24], .little);
        if (flags & 2 == 0) continue;
        const field = if (kind == 8)
            &out.bss
        else if (flags & 4 != 0)
            &out.text
        else if (flags & 1 != 0)
            &out.data
        else
            &out.rodata;
        field.* += size;
    }
    return out;
}
