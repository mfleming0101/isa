//! Emits the meta file of an architecture: how many rows the generated tree implements, how many
//! the spec defines, the row names indexed like the decoder's leaves and, for Arm, an entry per row
//! then per alias with its class and the places and roles of the registers its text names, which
//! src/arm/isa/masks.zig reads. A general register inside brackets forms the address; before them
//! it is the destination or a source by class and mnemonic; a list is loaded or stored. Push, pop,
//! BL and BLX add their implied SP or LR. Registers a custom renderer prints get no bits.

const std = @import("std");
const spec = @import("spec.zig");
const emit_decode = @import("emit_decode.zig");

/// Writes the row counts and the name table for the given rows, and for Arm the meta entries.
pub fn write(w: *std.Io.Writer, rows: []const spec.Row, total: usize, arm: bool) !void {
    try w.print("/// How many rows the generated tree carries.\npub const rows_implemented: usize = {d};\n", .{rows.len});
    try w.print("/// How many rows the spec defines for this architecture.\npub const rows_total: usize = {d};\n", .{total});
    try w.writeAll("/// The spec name of each row, indexed like the decoder's leaves.\npub const names = [_][]const u8{\n");
    for (rows) |r| try w.print("    \"{s}\",\n", .{r.name});
    try w.writeAll("};\n");
    if (arm) try entries(w, rows);
}

/// The meta entry of each row's first alias; aliases follow the rows, in row order.
pub fn firstAliases(gpa: std.mem.Allocator, rows: []const spec.Row) ![]u32 {
    const out = try gpa.alloc(u32, rows.len);
    var next: u32 = @intCast(rows.len);
    for (rows, out) |r, *first| {
        first.* = next;
        next += @intCast(r.aliases.len);
    }
    return out;
}

fn entries(w: *std.Io.Writer, rows: []const spec.Row) !void {
    try w.writeAll("\nconst Entry = @import(\"isa\").arm.masks.Entry;\n\n");
    try w.writeAll("/// The class and register places of each row, then of each alias, then of a code no row claims.\n");
    try w.writeAll("pub const entries = [_]Entry{\n");
    for (rows) |r| try entry(w, r, r.text, r.class);
    for (rows) |r| for (r.aliases) |a| try entry(w, r, a.text, a.class orelse r.class);
    try w.writeAll("    .{},\n};\n");
    try w.writeAll("\n/// The entry of a row's code: its alias's where the alias field matches, the last where no row claims it.\n");
    try w.writeAll("pub fn entryOf(row: u32, code: u32) u11 {\n    return switch (row) {\n");
    var next = rows.len;
    for (rows, 0..) |r, i| {
        if (r.aliases.len == 0) continue;
        try w.print("        {d} => ", .{i});
        for (r.aliases) |a| {
            try w.writeAll("if (");
            try emit_decode.operand(w, r.field(a.letter).?);
            try w.print(" == {d}) {d} else ", .{ a.value, next });
            next += 1;
        }
        try w.print("{d},\n", .{i});
    }
    if (next > std.math.maxInt(u11)) return error.TooManyEntries;
    try w.print("        else => if (row < {d}) @intCast(row) else {d},\n    }};\n}}\n", .{ rows.len, next });
}

const FieldRegister = struct { letter: u8, scale: u32 = 1, offset: u32 = 0, none_at_15: bool = false };

const Register = union(enum) {
    field: FieldRegister,
    fixed: u4,
    list,
};

const Written = enum { no, yes, w_field, unlisted };

const Operand = struct {
    register: Register,
    read: bool = false,
    written: Written = .no,
    addressed: bool = false,
    accumulator: bool = false,
};

const Operands = struct {
    items: [12]Operand = undefined,
    len: usize = 0,

    fn add(self: *Operands, o: Operand) void {
        self.items[self.len] = o;
        self.len += 1;
    }

    fn slice(self: *const Operands) []const Operand {
        return self.items[0..self.len];
    }
};

const no_destination = [_][]const u8{ "cmp", "cmn", "tst", "teq", "bx", "blx", "bxns", "blxns", "cbz", "cbnz", "vctp", "vlldm", "vlstm", "autg", "bxaut" };
const two_address = [_][]const u8{ "adcs", "adds", "add", "ands", "asrs", "bics", "eors", "lsls", "lsrs", "orrs", "rors", "sbcs", "subs", "sub" };
const updates = [_][]const u8{
    "movt",    "bfi",     "bfc",    "le",      "letp",    "asrl",    "lsll",    "lsrl",     "sqrshrl", "sqshll",
    "srshrl",  "uqrshll", "uqshll", "urshrl",  "sqrshr",  "sqshl",   "srshr",   "uqrshl",   "uqshl",   "urshr",
    "vshlc",   "vabav",   "vmaxv",  "vmaxav",  "vminv",   "vminav",  "vmaxnmv", "vmaxnmav", "vminnmv", "vminnmav",
    "smlal",   "umlal",   "umaal",  "smlalbb", "smlalbt", "smlaltb", "smlaltt", "smlald",   "smlaldx", "smlsld",
    "smlsldx",
};
const links = [_][]const u8{ "bl", "blx", "blxns" };

