//! Access to the pinned corpus manifest. `images` is corpus/manifest.zon imported as data, one
//! entry per pinned image with its architecture, path, retired count, stop reason and console
//! checksum; `archOf` and `matches` are the lookups bench/run.zig uses to pick a consumer and gate
//! a run.

const std = @import("std");
const facade = @import("facade.zig");
const snapshot = @import("snapshot.zig");

/// One pinned corpus image: name, architecture, path, retired count, stop reason and checksum.
pub const Image = struct {
    name: []const u8,
    arch: []const u8,
    path: []const u8,
    retired: u64,
    stop: []const u8,
    checksum: u32,
};

/// Every pinned image, read from corpus/manifest.zon.
pub const images: []const Image = @import("manifest");

/// Maps the manifest's architecture string onto the facade tag.
pub fn archOf(image: Image) facade.Arch {
    return if (std.mem.eql(u8, image.arch, "arm")) .armv7m else .rv32imc;
}

/// Whether a run retired, stopped and checksummed exactly as the image was pinned.
pub fn matches(image: Image, retired: u64, stop: snapshot.Stop, checksum: u32) bool {
    return retired == image.retired and std.mem.eql(u8, @tagName(stop), image.stop) and checksum == image.checksum;
}

test "every pinned image names an architecture the harness knows" {
    try std.testing.expectEqual(@as(usize, 49), images.len);
    for (images) |image| {
        try std.testing.expect(std.mem.eql(u8, image.arch, "arm") or std.mem.eql(u8, image.arch, "riscv"));
        try std.testing.expect(std.meta.stringToEnum(snapshot.Stop, image.stop) != null);
    }
}
