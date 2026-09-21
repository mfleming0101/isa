//! The shape of a spec row and the checks over a row set. A row names one instruction encoding: a
//! bit pattern of fixed bits and operand letters, its assembler text with the letters as fields,
//! the semantic class its cost is read from, the group that gates it, constraints that forbid field
//! values another row claims, and aliases that render special cases. `validate` and `ambiguities`
//! decide whether a set is well formed and whether any two rows can match one code.
const std = @import("std");

/// An alternative rendering used when the named field holds the value.
pub const Alias = struct { text: []const u8, letter: u8, value: u32 = 15 };

/// A value the row forbids in the fields the letters name, because another row claims it.
pub const Constraint = struct { letters: []const u8, ne: u32 };

/// One instruction encoding: name, bit pattern, assembler text, class, group, constraints and aliases.
pub const Row = struct {
    name: []const u8,
    bits: []const u8,
    text: []const u8,
    class: []const u8,
    group: []const u8,
    when: []const Constraint = &.{},
    aliases: []const Alias = &.{},
};

/// The encoding width in bits, the length of the bit pattern.
pub fn width(row: Row) u8 {
    return @intCast(row.bits.len);
}

/// The bits the pattern fixes.
pub fn mask(row: Row) u32 {
    var m: u32 = 0;
    for (row.bits, 0..) |ch, i| {
        if (ch == '0' or ch == '1') m |= @as(u32, 1) << @intCast(row.bits.len - 1 - i);
    }
    return m;
}

/// The values of the fixed bits.
pub fn match(row: Row) u32 {
    var m: u32 = 0;
    for (row.bits, 0..) |ch, i| {
        if (ch == '1') m |= @as(u32, 1) << @intCast(row.bits.len - 1 - i);
    }
    return m;
}

/// Why a row set is malformed: a bad width, a bad pattern character, or two overlapping rows.
pub const Problem = union(enum) {
    bad_width: struct { row: usize },
    bad_character: struct { row: usize, at: usize },
    overlap: struct { a: usize, b: usize },
};

/// The first problem in the row set, or null when it is well formed.
pub fn validate(rows: []const Row) ?Problem {
    for (rows, 0..) |row, i| {
        if (row.bits.len != 16 and row.bits.len != 32) return .{ .bad_width = .{ .row = i } };
        for (row.bits, 0..) |ch, at| {
            if (ch != '0' and ch != '1' and !std.ascii.isAlphabetic(ch)) return .{ .bad_character = .{ .row = i, .at = at } };
        }
    }
    for (rows, 0..) |a, i| {
        for (rows[i + 1 ..], i + 1..) |b, j| {
            if (a.bits.len != b.bits.len) continue;
            const both = mask(a) & mask(b);
            if (match(a) & both != match(b) & both) continue;
            if (excludes(a, b) or excludes(b, a)) continue;
            return .{ .overlap = .{ .a = i, .b = j } };
        }
    }
    return null;
}

/// How many pairs of rows can both match one code.
pub fn ambiguities(rows: []const Row) u32 {
    var n: u32 = 0;
    for (rows, 0..) |a, i| {
        for (rows[i + 1 ..]) |b| {
            if (a.bits.len != b.bits.len) continue;
            const both = mask(a) & mask(b);
            if (match(a) & both != match(b) & both) continue;
            if (excludes(a, b) or excludes(b, a)) continue;
            n += 1;
        }
    }
    return n;
}

fn excludes(a: Row, b: Row) bool {
    for (a.when) |c| {
        if (forced(a, c.letters, b)) |value| {
            if (value == c.ne) return true;
        }
    }
    return false;
}

fn forced(a: Row, letters: []const u8, b: Row) ?u32 {
    var value: u32 = 0;
    var seen = false;
    for (a.bits, 0..) |ch, i| {
        if (std.mem.indexOfScalar(u8, letters, ch) == null) continue;
        seen = true;
        const bit = @as(u32, 1) << @intCast(a.bits.len - 1 - i);
        if (mask(b) & bit == 0) return null;
        value = value << 1 | @intFromBool(match(b) & bit != 0);
    }
    return if (seen) value else null;
}