const written_lane: u64 = 1;
const source_lane: u64 = 1 << 16;
const address_lane: u64 = 1 << 32;

const Pending = struct { register: Register, lanes: u64, conditional: bool };

const Built = struct {
    lanes: [4]u64 = @splat(0),
    shift: [4]u5 = @splat(0),
    mask: [4]u8 = @splat(0),
    held: [4]bool = @splat(false),
    split: u5 = 0,
    split_mask: u8 = 0,
    keep: u64 = ~@as(u64, 0),
    writeback: u5 = 0,
    writeback_mask: u8 = 0,
    writeback_at: u6 = 0,
    list: u32 = 0,
    list_high: u32 = 0,
    list_shift: u5 = 0,
    list_lane: u6 = 0,
    fixed: u64 = 0,
};

fn entry(w: *std.Io.Writer, r: spec.Row, text: []const u8, class: []const u8) !void {
    const ops = try operands(r, text);
    var b: Built = .{};
    var pending: [12]Pending = undefined;
    var n: usize = 0;
    for (ops.slice()) |o| {
        const conditional = o.written == .w_field;
        if (o.written == .unlisted and !writesList(ops.slice())) return error.UnlistedWithoutList;
        const lanes = (if (o.written == .yes or o.written == .unlisted) written_lane else 0) |
            (if (o.read and !o.accumulator) source_lane else 0) |
            (if (o.addressed) address_lane else 0);
        if (lanes == 0 and !conditional) continue;
        switch (o.register) {
            .list => {
                try list(&b, r, lanes);
                continue;
            },
            .fixed => |register| if (!conditional) {
                b.fixed |= lanes << register;
                continue;
            },
            .field => {},
        }
        pending[n] = .{ .register = o.register, .lanes = lanes, .conditional = conditional };
        n += 1;
    }
    for (pending[0..n]) |p| if (p.conditional) try place(&b, r, p, 1);
    for (pending[0..n]) |p| if (!p.conditional and special(r, p)) try place(&b, r, p, 0);
    for (pending[0..n]) |p| if (!p.conditional and !special(r, p)) try place(&b, r, p, null);

    try w.print("    .{{ .class = .{s}", .{class});
    if (std.mem.indexOfScalar(bool, &b.held, true) != null) {
        try w.print(", .lanes = .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }}", .{ b.lanes[0], b.lanes[1], b.lanes[2], b.lanes[3] });
        try w.print(", .shift = .{{ {d}, {d}, {d}, {d} }}", .{ b.shift[0], b.shift[1], b.shift[2], b.shift[3] });
        try w.print(", .mask = .{{ {d}, {d}, {d}, {d} }}", .{ b.mask[0], b.mask[1], b.mask[2], b.mask[3] });
    }
    inline for (.{ "split", "split_mask", "writeback", "writeback_mask", "writeback_at", "list", "list_high", "list_shift", "list_lane", "fixed" }) |name| {
        if (@field(b, name) != 0) try w.print(", .{s} = 0x{x}", .{ name, @field(b, name) });
    }
    if (b.keep != ~@as(u64, 0)) try w.print(", .keep = 0x{x}", .{b.keep});
    try w.writeAll(" },\n");
}

fn special(r: spec.Row, p: Pending) bool {
    const f = p.register.field;
    return dropsR15(r, f) or runsOf(r.field(f.letter).?).len > 1;
}

fn dropsR15(r: spec.Row, f: FieldRegister) bool {
    const top = (@as(u32, 1) << @intCast(r.field(f.letter).?.width)) - 1;
    return f.none_at_15 and 15 >= f.offset and (15 - f.offset) % f.scale == 0 and (15 - f.offset) / f.scale <= top;
}

fn list(b: *Built, r: spec.Row, lanes: u64) !void {
    const low = r.field('r').?;
    if (low.positions[0] != low.width - 1 or runsOf(low).len != 1) return error.ListNotLow;
    b.list = (@as(u32, 1) << @intCast(low.width)) - 1;
    if (r.field('l')) |high| {
        if (high.width != 1 or high.positions[0] > 14) return error.ListHigh;
        b.list_high = @as(u32, 1) << @intCast(high.positions[0]);
        b.list_shift = @intCast(14 - high.positions[0]);
    }
    b.list_lane = if (lanes == written_lane) 0 else if (lanes == source_lane) 16 else return error.ListRoles;
    if (std.mem.eql(u8, r.class, "pop_pc")) b.fixed |= lanes << 15;
}

