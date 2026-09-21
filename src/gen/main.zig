//! Entry point of the offline generator. Loads every row of each architecture through spec.zig,
//! keeps the rows the requested presets reach, proves them disjoint, builds one decision tree per
//! instruction width, proves each tree total, and writes the decode, disasm and meta files for
//! the arm and riscv architectures. Arguments: output directory, comma-separated preset names,
//! and a shape, union for one tree gated at its leaves or split for one tree per preset.

const std = @import("std");
const spec = @import("spec.zig");
const tree = @import("tree.zig");
const prove = @import("prove.zig");
const emit_decode = @import("emit_decode.zig");
const emit_disasm = @import("emit_disasm.zig");
const emit_meta = @import("emit_meta.zig");

const Preset = struct { name: []const u8, groups: []const []const u8 };

const arm_presets = [_]Preset{
    .{ .name = "v7m", .groups = &.{ "v6m", "v7m", "main" } },
    .{ .name = "v6m", .groups = &.{"v6m"} },
    .{ .name = "v8mbase", .groups = &.{ "v6m", "v7m", "v8m" } },
    .{ .name = "v81mmain", .groups = &.{ "v6m", "v7m", "main", "dsp", "v8m", "v8m_main", "v8_1m", "mve" } },
};

const riscv_presets = [_]Preset{
    .{ .name = "rv32imafc", .groups = &.{ "rv32i", "m", "a", "c", "zicsr", "f" } },
    .{ .name = "rv32imc", .groups = &.{ "rv32i", "m", "c", "zicsr" } },
    .{ .name = "rv32imac", .groups = &.{ "rv32i", "m", "a", "c", "zicsr" } },
    .{ .name = "rv32i", .groups = &.{"rv32i"} },
};

const Shape = enum { @"union", split };

const arm_groups = [_][]const u8{ "v6m", "v7m", "main", "dsp", "v8m", "v8m_main", "v8_1m", "mve" };
const riscv_groups = [_][]const u8{ "rv32i", "m", "a", "c", "zicsr", "f" };

const Architecture = struct {
    name: []const u8,
    arch: emit_disasm.Arch,
    rows: []const spec.schema.Row,
    sem: []const u8,
    presets: []const Preset,
    groups: []const []const u8,
};

/// Generates decode, disassembly and meta files for both architectures from the arguments.
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next();
    const out_dir = args.next() orelse "src/generated";
    const wanted = try split(gpa, args.next() orelse "v7m");
    const shape = std.meta.stringToEnum(Shape, args.next() orelse "union") orelse return error.NoSuchShape;
    for (wanted) |name| {
        if (named(&arm_presets, name) == null) {
            std.debug.print("error: no preset called {s}\n", .{name});
            std.process.exit(1);
        }
    }

    const architectures = [_]Architecture{
        .{ .name = "arm", .arch = .arm, .rows = spec.arm_rows, .sem = "arm", .presets = &arm_presets, .groups = &arm_groups },
        .{ .name = "riscv", .arch = .riscv, .rows = spec.riscv_rows, .sem = "riscv", .presets = &riscv_presets, .groups = &riscv_groups },
    };

    for (architectures) |a| {
        const chosen = try pick(gpa, a.presets, wanted);
        const all = try spec.load(gpa, a.rows);
        const groups = a.groups;
        for (all) |r| {
            if (bitOf(groups, r.group) == 0) {
                std.debug.print("error: {s} names group {s}, which the host order does not carry\n", .{ r.name, r.group });
                std.process.exit(1);
            }
        }

        const masks = try gpa.alloc(u32, chosen.len);
        var reach: u32 = 0;
        for (chosen, masks) |p, *m| {
            m.* = maskOf(groups, p.groups);
            reach |= m.*;
        }

        var rows: std.ArrayList(spec.Row) = .empty;
        for (all) |r| if (bitOf(groups, r.group) & reach != 0) try rows.append(gpa, r);
        if (prove.disjoint(rows.items)) |bad| {
            std.debug.print("error: {s} and {s} can both match one code\n", .{ bad.a, bad.b });
            std.process.exit(1);
        }

        const gates = try gpa.alloc(u32, rows.items.len);
        for (rows.items, gates) |r, *g| {
            const bit = bitOf(groups, r.group);
            g.* = for (masks) |m| {
                if (bit & m == 0) break bit;
            } else 0;
        }

        var narrow: std.ArrayList(tree.Node) = .empty;
        var wide: std.ArrayList(tree.Node) = .empty;
        for (if (shape == .split) masks else masks[0..1], 0..) |m, k| {
            const members = try gpa.alloc(bool, rows.items.len);
            for (rows.items, members) |r, *in| in.* = shape == .@"union" or bitOf(groups, r.group) & m != 0;
            try narrow.append(gpa, try tree.build(gpa, rows.items, 16, members));
            try wide.append(gpa, try tree.build(gpa, rows.items, 32, members));
            for ([_]struct { tree.Node, u8 }{ .{ narrow.items[k], 16 }, .{ wide.items[k], 32 } }) |pair| {
                if (try prove.total(gpa, pair[0], rows.items, pair[1], members)) |hole| {
                    std.debug.print("error: {s} tree at width {d} answers {d} where a scan finds {d} rows (known {x}/{x})\n", .{ a.name, pair[1], hole.leaf, hole.candidates, hole.known_value, hole.known_mask });
                    std.process.exit(1);
                }
            }
        }

        const word = if (shape == .split) masks.len > 1 else std.mem.indexOfNone(u32, gates, &.{0}) != null;
        for ([_][]const u8{ "decode", "disasm", "meta" }) |file| {
            try writeFile(init, gpa, out_dir, a.name, file, rows.items, gates, narrow.items, wide.items, masks, word, a);
        }
    }
}

