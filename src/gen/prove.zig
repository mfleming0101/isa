//! The two proofs the generator makes before emitting anything. `disjoint` checks that no code can
//! match two rows of one width, allowing for the constraints that carve one row's encoding out of
//! another's. `total` checks that every region a tree carves out answers exactly what a naive
//! mask-and-match scan over that region answers, including both regions a guarded leaf splits into.

const std = @import("std");
const spec = @import("spec.zig");
const tree = @import("tree.zig");

/// The names of two rows that can both match one code.
pub const Overlap = struct { a: []const u8, b: []const u8 };

/// Returns the first pair of rows that can both match one code, or null.
pub fn disjoint(rows: []const spec.Row) ?Overlap {
    for (rows, 0..) |a, i| {
        for (rows[i + 1 ..]) |b| {
            if (a.width != b.width) continue;
            const both = a.mask & b.mask;
            if ((a.value ^ b.value) & both != 0) continue;
            if (excludes(a, b) or excludes(b, a)) continue;
            return .{ .a = a.name, .b = b.name };
        }
    }
    return null;
}

fn excludes(a: spec.Row, b: spec.Row) bool {
    for (a.when) |c| if (c.status(b.mask, b.value) == .fails) return true;
    return false;
}

/// A region where the tree disagrees with a scan: its known bits, leaf and candidate count.
pub const Hole = struct { known_mask: u32, known_value: u32, leaf: u32, candidates: usize };

/// Walks the tree and returns the first region whose leaf disagrees with a scan, or null.
pub fn total(gpa: std.mem.Allocator, node: tree.Node, rows: []const spec.Row, width: u8, members: []const bool) !?Hole {
    return walk(gpa, node, rows, width, members, 0, 0);
}

fn walk(gpa: std.mem.Allocator, node: tree.Node, rows: []const spec.Row, width: u8, members: []const bool, known_mask: u32, known_value: u32) !?Hole {
    switch (node) {
        .leaf => |leaf| {
            if (region(rows, members, width, known_mask, known_value, leaf.guards, leaf.row)) |hole| return hole;
            for (leaf.guards) |g| {
                const rejected = g.pinned(known_mask, known_value);
                if (region(rows, members, width, rejected[0], rejected[1], &.{}, leaf.fallback)) |hole| return hole;
            }
            return null;
        },
        .branch => |br| {
            const span = ((@as(u32, 1) << br.len) - 1) << br.lsb;
            for (br.children, 0..) |child, k| {
                const value = (known_value & ~span) | (@as(u32, @intCast(k)) << br.lsb);
                if (try walk(gpa, child, rows, width, members, known_mask | span, value)) |hole| return hole;
            }
            return null;
        },
    }
}

fn region(rows: []const spec.Row, members: []const bool, width: u8, known_mask: u32, known_value: u32, guards: []const spec.Constraint, expect: u32) ?Hole {
    var count: usize = 0;
    var only: u32 = tree.undefined_index;
    for (rows, 0..) |r, i| {
        if (r.width != width or !members[i]) continue;
        if ((r.value ^ known_value) & (r.mask & known_mask) != 0) continue;
        if (fails(r, known_mask, known_value)) continue;
        count += 1;
        only = @intCast(i);
    }
    const bad = if (expect == tree.undefined_index)
        count != 0
    else
        count != 1 or only != expect or rows[expect].mask & ~known_mask != 0 or
            !settled(rows[expect], known_mask, known_value, guards);
    if (bad) return .{ .known_mask = known_mask, .known_value = known_value, .leaf = expect, .candidates = count };
    return null;
}

fn fails(r: spec.Row, known_mask: u32, known_value: u32) bool {
    for (r.when) |c| if (c.status(known_mask, known_value) == .fails) return true;
    return false;
}

fn settled(r: spec.Row, known_mask: u32, known_value: u32, guards: []const spec.Constraint) bool {
    for (r.when) |c| {
        if (c.status(known_mask, known_value) != .unknown) continue;
        if (!assumed(guards, c)) return false;
    }
    return true;
}

fn assumed(guards: []const spec.Constraint, c: spec.Constraint) bool {
    for (guards) |g| if (g.ne == c.ne and std.mem.eql(u8, g.field.positions, c.field.positions)) return true;
    return false;
}

test "two rows one code can match are reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pair = try spec.load(arena.allocator(), &.{
        .{ .name = "ADD", .bits = "1001dddddmmmmm10", .text = "", .class = "", .group = "c" },
        .{ .name = "JALR", .bits = "1001nnnnn0000010", .text = "", .class = "", .group = "c" },
    });
    try std.testing.expect(disjoint(pair) != null);
}

test "a row whose constraint forbids the value the other fixes is disjoint from it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pair = try spec.load(arena.allocator(), &.{
        .{ .name = "ADD", .bits = "1001dddddmmmmm10", .text = "", .class = "", .group = "c", .when = &.{.{ .letters = "m", .ne = 0 }} },
        .{ .name = "JALR", .bits = "1001nnnnn0000010", .text = "", .class = "", .group = "c" },
    });
    try std.testing.expect(disjoint(pair) == null);
}
