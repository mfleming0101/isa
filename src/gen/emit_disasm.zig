//! Emits one disassembly arm per row from the row's text template. Every `{key}` in a template is
//! rendered by `key`, which knows each operand form the spec uses: registers, immediates with scale
//! and offset, shifts, register lists, fences and RISC-V ABI names. A template using a key this
//! file does not handle fails generation instead of printing wrong text. Aliases are tried first,
//! each guarded by the field value that selects it.

const std = @import("std");
const spec = @import("spec.zig");
const emit_decode = @import("emit_decode.zig");

/// Which architecture's operand conventions a template is rendered with.
pub const Arch = enum { arm, riscv };

/// Emits the alias checks and then the main template of one row at the given indent.
pub fn row(w: *std.Io.Writer, arch: Arch, r: spec.Row, depth: usize) !void {
    for (r.aliases) |a| {
        try pad(w, depth);
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field(a.letter) orelse return error.UnhandledKey);
        try w.print(" == {d}) {{\n", .{a.value});
        try expand(w, arch, r, a.text, depth + 1);
        try pad(w, depth + 1);
        try w.writeAll("return;\n");
        try pad(w, depth);
        try w.writeAll("}\n");
    }
    try expand(w, arch, r, r.text, depth);
}

fn expand(w: *std.Io.Writer, arch: Arch, r: spec.Row, source: []const u8, depth: usize) !void {
    var at: usize = 0;
    while (at < source.len) {
        const open = std.mem.indexOfScalarPos(u8, source, at, '{') orelse {
            try literal(w, source[at..], depth);
            return;
        };
        const register = arch == .arm and namesRegister(source, open);
        const end = open - @intFromBool(register);
        if (end != at) try literal(w, source[at..end], depth);
        const close = std.mem.indexOfScalarPos(u8, source, open, '}').?;
        try key(w, arch, r, source[open + 1 .. close], register, depth);
        at = close + 1;
    }
}

fn namesRegister(source: []const u8, open: usize) bool {
    if (open == 0 or source[open - 1] != 'r') return false;
    return open == 1 or !std.ascii.isAlphabetic(source[open - 2]);
}

fn literal(w: *std.Io.Writer, text: []const u8, depth: usize) !void {
    try pad(w, depth);
    try w.print("try w.writeAll(\"{f}\");\n", .{std.zig.fmtString(text)});
}

