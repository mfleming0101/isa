//! Reading the pinned oracles bench/run.zig compares an alternative against. `parse` splits a
//! line of oracle/disasm_*.txt; `normalize` brings both sides of the disassembly differential to one
//! spelling so only decode disagreements survive; `window`, `seed`, `fold` and `state` hash a
//! window of retired instructions the way oracle/mktrace.py folds the Sail side.

const std = @import("std");

/// Whether a pinned line must match, or is skipped as an IT-block slot or out-of-scope extension.
pub const Match = enum { ok, skip };

/// One line of oracle/disasm_*.txt: code, pc, kind and rendered text.
pub const Line = struct { code: []const u8, pc: []const u8, kind: Match, text: []const u8 };

/// Splits a pinned line into its fields; comments and blanks yield null.
pub fn parse(raw: []const u8) ?Line {
    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.splitScalar(u8, trimmed, ' ');
    const code = fields.next() orelse return null;
    const pc = fields.next() orelse return null;
    const kind = fields.next() orelse return null;
    return .{
        .code = code,
        .pc = pc,
        .kind = if (std.mem.eql(u8, kind, "ok")) .ok else .skip,
        .text = fields.rest(),
    };
}

/// Collapses whitespace, immediate radix, width suffixes, implicit zero offsets and aliases into out.
pub fn normalize(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var mnemonic = true;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
            if (n != 0 and i < text.len) {
                out[n] = ' ';
                n += 1;
            }
            mnemonic = false;
            continue;
        }
        if (mnemonic and c == '.' and width(text[i + 1 ..])) {
            i += 2;
            continue;
        }
        if (numeric(text, i)) {
            const end = span(text, i);
            n += decimal(out[n..], text[i..end]);
            i = end;
            continue;
        }
        out[n] = c;
        n += 1;
        i += 1;
    }
    return alias(out, implicitZero(out[0..n]));
}

fn alias(scratch: []u8, text: []const u8) []const u8 {
    const swapped = condition(scratch, shift(scratch, text));
    for ([_][2][]const u8{
        .{ "lsls ", "movs " },
        .{ "pop {", "ldm sp!, {" },
        .{ "push {", "stmdb sp!, {" },
        .{ "blo ", "bcc " },
        .{ "bhs ", "bcs " },
        .{ "msr apsr_nzcvq,", "msr apsr," },
    }, 0..) |rule, i| {
        if (i == 0) {
            if (std.mem.startsWith(u8, swapped, rule[0]) and std.mem.endsWith(u8, swapped, ", #0")) {
                return join(scratch, swapped, rule[1], swapped[rule[0].len .. swapped.len - ", #0".len]);
            }
            continue;
        }
        if (std.mem.startsWith(u8, swapped, rule[0])) {
            return join(scratch, swapped, rule[1], swapped[rule[0].len..]);
        }
    }
    return swapped;
}

fn condition(scratch: []u8, text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "it")) return text;
    const at = std.mem.indexOfScalar(u8, text, ' ') orelse return text;
    for (text[1..at]) |c| if (c != 't' and c != 'e') return text;
    for ([_][2][]const u8{ .{ "lo", "cc" }, .{ "hs", "cs" } }) |rule| {
        if (!std.mem.eql(u8, text[at + 1 ..], rule[0])) continue;
        return join(scratch, text, text[0 .. at + 1], rule[1]);
    }
    return text;
}

fn shift(scratch: []u8, text: []const u8) []const u8 {
    const flags = std.mem.startsWith(u8, text, "movs ");
    if (!flags and !std.mem.startsWith(u8, text, "mov ")) return text;
    const operands = text[if (flags) "movs ".len else "mov ".len..];
    if (std.mem.endsWith(u8, operands, ", rrx")) {
        var buffer: [256]u8 = undefined;
        const built = std.fmt.bufPrint(&buffer, "rrx{s} {s}", .{
            if (flags) "s" else "",
            operands[0 .. operands.len - ", rrx".len],
        }) catch return text;
        @memcpy(scratch[0..built.len], built);
        return scratch[0..built.len];
    }
    for ([_][]const u8{ "lsl", "lsr", "asr", "ror" }) |name| {
        var tail: [8]u8 = undefined;
        const marker = std.fmt.bufPrint(&tail, ", {s} #", .{name}) catch unreachable;
        const at = std.mem.indexOf(u8, operands, marker) orelse continue;
        var buffer: [256]u8 = undefined;
        const built = std.fmt.bufPrint(&buffer, "{s}{s} {s}, #{s}", .{
            name,
            if (flags) "s" else "",
            operands[0..at],
            operands[at + marker.len ..],
        }) catch return text;
        @memcpy(scratch[0..built.len], built);
        return scratch[0..built.len];
    }
    return text;
}

fn join(scratch: []u8, text: []const u8, head: []const u8, tail: []const u8) []const u8 {
    var buffer: [256]u8 = undefined;
    const built = std.fmt.bufPrint(&buffer, "{s}{s}", .{ head, tail }) catch return text;
    if (built.len > scratch.len) return text;
    @memcpy(scratch[0..built.len], built);
    return scratch[0..built.len];
}

fn width(rest: []const u8) bool {
    if (rest.len == 0 or (rest[0] != 'w' and rest[0] != 'n')) return false;
    return rest.len == 1 or std.ascii.isWhitespace(rest[1]);
}

fn numeric(text: []const u8, at: usize) bool {
    const c = text[at];
    const digit = std.ascii.isDigit(c) or (c == '-' and at + 1 < text.len and std.ascii.isDigit(text[at + 1]));
    if (!digit) return false;
    return at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
}

