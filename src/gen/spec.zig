//! The generator's view of the shared row set. Loads the rows of `spec/*.zon` into `Row`, which
//! carries a mask and value for the fixed bits, a `Field` per lettered operand with its bit
//! positions, and a `Constraint` per forbidden field value. Rows keep their file order, which is
//! the order the generated tables index them by.

const std = @import("std");

const check = @import("spec");

/// The row schema shared with `spec/schema.zig`.
pub const schema = check.schema;
/// Every Arm row the spec defines.
pub const arm_rows: []const schema.Row = check.arm;
/// Every RISC-V row the spec defines.
pub const riscv_rows: []const schema.Row = check.riscv;

/// One lettered operand: its width and the code bit positions it occupies, most significant first.
pub const Field = struct {
    letter: u8,
    width: u8,
    positions: []const u8,
};

/// Whether a constraint holds, fails, or is undecided on the bits known so far.
pub const Status = enum { holds, fails, unknown };

/// A value the row forbids in one field because another row claims that encoding.
pub const Constraint = struct {
    field: Field,
    ne: u32,

    /// Decides the constraint against a partially known code.
    pub fn status(c: Constraint, mask: u32, value: u32) Status {
        var all = true;
        var shift: usize = c.field.width;
        for (c.field.positions) |p| {
            shift -= 1;
            const bit = @as(u32, 1) << @intCast(p);
            if (mask & bit == 0) {
                all = false;
                continue;
            }
            if (@intFromBool(value & bit != 0) != (c.ne >> @intCast(shift)) & 1) return .holds;
        }
        return if (all) .fails else .unknown;
    }

    /// Extends the known mask and value with the bits the forbidden value would pin.
    pub fn pinned(c: Constraint, mask: u32, value: u32) struct { u32, u32 } {
        var m = mask;
        var v = value;
        var shift: usize = c.field.width;
        for (c.field.positions) |p| {
            shift -= 1;
            const bit = @as(u32, 1) << @intCast(p);
            m |= bit;
            v = if ((c.ne >> @intCast(shift)) & 1 != 0) v | bit else v & ~bit;
        }
        return .{ m, v };
    }
};

/// One parsed row: fixed bits, operand fields, constraints, aliases and the disassembly template.
pub const Row = struct {
    name: []const u8,
    group: []const u8,
    text: []const u8,
    class: []const u8,
    bits: []const u8,
    width: u8,
    mask: u32,
    value: u32,
    fields: []const Field,
    when: []const Constraint,
    aliases: []const schema.Alias,

    /// Finds the operand field with the given letter.
    pub fn field(self: Row, letter: u8) ?Field {
        for (self.fields) |f| if (f.letter == letter) return f;
        return null;
    }
};

/// Parses every row of the set, in file order.
pub fn load(gpa: std.mem.Allocator, rows: []const schema.Row) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    for (rows) |row| try out.append(gpa, try parse(gpa, row));
    return out.items;
}

fn parse(gpa: std.mem.Allocator, row: schema.Row) !Row {
    const width: u8 = @intCast(row.bits.len);
    var mask: u32 = 0;
    var value: u32 = 0;
    for (row.bits, 0..) |ch, i| {
        const at: u5 = @intCast(width - 1 - i);
        if (ch == '0' or ch == '1') mask |= @as(u32, 1) << at;
        if (ch == '1') value |= @as(u32, 1) << at;
    }

    var fields: std.ArrayList(Field) = .empty;
    for (row.bits, 0..) |ch, i| {
        if (ch == '0' or ch == '1') continue;
        if (seen(fields.items, ch)) continue;

        var positions: std.ArrayList(u8) = .empty;
        for (row.bits[i..], i..) |c2, j| {
            if (c2 == ch) try positions.append(gpa, @intCast(width - 1 - j));
        }
        try fields.append(gpa, .{ .letter = ch, .width = @intCast(positions.items.len), .positions = positions.items });
    }

    var when: std.ArrayList(Constraint) = .empty;
    for (row.when) |c| {
        var positions: std.ArrayList(u8) = .empty;
        for (row.bits, 0..) |ch, i| {
            if (std.mem.indexOfScalar(u8, c.letters, ch) != null) try positions.append(gpa, @intCast(width - 1 - i));
        }
        if (positions.items.len == 0) return error.NoSuchField;
        try when.append(gpa, .{
            .field = .{ .letter = c.letters[0], .width = @intCast(positions.items.len), .positions = positions.items },
            .ne = c.ne,
        });
    }

    return .{
        .name = row.name,
        .group = row.group,
        .text = row.text,
        .class = row.class,
        .bits = row.bits,
        .width = width,
        .mask = mask,
        .value = value,
        .fields = fields.items,
        .when = when.items,
        .aliases = row.aliases,
    };
}

fn seen(fields: []const Field, letter: u8) bool {
    for (fields) |f| if (f.letter == letter) return true;
    return false;
}