fn key(w: *std.Io.Writer, arch: Arch, r: spec.Row, name: []const u8, register: bool, depth: usize) !void {
    try pad(w, depth);
    if (std.mem.eql(u8, name, "pc")) {
        try w.print("try w.print(\"0x{{x}}\", .{{target.@\"{s}\"(pc", .{r.name});
        for (r.fields) |f| {
            try w.writeAll(", ");
            try emit_decode.operand(w, f);
        }
        try w.writeAll(")});\n");
        return;
    }
    if (std.mem.eql(u8, name, "s")) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('s').?);
        try w.writeAll(" != 0) try w.writeByte('s');\n");
        return;
    }
    if (std.mem.eql(u8, name, "amount")) {
        try w.writeAll("try w.print(\"{d}\", .{amountOf(");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")});\n");
        return;
    }
    if (std.mem.eql(u8, name, "const")) {
        try w.writeAll("try w.print(\"{d}\", .{expandImm(");
        try emit_decode.operand(w, r.field('i').?);
        try w.writeAll(")});\n");
        return;
    }
    if (arch == .arm and (std.mem.eql(u8, name, "f16") or std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64"))) {
        try w.print("try w.print(\"{{d}}\", .{{@as({s}, @bitCast(expandFloat({s}, ", .{ name, name });
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")))});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "barrier")) {
        try w.writeAll("try writeBarrier(w, ");
        try emit_decode.operand(w, r.field('o') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .riscv and name.len == 1 and std.mem.indexOfScalar(u8, "DNMS", name[0]) != null) {
        const f = r.field(name[0]) orelse return error.UnhandledKey;
        try w.writeAll("try w.writeAll(fpabi[");
        if (f.width == 3) try w.writeAll("primed(");
        try emit_decode.operand(w, f);
        try w.writeAll(if (f.width == 3) ")]);\n" else "]);\n");
        return;
    }
    if (arch == .riscv and std.mem.eql(u8, name, "rm")) {
        try w.writeAll("try w.writeAll(rounding[");
        try emit_decode.operand(w, r.field('r') orelse return error.UnhandledKey);
        try w.writeAll("]);\n");
        return;
    }
    if (name.len == 1 and std.mem.indexOfScalar(u8, "dntm", name[0]) != null) {
        if (arch == .arm) {
            try number(w, r.field(name[0]).?, register, null, null);
        } else {
            const f = r.field(name[0]).?;
            try w.writeAll("try w.writeAll(abi[");
            if (f.width == 3) try w.writeAll("primed(");
            try emit_decode.operand(w, f);
            try w.writeAll(if (f.width == 3) ")]);\n" else "]);\n");
        }
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "lsl")) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('y') orelse return error.UnhandledKey);
        try w.writeAll(" != 0) try w.print(\", lsl #{d}\", .{");
        try emit_decode.operand(w, r.field('y').?);
        try w.writeAll("});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "asr")) {
        try w.writeAll("try w.print(\", asr #{d}\", .{amountOf(");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "sat")) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(" != 0) try w.print(\", lsl #{d}\", .{");
        try emit_decode.operand(w, r.field('i').?);
        try w.writeAll("});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "sign")) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('u') orelse return error.UnhandledKey);
        try w.writeAll(" == 0) try w.writeByte('-');\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "width")) {
        try w.writeAll("try w.print(\"{d}\", .{(");
        try emit_decode.operand(w, r.field('b') orelse return error.UnhandledKey);
        try w.writeAll(" + 1) -% (");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "index")) {
        try w.writeAll("try writeIndex(w, ");
        try emit_decode.operand(w, r.field('p') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('u').?);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('i').?);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "sysm")) {
        try w.writeAll("try writeSpecial(w, ");
        try emit_decode.operand(w, r.field('m') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        if (r.field('a')) |f| try emit_decode.operand(w, f) else try w.writeAll("2");
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "block")) {
        try w.writeAll("try writeItBlock(w, ");
        try emit_decode.operand(w, r.field('c') orelse return error.UnhandledKey);
        try w.writeAll(", code & 0xf);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "cond")) {
        try w.print("try w.writeAll(([_][]const u8{{ {s} }})[", .{condition_names});
        try emit_decode.operand(w, r.field('c') orelse return error.UnhandledKey);
        try w.writeAll("]);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "hint")) {
        try w.writeAll("try writeHint(w, ");
        try emit_decode.operand(w, r.field('h') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "cs")) {
        try w.writeAll("try w.writeAll(([_][]const u8{ \"csel\", \"csinc\", \"csinv\", \"csneg\" })[");
        try emit_decode.operand(w, r.field('k') orelse return error.UnhandledKey);
        try w.writeAll("]);\n");
        return;
    }
    if (arch == .arm and (std.mem.eql(u8, name, "amount") or std.mem.eql(u8, name, "vshlc"))) {
        try w.writeAll("try w.print(\"{d}\", .{amountOf(");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "limit")) {
        try w.writeAll("try w.print(\"{d}\", .{@as(u32, if (");
        try emit_decode.operand(w, r.field('q') orelse return error.UnhandledKey);
        try w.writeAll(" == 0) 64 else 48)});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vshr")) {
        try w.writeAll("try writeVectorShift(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vaddv")) {
        try w.writeAll("try writeVectorAcross(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vmlav")) {
        try w.writeAll("try writeVectorProducts(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vshll")) {
        try w.writeAll("try writeVectorWiden(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vshrn")) {
        try w.writeAll("try writeVectorNarrow(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vimm")) {
        try w.writeAll("try writeVectorConstant(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vidup")) {
        try w.writeAll("try w.print(\"{d}\", .{@as(u32, 1) << @intCast(");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vldst")) {
        try w.writeAll("try writeVectorMemory(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vgather")) {
        try w.writeAll("try writeVectorGather(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "group")) {
        try w.writeAll("try writeVectorGroup(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vorr")) {
        try w.writeAll("try writeVectorOrr(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vpt")) {
        try w.writeAll("try writeVectorCompare(w, code);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vpst")) {
        try w.writeAll("try writeVectorBlock(w, code, \"vpst\", \"vpnot\");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "elt")) {
        try w.writeAll("try w.print(\"{d}\", .{@as(u32, 8) << @intCast(code >> 20 & 3)});\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "bf")) {
        try w.writeAll("try writeBranchFuture(w, code, pc);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "fpdest")) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('t') orelse return error.UnhandledKey);
        try w.print(" == 15) try w.writeAll(\"APSR_nzcv\") else try w.writeAll(([_][]const u8{{ {s} }})[", .{register_names});
        try emit_decode.operand(w, r.field('t').?);
        try w.writeAll("]);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "fpregs")) {
        try w.writeAll("try writeSingles(w, (");
        try emit_decode.operand(w, r.field('d') orelse return error.UnhandledKey);
        try w.writeAll(" << 1) | ");
        try emit_decode.operand(w, r.field('y') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "sysreg")) {
        try w.writeAll("try w.writeAll(([_][]const u8{ \"vpr\", \"p0\", \"fpcxtns\", \"fpcxts\" })[");
        try emit_decode.operand(w, r.field('k') orelse return error.UnhandledKey);
        try w.writeAll("]);\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "vprregs")) {
        try w.writeAll("try writeVprRegs(w, code, ");
        try emit_decode.operand(w, r.field('d') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('y') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "dpregs")) {
        try w.writeAll("try writeDoubles(w, ");
        try emit_decode.operand(w, r.field('d') orelse return error.UnhandledKey);
        try w.writeAll(", ");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (arch == .arm and std.mem.eql(u8, name, "fbits")) {
        try w.writeAll("try w.print(\"{d}\", .{(if ((code >> 7) & 1 == 1) @as(i32, 32) else 16) - (@as(i32, @intCast(");
        try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
        try w.writeAll(")) << 1 | @as(i32, @intCast(");
        try emit_decode.operand(w, r.field('j') orelse return error.UnhandledKey);
        try w.writeAll(")))});\n");
        return;
    }
    if (arch == .arm and name.len > 1 and name[0] == 'z' and name[1] != ':') return armZero(w, r, name[1..]);
    if (arch == .arm and std.mem.eql(u8, name, "regs")) return armRegs(w, r, depth);
    if (arch == .arm and std.mem.eql(u8, name, "wb")) {
        try w.writeAll("if (");
        if (r.field('w')) |f| {
            try emit_decode.operand(w, f);
            try w.writeAll(" != 0");
        } else {
            try w.writeAll("(");
            try emit_decode.operand(w, r.field('r') orelse return error.UnhandledKey);
            try w.writeAll(" >> @intCast(");
            try emit_decode.operand(w, r.field('n') orelse return error.UnhandledKey);
            try w.writeAll(")) & 1 == 0");
        }
        try w.writeAll(") try w.writeByte('!');\n");
        return;
    }
    return switch (arch) {
        .arm => if (std.mem.eql(u8, name, "shift")) armShift(w, r, depth) else armImmediate(w, r, name, register),
        .riscv => if (std.mem.eql(u8, name, "fence")) riscvFence(w, r, depth) else riscvImmediate(w, r, name),
    };
}

fn armZero(w: *std.Io.Writer, r: spec.Row, name: []const u8) !void {
    const star = std.mem.indexOfScalar(u8, name, '*');
    const plus = std.mem.indexOfScalar(u8, name, '+');
    const letters = name[0 .. star orelse plus orelse name.len];
    if (letters.len != 1) return error.UnhandledKey;
    const f = r.field(letters[0]) orelse return error.UnhandledKey;
    try w.writeAll("try writeZero(w, ");
    try emit_decode.operand(w, f);
    if (star) |at| try w.print(" * {s}", .{name[at + 1 .. plus orelse name.len]});
    if (plus) |at| try w.print(" + {s}", .{name[at + 1 ..]});
    try w.writeAll(");\n");
}

fn armRegs(w: *std.Io.Writer, r: spec.Row, depth: usize) !void {
    try w.writeAll("{\n");
    try pad(w, depth + 1);
    try w.writeAll("const list = ");
    try emit_decode.operand(w, r.field('r') orelse return error.UnhandledKey);
    if (r.field('l')) |l| {
        try w.writeAll(" | (");
        try emit_decode.operand(w, l);
        try w.writeAll(" << 14)");
    }
    if (std.mem.eql(u8, r.class, "pop_pc")) try w.writeAll(" | 0x8000");
    try w.writeAll(";\n");
    try pad(w, depth + 1);
    try w.writeAll("const apsr = ");
    if (r.field('a')) |a| try emit_decode.operand(w, a) else try w.writeAll("0");
    try w.writeAll(";\n");
    try pad(w, depth + 1);
    try w.print("const names = [_][]const u8{{ {s} }};\n", .{register_names});
    try block(w, depth + 1, regs_body);
    try pad(w, depth);
    try w.writeAll("}\n");
}

const regs_body =
    \\try w.writeByte('{');
    \\var first = true;
    \\for (0..16) |i| {
    \\    if (list >> @as(u5, @intCast(i)) & 1 == 0) continue;
    \\    if (!first) try w.writeAll(", ");
    \\    first = false;
    \\    try w.writeAll(names[i]);
    \\}
    \\if (apsr == 1) {
    \\    if (!first) try w.writeAll(", ");
    \\    try w.writeAll("apsr");
    \\}
    \\try w.writeByte('}');
;

fn armImmediate(w: *std.Io.Writer, r: spec.Row, name: []const u8, register: bool) !void {
    const star = std.mem.indexOfScalar(u8, name, '*');
    const plus = std.mem.indexOfScalar(u8, name, '+');
    const letters = name[0 .. star orelse plus orelse name.len];
    if (letters.len == 1) {
        const f = r.field(letters[0]) orelse return error.UnhandledKey;
        const scale = if (star) |at| name[at + 1 .. plus orelse name.len] else null;
        const offset = if (plus) |at| name[at + 1 ..] else null;
        return number(w, f, register, scale, offset);
    }
    if (register or star != null) return error.UnhandledKey;
    const width = try widthOf(r, letters);
    try w.writeAll("try w.print(\"{d}\", .{(");
    try join(w, r, letters, width);
    try w.writeAll(")");
    if (plus) |at| try w.print(" + {s}", .{name[at + 1 ..]});
    try w.writeAll("});\n");
}

fn armShift(w: *std.Io.Writer, r: spec.Row, depth: usize) !void {
    if (r.field('y') == null) {
        try w.writeAll("if (");
        try emit_decode.operand(w, r.field('r') orelse return error.UnhandledKey);
        try w.writeAll(" != 0) try w.print(\", ror #{d}\", .{8 * ");
        try emit_decode.operand(w, r.field('r').?);
        try w.writeAll("});\n");
        return;
    }
    try w.writeAll("{\n");
    try pad(w, depth + 1);
    try w.writeAll("const amount = ");
    try emit_decode.operand(w, r.field('i') orelse return error.UnhandledKey);
    try w.writeAll(";\n");
    try pad(w, depth + 1);
    try w.writeAll("switch (");
    try emit_decode.operand(w, r.field('y') orelse return error.UnhandledKey);
    try w.writeAll(") {\n");
    try block(w, depth + 2, shift_arms);
    try pad(w, depth + 1);
    try w.writeAll("}\n");
    try pad(w, depth);
    try w.writeAll("}\n");
}

const shift_arms =
    \\0 => if (amount != 0) try w.print(", lsl #{d}", .{amount}),
    \\1 => try w.print(", lsr #{d}", .{if (amount == 0) 32 else amount}),
    \\2 => try w.print(", asr #{d}", .{if (amount == 0) 32 else amount}),
    \\else => if (amount == 0) try w.writeAll(", rrx") else try w.print(", ror #{d}", .{amount}),
;

const register_names = "\"r0\", \"r1\", \"r2\", \"r3\", \"r4\", \"r5\", \"r6\", \"r7\", \"r8\", \"r9\", \"r10\", \"r11\", \"r12\", \"sp\", \"lr\", \"pc\"";

fn number(w: *std.Io.Writer, f: spec.Field, register: bool, scale: ?[]const u8, offset: ?[]const u8) !void {
    if (register and scale == null and offset == null and f.width == 4) {
        try w.print("try w.writeAll(([_][]const u8{{ {s} }})[", .{register_names});
        try emit_decode.operand(w, f);
        try w.writeAll("]);\n");
        return;
    }
    if (register) {
        try w.print("try w.writeAll(([_][]const u8{{ {s} }})[", .{register_names});
        try applied(w, f, scale, offset);
        try w.writeAll("]);\n");
        return;
    }
    try w.writeAll("try w.print(\"{d}\", .{");
    try applied(w, f, scale, offset);
    try w.writeAll("});\n");
}

fn applied(w: *std.Io.Writer, f: spec.Field, scale: ?[]const u8, offset: ?[]const u8) !void {
    const wrapped = scale != null or offset != null;
    if (wrapped) try w.writeByte('(');
    try emit_decode.operand(w, f);
    if (wrapped) try w.writeByte(')');
    if (scale) |s| try w.print(" * {s}", .{s});
    if (offset) |o| try w.print(" + {s}", .{o});
}

fn riscvImmediate(w: *std.Io.Writer, r: spec.Row, name: []const u8) !void {
    if (std.mem.eql(u8, name, "u")) {
        try w.writeAll("try w.print(\"0x{x}\", .{");
        try emit_decode.operand(w, r.field('u') orelse return error.UnhandledKey);
        try w.writeAll("});\n");
        return;
    }
    if (std.mem.eql(u8, name, "h")) {
        try w.writeAll("try w.print(\"{d}\", .{");
        try emit_decode.operand(w, r.field('h') orelse return error.UnhandledKey);
        try w.writeAll("});\n");
        return;
    }
    if (std.mem.eql(u8, name, "csr")) {
        try w.writeAll("try writeCsr(w, ");
        try emit_decode.operand(w, r.field('c') orelse return error.UnhandledKey);
        try w.writeAll(");\n");
        return;
    }
    if (std.mem.eql(u8, name, "lui")) {
        const f = r.field('i') orelse return error.UnhandledKey;
        try w.print("try w.print(\"0x{{x}}\", .{{sext({d}, ", .{f.width});
        try emit_decode.operand(w, f);
        try w.writeAll(") & 0xfffff});\n");
        return;
    }
    const unsigned = name[0] == '+';
    const tail = name[name.len - 1];
    const scale: u5 = if (tail >= '0' and tail <= '9') @intCast(tail - '0') else 0;
    const letters = name[@intFromBool(unsigned) .. name.len - @intFromBool(scale != 0)];

    const width = try widthOf(r, letters);

    try w.writeAll("try w.print(\"{d}\", .{");
    if (unsigned) try w.writeAll("(") else try w.print("@as(i32, @bitCast(sext({d}, ", .{width});
    try join(w, r, letters, width);
    if (unsigned) try w.writeAll(")") else try w.writeAll(")))");
    if (scale != 0) try w.print(" << {d}", .{scale});
    try w.writeAll("});\n");
}

fn riscvFence(w: *std.Io.Writer, r: spec.Row, depth: usize) !void {
    try w.writeAll("{\n");
    for ([_]struct { []const u8, u8 }{ .{ "fm", 'f' }, .{ "pred", 'p' }, .{ "succ", 's' } }) |named| {
        try pad(w, depth + 1);
        try w.print("const {s} = ", .{named[0]});
        try emit_decode.operand(w, r.field(named[1]) orelse return error.UnhandledKey);
        try w.writeAll(";\n");
    }
    try pad(w, depth + 1);
    try w.writeAll("const bare = ");
    try emit_decode.operand(w, r.field('n') orelse return error.UnhandledKey);
    try w.writeAll(" == 0 and ");
    try emit_decode.operand(w, r.field('d') orelse return error.UnhandledKey);
    try w.writeAll(" == 0;\n");
    try block(w, depth + 1, fence_body);
    try pad(w, depth);
    try w.writeAll("}\n");
}

const fence_body =
    \\if (bare and fm == 8 and pred == 3 and succ == 3) {
    \\    try w.writeAll("fence.tso");
    \\} else if (bare and fm == 0 and pred == 1 and succ == 0) {
    \\    try w.writeAll("pause");
    \\} else if (fm == 0 and pred == 15 and succ == 15) {
    \\    try w.writeAll("fence");
    \\} else {
    \\    try w.writeAll("fence ");
    \\    inline for (.{ pred, succ }, 0..) |set, at| {
    \\        if (at != 0) try w.writeAll(", ");
    \\        if (set == 0) try w.writeByte('0');
    \\        inline for ("iorw", 0..) |letter, bit| {
    \\            if (set >> @intCast(3 - bit) & 1 != 0) try w.writeByte(letter);
    \\        }
    \\    }
    \\}
;

fn widthOf(r: spec.Row, letters: []const u8) !u8 {
    var width: u8 = 0;
    for (letters) |c| {
        if (c == ':') continue;
        width += (r.field(c) orelse return error.UnhandledKey).width;
    }
    return width;
}

fn join(w: *std.Io.Writer, r: spec.Row, letters: []const u8, width: u8) !void {
    var shift = width;
    var first = true;
    for (letters) |c| {
        if (c == ':') continue;
        const f = r.field(c).?;
        shift -= f.width;
        if (!first) try w.writeAll(" | ");
        try w.writeAll("(");
        try emit_decode.operand(w, f);
        try w.print(") << {d}", .{shift});
        first = false;
    }
}

fn block(w: *std.Io.Writer, depth: usize, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |l| {
        try pad(w, depth);
        try w.writeAll(l);
        try w.writeByte('\n');
    }
}

fn pad(w: *std.Io.Writer, depth: usize) !void {
    try w.splatByteAll(' ', depth * 4);
}

const condition_names = "\"eq\", \"ne\", \"cs\", \"cc\", \"mi\", \"pl\", \"vs\", \"vc\", \"hi\", \"ls\", \"ge\", \"lt\", \"gt\", \"le\", \"al\", \"nv\"";

/// Zig source for the register-list writers prepended to the Arm disassembler.
pub const helpers =
    \\fn writeSingles(w: *std.Io.Writer, first: u32, count: u32) std.Io.Writer.Error!void {
    \\    if (count == 0) return w.writeAll("{}");
    \\    return w.print("{{s{d}-s{d}}}", .{ first, first + count - 1 });
    \\}
    \\
    \\fn writeDoubles(w: *std.Io.Writer, first: u32, count: u32) std.Io.Writer.Error!void {
    \\    if (count == 0) return w.writeAll("{}");
    \\    return w.print("{{d{d}-d{d}}}", .{ first, first + count - 1 });
    \\}
    \\
    \\fn writeVprRegs(w: *std.Io.Writer, code: u32, d: u32, y: u32, i: u32) std.Io.Writer.Error!void {
    \\    const single = code >> 8 & 1 == 0;
    \\    const letter: u8 = if (single) 's' else 'd';
    \\    const first = if (single) d << 1 | y else y << 4 | d;
    \\    try w.writeByte('{');
    \\    if (i == 1) try w.print("{c}{d}, ", .{ letter, first }) else if (i > 1) try w.print("{c}{d}-{c}{d}, ", .{ letter, first, letter, first + i - 1 });
    \\    return w.writeAll("VPR}");
    \\}
    \\
    \\fn writeVectorOrr(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const n = code >> 17 & 7;
    \\    const m = code >> 1 & 7;
    \\    if (n == m) return w.print("vmov q{d}, q{d}", .{ code >> 13 & 7, n });
    \\    return w.print("vorr q{d}, q{d}, q{d}", .{ code >> 13 & 7, n, m });
    \\}
    \\
    \\fn writeVectorBlock(w: *std.Io.Writer, code: u32, comptime opens: []const u8, comptime bare: []const u8) std.Io.Writer.Error!void {
    \\    const mask = (code >> 22 & 1) << 3 | (code >> 13 & 7);
    \\    if (mask == 0) return w.writeAll(bare);
    \\    try w.writeAll(opens);
    \\    var inverted = false;
    \\    var bit: u5 = 3;
    \\    while (bit > @ctz(mask)) : (bit -= 1) {
    \\        if (mask >> bit & 1 != 0) inverted = !inverted;
    \\        try w.writeByte(if (inverted) 'e' else 't');
    \\    }
    \\}
    \\
    \\fn writeVectorCompare(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const scalar = code >> 6 & 1 == 1;
    \\    const condition = (code >> 12 & 1) << 2 | (code >> 7 & 1) << 1 | (if (scalar) code >> 5 & 1 else code & 1);
    \\    const real = code >> 20 & 3 == 3;
    \\    try writeVectorBlock(w, code, "vpt", "vcmp");
    \\    try w.print(".{c}{d} {s}, q{d}, ", .{
    \\        if (real) 'f' else "iuiussss"[condition],
    \\        if (real) @as(u32, if (code >> 28 & 1 == 1) 16 else 32) else @as(u32, 8) << @intCast(code >> 20 & 3),
    \\        ([_][]const u8{ "eq", "cs", "ne", "hi", "ge", "gt", "lt", "le" })[condition],
    \\        code >> 17 & 7,
    \\    });
    \\    if (scalar) return if (code & 0xf == 15) w.writeAll("zr") else w.writeAll(([_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc" })[code & 0xf]);
    \\    return w.print("q{d}", .{code >> 1 & 7});
    \\}
    \\
    \\fn writeVectorAcross(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const long = code >> 20 & 7 != 7;
    \\    try w.print("v{s}{s}.{c}{d} r{d}, ", .{
    \\        if (long) "addlv" else "addv",
    \\        if (code >> 5 & 1 == 1) "a" else "",
    \\        @as(u8, if (code >> 28 & 1 == 1) 'u' else 's'),
    \\        if (long) @as(u32, 32) else @as(u32, 8) << @intCast(code >> 18 & 3),
    \\        (code >> 13 & 7) * 2,
    \\    });
    \\    if (long) try w.print("r{d}, ", .{(code >> 20 & 7) * 2 + 1});
    \\    return w.print("q{d}", .{code >> 1 & 7});
    \\}
    \\
    \\fn writeVectorProducts(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const long = code >> 20 & 7 != 7;
    \\    const minus = code & 1 == 1;
    \\    const unsigned = code >> 28 & 1 == 1;
    \\    const other = if (minus) unsigned else code >> 8 & 1 == 1;
    \\    const rounding = long and other;
    \\    const size: u32 = if (other) (if (long) 32 else 8) else if (code >> 16 & 1 == 1) 32 else 16;
    \\    const exchange = code >> 12 & 1 == 1;
    \\    try w.print("v{s}ml{s}{s}{s}{s}{s}{s}.{c}{d} r{d}, ", .{
    \\        if (rounding) "r" else "",
    \\        if (minus) "s" else "a",
    \\        if (long) "l" else "",
    \\        if (minus or exchange) "dav" else "v",
    \\        if (rounding) "h" else "",
    \\        if (code >> 5 & 1 == 1) "a" else "",
    \\        if (exchange) "x" else "",
    \\        @as(u8, if (!minus and unsigned) 'u' else 's'),
    \\        size,
    \\        (code >> 13 & 7) * 2,
    \\    });
    \\    if (long) try w.print("r{d}, ", .{(code >> 20 & 7) * 2 + 1});
    \\    return w.print("q{d}, q{d}", .{ code >> 17 & 7, code >> 1 & 7 });
    \\}
    \\
    \\fn writeVectorWiden(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const wide = code >> 20 & 1 == 1;
    \\    const amount = if (wide) code >> 16 & 0xf else code >> 16 & 7;
    \\    try w.print("{s}{c}.{c}{d} q{d}, q{d}", .{
    \\        if (amount == 0) "vmovl" else "vshll",
    \\        @as(u8, if (code >> 12 & 1 == 1) 't' else 'b'),
    \\        @as(u8, if (code >> 28 & 1 == 1) 'u' else 's'),
    \\        @as(u32, if (wide) 16 else 8),
    \\        code >> 13 & 7,
    \\        code >> 1 & 7,
    \\    });
    \\    if (amount != 0) try w.print(", #{d}", .{amount});
    \\}
    \\
    \\fn writeVectorNarrow(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    return w.print("{d}", .{16 - (code >> 16 & 0xf)});
    \\}
    \\
    \\fn writeVectorConstant(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const cmode: u4 = @truncate(code >> 8);
    \\    const inverted = code >> 5 & 1 == 1;
    \\    const imm8: u8 = @intCast((code >> 28 & 1) << 7 | (code >> 16 & 7) << 4 | (code & 0xf));
    \\    const d = code >> 13 & 7;
    \\    const words = expandedWord(cmode, inverted, imm8);
    \\    if (cmode == 14 and inverted) return w.print("vmov.i64 q{d}, #0x{x:0>16}", .{ d, @as(u64, words[1]) << 32 | words[0] });
    \\    if (cmode == 15) return w.print("vmov.f32 q{d}, #{d}", .{ d, @as(f32, @bitCast(words[0])) });
    \\    const combining = cmode & 1 == 1 and cmode >> 2 != 3;
    \\    const size: u32 = if (cmode >> 3 == 1 and cmode >> 2 != 3) 16 else if (cmode == 14) 8 else 32;
    \\    return w.print("{s}.i{d} q{d}, #{d}", .{
    \\        if (combining) (if (inverted) "vbic" else "vorr") else if (inverted) "vmvn" else "vmov",
    \\        size,
    \\        d,
    \\        if (size == 32) words[0] else words[0] & ((@as(u32, 1) << @intCast(size)) - 1),
    \\    });
    \\}
    \\
    \\fn writeVectorMemory(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const load = code >> 20 & 1 == 1;
    \\    const esize: u32 = @as(u32, 8) << @intCast(code >> 7 & 3);
    \\    const msize: u32 = if (code >> 12 & 1 == 1) esize else if (code >> 19 & 1 == 1) 16 else 8;
    \\    const base = if (code >> 12 & 1 == 1) code >> 16 & 0xf else code >> 16 & 7;
    \\    try w.print("{s}{c}.", .{ if (load) "vldr" else "vstr", "bhw"[std.math.log2(msize) - 3] });
    \\    if (load and msize != esize) try w.writeByte(if (code >> 28 & 1 == 1) 'u' else 's') else if (load) try w.writeByte('u');
    \\    const offset = (code & 0x7f) * (msize / 8);
    \\    try w.print("{d} q{d}, [r{d}", .{ esize, code >> 13 & 7, base });
    \\    const sign: []const u8 = if (code >> 23 & 1 == 1) "" else "-";
    \\    if (code >> 24 & 1 == 0) return w.print("], #{s}{d}", .{ sign, offset });
    \\    return w.print(", #{s}{d}]{s}", .{ sign, offset, if (code >> 21 & 1 == 1) "!" else "" });
    \\}
    \\
    \\fn writeVectorGather(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const wide = code >> 8 & 1 == 1;
    \\    const load = code >> 20 & 1 == 1;
    \\    const offset = (code & 0x7f) * (if (wide) @as(u32, 8) else 4);
    \\    try w.print("{s}{c}.{s}{d} q{d}, [q{d}", .{
    \\        if (load) "vldr" else "vstr",
    \\        @as(u8, if (wide) 'd' else 'w'),
    \\        if (load) "u" else "",
    \\        if (wide) @as(u32, 64) else 32,
    \\        code >> 13 & 7,
    \\        code >> 17 & 7,
    \\    });
    \\    if (offset != 0) try w.print(", #{s}{d}", .{ if (code >> 23 & 1 == 1) "" else "-", offset });
    \\    return w.print("]{s}", .{if (code >> 21 & 1 == 1) "!" else ""});
    \\}
    \\
    \\fn writeVectorGroup(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const first = code >> 13 & 7;
    \\    try w.print("{{q{d}, q{d}", .{ first, (first + 1) % 8 });
    \\    if (code & 1 == 1) try w.print(", q{d}, q{d}", .{ (first + 2) % 8, (first + 3) % 8 });
    \\    return w.writeByte('}');
    \\}
    \\
    \\fn writeVectorShift(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    \\    const width = code >> 16 & 0x3f;
    \\    return w.print("{d}", .{@as(u32, if (width >= 32) 64 else if (width >= 16) 32 else 16) - width});
    \\}
    \\
    \\fn amountOf(i: u32) u32 {
    \\    return if (i == 0) 32 else i;
    \\}
    \\
    \\fn writeIndex(w: *std.Io.Writer, p: u32, u: u32, i: u32) std.Io.Writer.Error!void {
    \\    const sign: []const u8 = if (u == 1) "" else "-";
    \\    if (p == 1) try w.print(", #{s}{d}]!", .{ sign, i }) else try w.print("], #{s}{d}", .{ sign, i });
    \\}
    \\
    \\fn writeBarrier(w: *std.Io.Writer, option: u32) std.Io.Writer.Error!void {
    \\    return switch (option) {
    \\        0b1111 => w.writeAll("sy"),
    \\        0b1110 => w.writeAll("st"),
    \\        0b1011 => w.writeAll("ish"),
    \\        0b1010 => w.writeAll("ishst"),
    \\        0b0111 => w.writeAll("nsh"),
    \\        0b0110 => w.writeAll("nshst"),
    \\        0b0011 => w.writeAll("osh"),
    \\        0b0010 => w.writeAll("oshst"),
    \\        else => w.print("#{d}", .{option}),
    \\    };
    \\}
    \\
    \\fn writeHint(w: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    \\    return w.writeAll(switch (value) {
    \\        0x00 => "nop.w",
    \\        0x01 => "yield.w",
    \\        0x02 => "wfe.w",
    \\        0x03 => "wfi.w",
    \\        0x04 => "sev.w",
    \\        0x14 => "csdb",
    \\        0x0d => "pacbti r12, lr, sp",
    \\        0x0f => "bti",
    \\        0x1d => "pac r12, lr, sp",
    \\        0x2d => "aut r12, lr, sp",
    \\        else => "reserved hint",
    \\    });
    \\}
    \\
    \\fn writeZero(w: *std.Io.Writer, number: u32) std.Io.Writer.Error!void {
    \\    if (number == 15) return w.writeAll("zr");
    \\    return w.writeAll(([_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc" })[number]);
    \\}
    \\
    \\fn signedOffset(top: u32, low: u32, comptime width: u5) u32 {
    \\    const value = top << 12 | low;
    \\    return value -% (value >> (width - 1) & 1) * (@as(u32, 1) << width);
    \\}
    \\
    \\fn writeBranchFuture(w: *std.Io.Writer, code: u32, pc: u32) std.Io.Writer.Error!void {
    \\    const here = pc +% 4;
    \\    const point = here +% ((code >> 23 & 0xf) << 1);
    \\    const low = (code >> 1 & 0x3ff) << 2 | (code >> 11 & 1) << 1;
    \\    if (code >> 13 & 1 == 0) return w.print("bfl 0x{x}, 0x{x}", .{ point, here +% signedOffset(code >> 16 & 0x7f, low, 19) });
    \\    return switch (code >> 20 & 7) {
    \\        0b110 => w.print("bfx 0x{x}, r{d}", .{ point, code >> 16 & 0xf }),
    \\        0b111 => w.print("bflx 0x{x}, r{d}", .{ point, code >> 16 & 0xf }),
    \\        0b100, 0b101 => w.print("bf 0x{x}, 0x{x}", .{ point, here +% signedOffset(code >> 16 & 0x1f, low, 17) }),
    \\        else => {
    \\            try w.print("bfcsel 0x{x}, 0x{x}, 0x{x}, ", .{ point, here +% signedOffset(code >> 16 & 1, low, 13), point +% 4 });
    \\            try w.writeAll(([_][]const u8{ "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv" })[code >> 18 & 0xf]);
    \\        },
    \\    };
    \\}
    \\
    \\fn writeItBlock(w: *std.Io.Writer, first: u32, mask: u32) std.Io.Writer.Error!void {
    \\    var bit: u32 = 3;
    \\    while (bit > @ctz(mask)) : (bit -= 1) {
    \\        try w.writeByte(if (mask >> @intCast(bit) & 1 == first & 1) 't' else 'e');
    \\    }
    \\}
    \\
    \\fn writeSpecial(w: *std.Io.Writer, sysm: u32, mask: u32) std.Io.Writer.Error!void {
    \\    const number = sysm & 0x7f;
    \\    const ns = sysm & 0x80 != 0;
    \\    const suffix: []const u8 = if (ns) "_ns" else "";
    \\    if (number >= 32 and number <= 39) return w.print("pac_key_{c}_{d}{s}", .{ @as(u8, if (number < 36) 'p' else 'u'), number & 3, suffix });
    \\    if (ns and number == 24) return w.writeAll("sp_ns");
    \\    const name: ?[]const u8 = switch (number) {
    \\        8 => "msp",
    \\        9 => "psp",
    \\        10 => "msplim",
    \\        11 => "psplim",
    \\        16 => "primask",
    \\        17 => "basepri",
    \\        19 => "faultmask",
    \\        20 => "control",
    \\        0, 1, 2, 3, 5, 6, 7, 18 => if (ns) null else switch (number) {
    \\            0 => "apsr",
    \\            1 => "iapsr",
    \\            2 => "eapsr",
    \\            3 => "xpsr",
    \\            5 => "ipsr",
    \\            6 => "epsr",
    \\            7 => "iepsr",
    \\            else => "basepri_max",
    \\        },
    \\        else => null,
    \\    };
    \\    if (name) |n| try w.writeAll(n) else return w.print("{d}", .{sysm});
    \\    try w.writeAll(suffix);
    \\    if (sysm < 4) try w.writeAll(switch (mask) {
    \\        1 => "_g",
    \\        3 => "_nzcvqg",
    \\        else => "",
    \\    });
    \\}
;