fn place(b: *Built, r: spec.Row, p: Pending, at: ?usize) !void {
    const offset: u6 = switch (p.register) {
        .fixed => |register| register,
        .field => |f| @intCast(f.offset),
        .list => unreachable,
    };
    const k = at orelse std.mem.indexOfScalar(bool, &b.held, false) orelse return error.TooManyOperands;
    if (b.held[k]) return error.OperandPlaceTaken;
    b.held[k] = true;
    b.lanes[k] = p.lanes << offset;
    if (p.conditional) {
        const bit = r.field('w') orelse return error.NoWritebackField;
        if (bit.width != 1) return error.WritebackWidth;
        b.writeback = @intCast(bit.positions[0]);
        b.writeback_mask = 1;
        b.writeback_at = offset;
    }
    const f = switch (p.register) {
        .field => |f| f,
        else => return,
    };
    const field = r.field(f.letter).?;
    if (((@as(u32, 1) << @intCast(field.width)) - 1) * f.scale + f.offset > 15) return error.PastR15;
    const scale: u5 = if (f.scale == 1) 0 else if (f.scale == 2) 1 else return error.Scale;
    const runs = runsOf(field);
    const low = runs.items[runs.len - 1];
    if (low.lsb < scale) return error.ScaleBelowBitZero;
    b.shift[k] = @intCast(low.lsb - scale);
    b.mask[k] = @intCast(((@as(u32, 1) << low.len) - 1) << scale);
    if (runs.len > 1) {
        const high = runs.items[0];
        if (k != 0 or runs.len > 2 or scale != 0 or high.lsb < low.len) return error.Split;
        b.split = @intCast(high.lsb - low.len);
        b.split_mask = @intCast(((@as(u32, 1) << high.len) - 1) << low.len);
    }
    if (dropsR15(r, f)) {
        if (k != 0) return error.KeepNotFirst;
        b.keep = ~(p.lanes << 15);
    }
}

const Run = struct { lsb: u5, len: u5 };
const Runs = struct { items: [8]Run = undefined, len: usize = 0 };

fn runsOf(field: spec.Field) Runs {
    var out: Runs = .{};
    var at: usize = 0;
    while (at < field.positions.len) {
        var end = at + 1;
        while (end < field.positions.len and field.positions[end] == field.positions[end - 1] - 1) end += 1;
        out.items[out.len] = .{ .lsb = @intCast(field.positions[end - 1]), .len = @intCast(end - at) };
        out.len += 1;
        at = end;
    }
    return out;
}

fn writesList(ops: []const Operand) bool {
    for (ops) |o| if (o.register == .list and o.written == .yes) return true;
    return false;
}

