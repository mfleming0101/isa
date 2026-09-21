//! Renders the latest admissible row of every alternative side by side, behind `zig build compare
//! [summary.tsv ...]`. Columns are matched by header name rather than position, a row that failed
//! its gates never displaces an earlier admissible one, and columns a partial row may not carry are
//! shown as a dash.

const std = @import("std");
const metrics = @import("harness").metrics;

/// Reads the summaries, keeps each alternative's latest admissible row and prints them as columns.
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next();

    var paths: std.ArrayList([]const u8) = .empty;
    while (args.next()) |path| try paths.append(gpa, try gpa.dupe(u8, path));
    if (paths.items.len == 0) try paths.append(gpa, "bench/summary.tsv");

    var names: []const []const u8 = &.{};
    var alts: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList([]const []const u8) = .empty;
    var states: std.ArrayList(metrics.Status) = .empty;

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
            const alt = fields[column(names, "alt") orelse continue];
            const variant = fields[column(names, "variant") orelse continue];
            const label = if (variant.len == 0) alt else try std.fmt.allocPrint(gpa, "{s} {s}", .{ alt, variant });
            const at = find(alts.items, label) orelse blk: {
                try alts.append(gpa, label);
                try rows.append(gpa, fields);
                try states.append(gpa, state);
                break :blk null;
            };
            if (at) |i| {
                rows.items[i] = fields;
                states.items[i] = state;
            }
        }
    }
    if (alts.items.len == 0) return error.NoRows;

    var label: usize = 0;
    for (names) |name| label = @max(label, name.len);
    const widths = try gpa.alloc(usize, alts.items.len);
    for (alts.items, widths) |alt, *width| width.* = alt.len;
    for (rows.items, widths) |row, *width| for (row) |field| {
        width.* = @max(width.*, field.len);
    };

    var buffer: [1 << 16]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    try out.splatByteAll(' ', label);
    for (alts.items, widths) |alt, width| try out.print("  {s: <[1]}", .{ alt, width });
    try out.writeByte('\n');

    for (names, 0..) |name, i| {
        try out.print("{s: <[1]}", .{ name, label });
        for (rows.items, states.items, widths) |row, state, width| try out.print("  {s: <[1]}", .{ if (metrics.admits(state, name)) row[i] else "-", width });
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
