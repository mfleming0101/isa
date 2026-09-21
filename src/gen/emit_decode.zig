//! Emits the body of a generated decoder: nested switches over runs of code bits, ending in leaves
//! that either return a row index or call the row's semantic handler with operands extracted from
//! the code. A guarded leaf tests the forbidden field value first and falls back to the row a
//! rejected code takes. A gated row checks the group set before answering.

const std = @import("std");
const spec = @import("spec.zig");
const tree = @import("tree.zig");

/// Emits the expression extracting one field of the code, joining its bit runs most significant first.
pub fn operand(w: *std.Io.Writer, field: spec.Field) !void {
    var at: usize = 0;
    var first = true;
    while (at < field.positions.len) {
        var end = at + 1;
        while (end < field.positions.len and field.positions[end] == field.positions[end - 1] - 1) end += 1;
        const len = end - at;
        const lsb = field.positions[end - 1];
        const left = field.positions.len - end;

        if (!first) try w.writeAll(" | ");
        try w.print("((code >> {d}) & {d})", .{ lsb, (@as(u32, 1) << @intCast(len)) - 1 });
        if (left != 0) try w.print(" << {d}", .{left});
        first = false;
        at = end;
    }
    if (first) try w.writeAll("0");
}

/// Emits the tree as switches whose leaves return a row index or undefined_index.
pub fn indexTree(w: *std.Io.Writer, node: tree.Node, rows: []const spec.Row, gates: []const u32, depth: usize) !void {
    switch (node) {
        .leaf => |leaf| {
            for (leaf.guards) |g| {
                try pad(w, depth);
                try guard(w, g);
                try index(w, leaf.fallback, gates);
            }
            try pad(w, depth);
            try index(w, leaf.row, gates);
        },
        .branch => |br| {
            try pad(w, depth);
            try w.print("switch (@as(u{d}, @truncate(code >> {d}))) {{\n", .{ br.len, br.lsb });
            for (br.children, 0..) |child, k| {
                try pad(w, depth + 1);
                try w.print("{d} => {{\n", .{k});
                try indexTree(w, child, rows, gates, depth + 2);
                try pad(w, depth + 1);
                try w.writeAll("},\n");
            }
            try pad(w, depth);
            try w.writeAll("}\n");
        },
    }
}

/// Emits the tree as switches whose leaves call the row's handler and return its Done.
pub fn executeTree(w: *std.Io.Writer, node: tree.Node, rows: []const spec.Row, gates: []const u32, depth: usize) !void {
    switch (node) {
        .leaf => |leaf| {
            for (leaf.guards) |g| {
                try pad(w, depth);
                try guard(w, g);
                try execute(w, leaf.fallback, rows, gates);
            }
            try pad(w, depth);
            try execute(w, leaf.row, rows, gates);
        },
        .branch => |br| {
            try pad(w, depth);
            try w.print("switch (@as(u{d}, @truncate(code >> {d}))) {{\n", .{ br.len, br.lsb });
            for (br.children, 0..) |child, k| {
                try pad(w, depth + 1);
                try w.print("{d} => {{\n", .{k});
                try executeTree(w, child, rows, gates, depth + 2);
                try pad(w, depth + 1);
                try w.writeAll("},\n");
            }
            try pad(w, depth);
            try w.writeAll("}\n");
        },
    }
}

fn guard(w: *std.Io.Writer, c: spec.Constraint) !void {
    try w.writeAll("if (");
    try operand(w, c.field);
    try w.print(" == {d}) ", .{c.ne});
}

fn index(w: *std.Io.Writer, leaf: u32, gates: []const u32) !void {
    if (leaf == tree.undefined_index) return w.writeAll("return undefined_index;\n");
    if (gates[leaf] != 0) try w.print("{{ if (allowed & {d} == 0) return undefined_index; ", .{gates[leaf]});
    try w.print("return {d};{s}\n", .{ leaf, if (gates[leaf] != 0) " }" else "" });
}

fn execute(w: *std.Io.Writer, leaf: u32, rows: []const spec.Row, gates: []const u32) !void {
    if (leaf == tree.undefined_index) return w.writeAll("return .{};\n");
    const row = rows[leaf];
    if (gates[leaf] != 0) try w.print("{{ if (allowed & {d} == 0) return .{{}}; ", .{gates[leaf]});
    try w.print("return .by(@call(.always_inline, sem.@\"{s}\", .{{ s, host", .{row.name});
    for (row.fields) |f| {
        try w.writeAll(", ");
        try operand(w, f);
    }
    try w.print(" }}), .{s});{s}\n", .{ row.class, if (gates[leaf] != 0) " }" else "" });
}

fn pad(w: *std.Io.Writer, depth: usize) !void {
    try w.splatByteAll(' ', depth * 4);
}