fn operands(r: spec.Row, text: []const u8) !Operands {
    var out: Operands = .{};
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return out;
    const mnemonic = mnemonicOf(text[0..space]);
    const store = std.mem.startsWith(u8, r.class, "store") or std.mem.eql(u8, r.class, "push");
    const load = std.mem.startsWith(u8, r.class, "load") or std.mem.startsWith(u8, r.class, "pop");
    const multiply = std.mem.eql(u8, r.class, "multiply");
    const reads_destination = among(&updates, mnemonic) or (among(&two_address, mnemonic) and topLevel(text[space..]) == 2);

    var k: usize = 0;
    var inside = false;
    var bracket: usize = 0;
    var leading: usize = 0;
    var first_written = false;
    var based = false;
    var i = space + 1;
    while (i < text.len) {
        const rest = text[i..];
        if (rest[0] == ',' and !inside) {
            k += 1;
            i += 1;
            continue;
        }
        if (rest[0] == '[') {
            inside = true;
            bracket = out.len;
            i += 1;
            continue;
        }
        if (rest[0] == ']' or std.mem.startsWith(u8, rest, "{index}")) {
            inside = false;
            if (out.len > bracket) {
                const after = if (rest[0] == ']') rest[1..] else "!";
                const base = &out.items[bracket];
                if (std.mem.startsWith(u8, after, "!") or std.mem.startsWith(u8, after, ", ")) base.written = .yes;
                if (std.mem.startsWith(u8, after, "{wb}")) base.written = .w_field;
            }
            i += if (rest[0] == ']') 1 else "{index}".len;
            continue;
        }
        const found = try registerAt(r, text, i) orelse {
            i += if (rest[0] == '{') std.mem.indexOfScalar(u8, rest, '}').? + 1 else 1;
            continue;
        };
        i += found.len;
        if (found.register == .list) {
            out.add(.{ .register = .list, .read = store, .written = if (store) .no else .yes });
            continue;
        }
        if (inside) {
            out.add(.{ .register = found.register, .read = true, .addressed = true });
            continue;
        }
        const after = text[i..];
        if (std.mem.startsWith(u8, after, "{wb}") or std.mem.startsWith(u8, after, "!")) {
            const written: Written = if (after[0] == '!') .yes else if (r.field('w') != null) .w_field else .unlisted;
            out.add(.{ .register = found.register, .read = true, .addressed = true, .written = written });
            based = true;
            continue;
        }
        const letter: u8 = switch (found.register) {
            .field => |f| f.letter,
            else => 0,
        };
        const paired = switch (found.register) {
            .field => |f| letter == 'h' or letter == 'e' or f.scale != 1,
            else => false,
        };
        var o: Operand = .{ .register = found.register };
        if (store) {
            if (letter == 'd') o.written = .yes else o.read = true;
        } else if (load) {
            o.written = .yes;
        } else {
            const destination = (k == 0 and !among(&no_destination, mnemonic)) or
                (k == 1 and first_written and paired) or
                (leading == 0 and among(&updates, mnemonic));
            if (destination) o.written = .yes;
            o.read = !destination or reads_destination;
            o.accumulator = multiply and o.read and (destination or (letter == 'a' and k == 3));
        }
        if (k == 0 and o.written == .yes) first_written = true;
        leading += 1;
        out.add(o);
    }
    if ((std.mem.eql(u8, r.class, "push") or std.mem.startsWith(u8, r.class, "pop")) and !based)
        out.add(.{ .register = .{ .fixed = 13 }, .read = true, .written = .yes, .addressed = true });
    if (among(&links, mnemonic)) out.add(.{ .register = .{ .fixed = 14 }, .written = .yes });
    return out;
}

const Found = struct { register: Register, len: usize };

fn registerAt(r: spec.Row, text: []const u8, i: usize) !?Found {
    const rest = text[i..];
    const before: u8 = if (i == 0) ' ' else text[i - 1];
    if (std.mem.startsWith(u8, rest, "{regs}")) return .{ .register = .list, .len = "{regs}".len };
    if (std.mem.startsWith(u8, rest, "{fpdest}")) return .{ .register = .{ .field = .{ .letter = 't', .none_at_15 = true } }, .len = "{fpdest}".len };
    if (std.ascii.isAlphabetic(before)) return null;
    if (std.mem.startsWith(u8, rest, "r{")) return try expression(r, rest, 2, false);
    if (std.mem.startsWith(u8, rest, "{z") and rest.len > 2 and std.ascii.isAlphabetic(rest[2])) return try expression(r, rest, 2, true);
    if (before != ' ' and before != '[') return null;
    for ([_][]const u8{ "sp", "lr", "pc" }, 13..) |word, n| {
        if (!std.mem.startsWith(u8, rest, word)) continue;
        if (rest.len > 2 and std.mem.indexOfScalar(u8, ",]{!", rest[2]) == null) continue;
        return .{ .register = .{ .fixed = @intCast(n) }, .len = 2 };
    }
    return null;
}

fn expression(r: spec.Row, rest: []const u8, open: usize, none_at_15: bool) !Found {
    const close = std.mem.indexOfScalar(u8, rest, '}').?;
    const inner = rest[open..close];
    const star = std.mem.indexOfScalar(u8, inner, '*');
    const plus = std.mem.indexOfScalar(u8, inner, '+');
    const letters = inner[0 .. star orelse plus orelse inner.len];
    if (letters.len != 1 or r.field(letters[0]) == null) return error.UnhandledKey;
    const scale = if (star) |at| try std.fmt.parseInt(u32, inner[at + 1 .. plus orelse inner.len], 10) else 1;
    const offset = if (plus) |at| try std.fmt.parseInt(u32, inner[at + 1 ..], 10) else 0;
    return .{ .register = .{ .field = .{ .letter = letters[0], .scale = scale, .offset = offset, .none_at_15 = none_at_15 } }, .len = close + 1 };
}

fn mnemonicOf(word: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, word, ".{") orelse word.len;
    return word[0..end];
}

fn topLevel(operands_text: []const u8) usize {
    var n: usize = 1;
    var inside = false;
    for (operands_text) |c| switch (c) {
        '[' => inside = true,
        ']' => inside = false,
        ',' => n += @intFromBool(!inside),
        else => {},
    };
    return n;
}

fn among(set: []const []const u8, word: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, word)) return true;
    return false;
}
