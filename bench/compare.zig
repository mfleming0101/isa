//! Renders the latest admissible row of every commit side by side, behind `zig build compare
//! [summary.tsv ...]`. Columns are matched by header name rather than position, and a row that
//! failed its gates never displaces an earlier admissible one.

const std = @import("std");
const metrics = @import("harness").metrics;

/// Reads the summaries, keeps each commit's latest admissible row and prints them as columns.
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next();

    var paths: std.ArrayList([]const u8) = .empty;
    while (args.next()) |path| try paths.append(gpa, try gpa.dupe(u8, path));
    if (paths.items.len == 0) try paths.append(gpa, "bench/summary.tsv");

    var names: []const []const u8 = &.{};
    var labels: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList([]const []const u8) = .empty;

    for (paths.items) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 << 20));
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header = lines.next() orelse continue;
        if (names.len == 0) names = try split(gpa, header) else if (!std.mem.eql(u8, std.mem.trimEnd(u8, header, "\r"), try join(gpa, names))) return error.HeaderMismatch;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const fields = try split(gpa, line);
            if (fields.len != names.len) continue;
            const state = std.meta.stringToEnum(metrics.Status, fields[column(names, "status") orelse continue]) orelse continue;
            if (state == .fail) continue;
            const label = fields[column(names, "commit") orelse continue];
            const at = find(labels.items, label) orelse blk: {
                try labels.append(gpa, label);
                try rows.append(gpa, fields);
                break :blk null;
            };
            if (at) |i| rows.items[i] = fields;
        }
    }
    if (labels.items.len == 0) return error.NoRows;

    var label: usize = 0;
    for (names) |name| label = @max(label, name.len);
    const widths = try gpa.alloc(usize, labels.items.len);
    for (labels.items, widths) |each, *width| width.* = each.len;
    for (rows.items, widths) |row, *width| for (row) |field| {
        width.* = @max(width.*, field.len);
    };

    var buffer: [1 << 16]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    try out.splatByteAll(' ', label);
    for (labels.items, widths) |each, width| try out.print("  {s: <[1]}", .{ each, width });
    try out.writeByte('\n');

    for (names, 0..) |name, i| {
        try out.print("{s: <[1]}", .{ name, label });
        for (rows.items, widths) |row, width| try out.print("  {s: <[1]}", .{ row[i], width });
        try out.writeByte('\n');
    }
}

fn join(gpa: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| try out.print(gpa, "{s}{s}", .{ if (i == 0) "" else "\t", name });
    return out.items;
}

fn split(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), '\t');
    while (it.next()) |field| try fields.append(gpa, field);
    return fields.items;
}

fn column(names: []const []const u8, want: []const u8) ?usize {
    return find(names, want);
}

fn find(haystack: []const []const u8, want: []const u8) ?usize {
    for (haystack, 0..) |item, i| if (std.mem.eql(u8, item, want)) return i;
    return null;
}