fn span(text: []const u8, at: usize) usize {
    var i = at + @intFromBool(text[at] == '-');
    if (std.mem.startsWith(u8, text[i..], "0x") or std.mem.startsWith(u8, text[i..], "0X")) i += 2;
    while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
    return i;
}

fn decimal(out: []u8, literal: []const u8) usize {
    const negative = literal[0] == '-';
    const body = literal[@intFromBool(negative)..];
    const hex = std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X");
    const value = std.fmt.parseInt(u64, if (hex) body[2..] else body, if (hex) 16 else 10) catch {
        @memcpy(out[0..literal.len], literal);
        return literal.len;
    };
    const written = std.fmt.bufPrint(out, "{s}{d}", .{ if (negative) "-" else "", value }) catch literal;
    return written.len;
}

fn implicitZero(text: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ',' and std.mem.startsWith(u8, text[i..], ", #0]")) {
            text[n] = ']';
            n += 1;
            i += ", #0]".len;
            continue;
        }
        text[n] = text[i];
        n += 1;
        i += 1;
    }
    return text[0..n];
}

/// Retired instructions hashed per trace window.
pub const window = 1 << 16;

/// FNV-1a offset basis every window's fold starts from.
pub const seed: u64 = 0xcbf29ce484222325;

/// FNV-1a over one state record and a separator, as oracle/sweep_*.txt and oracle/mktrace.py hash.
pub fn fold(hash: u64, record: []const u8) u64 {
    var out = hash;
    for (record) |byte| out = (out ^ byte) *% 0x100000001b3;
    return (out ^ 0xff) *% 0x100000001b3;
}

/// A trace line without its leading retired count; a stop line yields null.
pub fn state(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "stop=")) return null;
    const at = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    return std.mem.trimEnd(u8, line[at + 1 ..], "\r\n");
}

test "the fold agrees with the generator that pinned the reference" {
    try std.testing.expectEqual(@as(u64, 0xfc182483ee0806dc), fold(seed, "abc"));
    try std.testing.expectEqual(@as(u64, 0x664faaa4e67a6b78), fold(fold(seed, "abc"), "de"));
}

test "a trace line yields the state record, and a stop line yields nothing" {
    try std.testing.expectEqualStrings("00000004 00000000 0000dead", state("1 00000004 00000000 0000dead\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), state("stop=breakpoint"));
}

test "a pinned line splits into its four fields" {
    const line = parse("f8048b01 11fe ok strb.w r8, [r4], #1").?;
    try std.testing.expectEqualStrings("f8048b01", line.code);
    try std.testing.expectEqualStrings("11fe", line.pc);
    try std.testing.expectEqual(Match.ok, line.kind);
    try std.testing.expectEqualStrings("strb.w r8, [r4], #1", line.text);
    try std.testing.expectEqual(Match.skip, parse("4770 5e skip-itblock bxne lr").?.kind);
    try std.testing.expectEqual(@as(?Line, null), parse("# llvm-objdump-19"));
}

test "the spellings that differ without disagreeing collapse onto each other" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const pairs = [_][2][]const u8{
        .{ "lui a1, 512", "lui a1, 0x200" },
        .{ "addi t0, t0, -8", "addi\tt0,  t0,  -0x8" },
        .{ "str r2, [r0]", "str r2, [r0, #0]" },
        .{ "mul r5, r4, r3", "mul.w r5, r4, r3" },
        .{ "ldr.w lr, [r0]", "ldr.w lr, [r0, #0]" },
        .{ "c.slli a3, 31", "c.slli a3, 0x1f" },
    };
    for (pairs) |pair| {
        try std.testing.expectEqualStrings(normalize(&a, pair[0]), normalize(&b, pair[1]));
    }
}

test "an alias and the architectural form it names collapse onto each other" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const pairs = [_][2][]const u8{
        .{ "movs r0, r0", "lsls r0, r0, #0" },
        .{ "pop {r4, pc}", "ldm.w sp!, {r4, pc}" },
        .{ "push {r4, lr}", "stmdb sp!, {r4, lr}" },
        .{ "blo 2496", "bcc 2496" },
        .{ "bhs 2566", "bcs 2566" },
        .{ "it hs", "it cs" },
        .{ "itt lo", "itt cc" },
        .{ "itete hs", "itete cs" },
        .{ "rrx r4, r4", "mov r4, r4, rrx" },
        .{ "rrxs r5, r9", "movs r5, r9, rrx" },
        .{ "msr apsr, lr", "msr apsr_nzcvq, lr" },
        .{ "lsl r8, r8, #1", "mov r8, r8, lsl #1" },
        .{ "lsls r2, lr, #31", "movs r2, lr, lsl #31" },
        .{ "lsr r12, r7, #2", "mov r12, r7, lsr #2" },
    };
    for (pairs) |pair| try std.testing.expectEqualStrings(normalize(&a, pair[0]), normalize(&b, pair[1]));
}

test "a register is not an immediate, and a real disagreement survives" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("mv s11, a5", normalize(&a, "mv s11, a5"));
    try std.testing.expectEqualStrings("ldm sp!, {r4, r5}", normalize(&a, "ldm.w sp!, {r4, r5}"));
    try std.testing.expect(!std.mem.eql(u8, normalize(&a, "c.addi4spn s0, sp, 0"), normalize(&b, "undefined")));
    try std.testing.expect(!std.mem.eql(u8, normalize(&a, "str r2, [r0, #4]"), normalize(&b, "str r2, [r0]")));
}
