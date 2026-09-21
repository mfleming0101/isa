//! Builds the decision tree a decoder is emitted from. Starting with every row of one width,
//! `build` repeatedly picks the run of bits that best splits the remaining candidates, branches on
//! it, and settles a leaf once a single row has had all its fixed bits tested. A leaf whose row
//! carries constraints keeps them as guards, with the fallback row a rejected code takes.

const std = @import("std");
const spec = @import("spec.zig");

/// The leaf value that names no row.
pub const undefined_index = std.math.maxInt(u32);

/// A branch on a run of bits, or a leaf.
pub const Node = union(enum) {
    leaf: Leaf,
    branch: Branch,
};

/// A row taken where every guard holds, and the row a guarded-out code takes instead.
pub const Leaf = struct {
    row: u32 = undefined_index,
    guards: []const spec.Constraint = &.{},
    fallback: u32 = undefined_index,
};

/// A switch over `len` bits starting at `lsb`, with one child per value.
pub const Branch = struct {
    lsb: u5,
    len: u5,
    children: []const Node,
};

const Build = struct {
    gpa: std.mem.Allocator,
    rows: []const spec.Row,
    width: u8,
    members: []const bool,
};

/// Builds the tree over the member rows of the given width.
pub fn build(gpa: std.mem.Allocator, rows: []const spec.Row, width: u8, members: []const bool) !Node {
    var all: std.ArrayList(u32) = .empty;
    for (rows, 0..) |r, i| if (r.width == width and members[i]) try all.append(gpa, @intCast(i));
    var b: Build = .{ .gpa = gpa, .rows = rows, .width = width, .members = members };
    return descend(&b, all.items, 0, 0);
}

fn descend(b: *Build, candidates: []const u32, tested: u32, known: u32) !Node {
    if (candidates.len == 0) return .{ .leaf = .{} };
    if (candidates.len == 1 and b.rows[candidates[0]].mask & ~tested == 0) return .{ .leaf = try settle(b, candidates[0], tested, known) };

    const run = pick(b, candidates, tested) orelse return .{ .leaf = .{} };
    const count = @as(usize, 1) << run.len;
    const children = try b.gpa.alloc(Node, count);
    const now = tested | (fill(run.len) << run.lsb);

    for (children, 0..) |*child, k| {
        const value = (known & ~(fill(run.len) << run.lsb)) | (@as(u32, @intCast(k)) << run.lsb);
        var kept: std.ArrayList(u32) = .empty;
        for (candidates) |i| {
            const row = b.rows[i];
            const fixed = (row.mask >> run.lsb) & fill(run.len);
            const want = (row.value >> run.lsb) & fill(run.len);
            if (want & fixed != @as(u32, @intCast(k)) & fixed) continue;
            if (rejects(row, now, value)) continue;
            try kept.append(b.gpa, i);
        }
        child.* = try descend(b, kept.items, now, value);
    }
    return .{ .branch = .{ .lsb = run.lsb, .len = run.len, .children = children } };
}

fn rejects(row: spec.Row, tested: u32, known: u32) bool {
    for (row.when) |c| if (c.status(tested, known) == .fails) return true;
    return false;
}

fn settle(b: *Build, row: u32, tested: u32, known: u32) !Leaf {
    var guards: std.ArrayList(spec.Constraint) = .empty;
    for (b.rows[row].when) |c| {
        if (c.status(tested, known) == .unknown) try guards.append(b.gpa, c);
    }
    if (guards.items.len == 0) return .{ .row = row };
    return .{ .row = row, .guards = guards.items, .fallback = other(b, row, tested, known) };
}

fn other(b: *Build, row: u32, tested: u32, known: u32) u32 {
    var found: u32 = undefined_index;
    for (b.rows, 0..) |r, i| {
        if (i == row or r.width != b.width or !b.members[i]) continue;
        if ((r.value ^ known) & (r.mask & tested) != 0) continue;
        if (rejects(r, tested, known)) continue;
        if (found != undefined_index) return undefined_index;
        found = @intCast(i);
    }
    return found;
}

fn fill(len: u5) u32 {
    return (@as(u32, 1) << len) - 1;
}

const Run = struct { lsb: u5, len: u5 };

fn pick(b: *Build, candidates: []const u32, tested: u32) ?Run {
    var common: u32 = ~tested;
    var any: u32 = 0;
    for (candidates) |i| {
        common &= b.rows[i].mask;
        any |= b.rows[i].mask & ~tested;
    }
    if (common != 0) return longest(common, b.width);
    if (any == 0) return null;
    return .{ .lsb = @intCast(@ctz(any)), .len = 1 };
}

fn longest(word: u32, width: u8) Run {
    var best: Run = .{ .lsb = 0, .len = 0 };
    var at: u8 = 0;
    while (at < width) {
        if (word >> @intCast(at) & 1 == 0) {
            at += 1;
            continue;
        }
        var end = at;
        while (end < width and word >> @intCast(end) & 1 == 1) end += 1;
        const len: u8 = @min(end - at, 8);
        if (len > best.len) best = .{ .lsb = @intCast(at), .len = @intCast(len) };
        at = end;
    }
    return best;
}
