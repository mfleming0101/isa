//! Emits the meta file of an architecture: how many rows the generated tree implements, how many
//! the spec defines, and the row names indexed like the decoder's leaves.

const std = @import("std");
const spec = @import("spec.zig");

/// Writes the row counts and the name table for the given rows.
pub fn write(w: *std.Io.Writer, rows: []const spec.Row, total: usize) !void {
    try w.print("/// How many rows the generated tree carries.\npub const rows_implemented: usize = {d};\n", .{rows.len});
    try w.print("/// How many rows the spec defines for this architecture.\npub const rows_total: usize = {d};\n", .{total});
    try w.writeAll("/// The spec name of each row, indexed like the decoder's leaves.\npub const names = [_][]const u8{\n");
    for (rows) |r| try w.print("    \"{s}\",\n", .{r.name});
    try w.writeAll("};\n");
}