fn split(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| try out.append(gpa, part);
    return out.items;
}

fn named(catalogue: []const Preset, name: []const u8) ?Preset {
    for (catalogue) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn pick(gpa: std.mem.Allocator, catalogue: []const Preset, wanted: []const []const u8) ![]const Preset {
    var out: std.ArrayList(Preset) = .empty;
    for (wanted) |name| {
        if (named(catalogue, name)) |p| try out.append(gpa, p);
    }
    return if (out.items.len == 0) catalogue else out.items;
}

fn bitOf(groups: []const []const u8, group: []const u8) u32 {
    for (groups, 0..) |g, i| if (std.mem.eql(u8, g, group)) return @as(u32, 1) << @intCast(i);
    return 0;
}

fn maskOf(groups: []const []const u8, wanted: []const []const u8) u32 {
    var out: u32 = 0;
    for (wanted) |g| out |= bitOf(groups, g);
    return out;
}

const Emit = enum { index, execute };

fn quota(w: *std.Io.Writer, rows: []const spec.Row) !void {
    try w.print("    @setEvalBranchQuota({d});\n", .{rows.len * 100});
}

fn family(
    w: *std.Io.Writer,
    name: []const u8,
    doc: []const u8,
    params: []const u8,
    call: []const u8,
    undef: []const u8,
    emit: Emit,
    nodes: []const tree.Node,
    rows: []const spec.Row,
    gates: []const u32,
    masks: []const u32,
) !void {
    if (nodes.len == 1) {
        try w.print("/// {s}\npub fn {s}{s} {{\n", .{ doc, name, params });
        try quota(w, rows);
        try body(w, emit, nodes[0], rows, gates);
        return w.writeAll("}\n");
    }
    for (nodes, 0..) |node, i| {
        try w.print("fn {s}{d}{s} {{\n", .{ name, i, params });
        try quota(w, rows);
        try body(w, emit, node, rows, gates);
        try w.writeAll("}\n\n");
    }
    try w.print("/// {s}\npub fn {s}{s} {{\n    return switch (allowed) {{\n", .{ doc, name, params });
    for (masks, 0..) |m, i| try w.print("        {d} => {s}{d}{s},\n", .{ m, name, i, call });
    try w.print("        else => {s},\n    }};\n}}\n", .{undef});
}

fn body(w: *std.Io.Writer, emit: Emit, node: tree.Node, rows: []const spec.Row, gates: []const u32) !void {
    return switch (emit) {
        .index => emit_decode.indexTree(w, node, rows, gates, 1),
        .execute => emit_decode.executeTree(w, node, rows, gates, 1),
    };
}

fn writeFile(
    init: std.process.Init,
    gpa: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    file: []const u8,
    rows: []const spec.Row,
    gates: []const u32,
    narrow: []const tree.Node,
    wide: []const tree.Node,
    masks: []const u32,
    word: bool,
    a: Architecture,
) !void {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    const w = &buffer.writer;

    try w.print("//! Generated by src/gen from spec/*.zon for the {s} architecture. Do not hand-edit; the build emits it.\n", .{name});
    if (std.mem.eql(u8, file, "decode")) {
        try w.writeAll("//! The decode tree: the index functions map a code to its row index and the execute functions\n//! dispatch a code to the row's semantic handler with operands extracted from the code.\n\n");
        try w.print("const sem = @import(\"isa\").sem.{s};\n", .{a.sem});
        try w.writeAll("const State = sem.State;\n/// Bit set of the groups a call answers for, one bit per group.\npub const Groups = sem.Groups;\n/// The index answered for a code no row of the group set claims.\npub const undefined_index: u32 = 0xffff_ffff;\n\n");
        const execute = if (word)
            "(comptime Host: type, s: *State, host: *Host, code: u32, allowed: Groups) sem.Done"
        else
            "(comptime Host: type, s: *State, host: *Host, code: u32, _: Groups) sem.Done";
        const lookup = if (word) "(code: u32, allowed: Groups) u32" else "(code: u32, _: Groups) u32";
        try family(w, "indexNarrow", "Row index of a 16-bit code under a group set, or undefined_index.", lookup, "(code, allowed)", "undefined_index", .index, narrow, rows, gates, masks);
        try w.writeAll("\n");
        try family(w, "indexWide", "Row index of a 32-bit code under a group set, or undefined_index.", lookup, "(code, allowed)", "undefined_index", .index, wide, rows, gates, masks);
        try w.writeAll("\n");
        try family(w, "executeNarrow", "Executes a 16-bit code against the state and host; unclaimed when no allowed row matches.", execute, "(Host, s, host, code, allowed)", ".{}", .execute, narrow, rows, gates, masks);
        try w.writeAll("\n");
        try family(w, "executeWide", "Executes a 32-bit code against the state and host; unclaimed when no allowed row matches.", execute, "(Host, s, host, code, allowed)", ".{}", .execute, wide, rows, gates, masks);
    } else if (std.mem.eql(u8, file, "disasm")) {
        try w.writeAll("//! The disassembler: renders a code at a program counter as its row's template text, aliases first.\n\n");
        try w.print("const std = @import(\"std\");\nconst sem = @import(\"isa\").sem.{s};\n", .{a.sem});
        try w.writeAll("const target = sem.target;\n");
        if (a.arch == .arm) {
            try w.writeAll("const expandImm = sem.expandImm;\n");
            try w.writeAll("const expandedWord = sem.expandedWord;\n");
            try w.writeAll("const expandFloat = sem.fp.lib.expandImm;\n");
            try w.writeAll(emit_disasm.helpers);
            try w.writeByte('\n');
        } else try w.writeAll("const abi = sem.abi;\nconst fpabi = sem.fpabi;\nconst rounding = sem.rounding;\nconst primed = sem.primed;\nconst sext = sem.sext;\nconst writeCsr = sem.writeCsr;\n");
        try w.print("const decode = @import(\"{s}_decode\");\n", .{name});
        try w.writeAll("\n/// Writes the disassembly of code at pc under a group set, or `undefined` for a code no row claims.\npub fn write(w: *std.Io.Writer, code: u32, pc: u32, groups: decode.Groups) std.Io.Writer.Error!void {\n");
        try w.writeAll("    switch (index(code, groups)) {\n");
        for (rows, 0..) |r, i| {
            try w.print("        {d} => {{\n", .{i});
            try emit_disasm.row(w, a.arch, r, 3);
            try w.writeAll("        },\n");
        }
        try w.writeAll("        else => try w.writeAll(\"undefined\"),\n    }\n}\n\n");
        try w.writeAll("fn index(code: u32, groups: decode.Groups) u32 {\n    return if (");
        try w.writeAll(if (a.arch == .arm) "code > 0xffff" else "code & 3 == 3");
        try w.writeAll(") decode.indexWide(code, groups) else decode.indexNarrow(code, groups);\n}\n");
    } else {
        try w.writeAll("//! Row counts and names, indexed like the decoder's leaves.\n\n");
        try emit_meta.write(w, rows, a.rows.len);
    }

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}_{s}.zig", .{ dir, name, file });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = buffer.written() });
}
