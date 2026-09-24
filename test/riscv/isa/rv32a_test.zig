//! Tests of the RV32A rows over a stub memory whose last word answers nothing: each AMO's
//! read-combine-write, LR.W and SC.W reservation behaviour (section 8.2), a misaligned address in
//! each of the three, unanswered atomics, the ignored aq and rl bits, rendering, and that the A
//! rows belong to a group of their own.
const std = @import("std");
const State = @import("../../../src/riscv/isa/state.zig").State;
const instruction = @import("../../../src/riscv/isa/instruction.zig");
const decode = @import("../../../src/riscv/isa/decode.zig");
const csr = @import("../../../src/riscv/isa/csr.zig");
const step = @import("../../../src/riscv/isa/step.zig");
const disasm = @import("riscv_disasm");
const tree = @import("riscv_decode");

const Mem = struct {
    /// Every group, so each row decodes.
    pub const allowed = decode.every;
    const Self = @This();

    const refused: u32 = 28;

    bytes: [32]u8 = @splat(0),

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (address >= refused) return null;
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    /// Host requirement: a touched address is ignored here.
    pub fn touch(_: *Self, _: u32) void {}

    /// The bytes from an address up to the refused word, or nothing where out of range.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        _ = self.slice(address, a.bytes) orelse return &.{};
        return self.bytes[address..refused];
    }

    /// Every access the span could not serve is refused.
    pub fn access(_: *Self, _: u32, comptime _: anytype, _: u32) error{DataFault}!u32 {
        return error.DataFault;
    }

    /// A PMP register reads as an unwritten entry; no processor stands behind these tests.
    pub fn readPmp(_: *Self, _: csr.Protection) u32 {
        return 0;
    }

    /// A PMP write goes nowhere.
    pub fn writePmp(_: *Self, _: csr.Protection, _: u32) void {}

    /// Host requirement: nothing to re-guard here.
    pub fn reguard(_: *Self) void {}

    /// Host requirement: nothing to re-arm here.
    pub fn rearm(_: *Self) void {}

    /// Host requirement: a privilege change is touched by nobody.
    pub fn returned(_: *Self) void {}

    /// Host requirement: a WFI has nothing to wait for.
    pub fn sleep(_: *Self) void {}

    fn word(self: *Self, address: u32) u32 {
        return std.mem.readInt(u32, self.bytes[address..][0..4], .little);
    }

    fn put(self: *Self, address: u32, value: u32) void {
        std.mem.writeInt(u32, self.bytes[address..][0..4], value, .little);
    }
};

fn exec(s: *State, m: *Mem, encoded: u32) instruction.Outcome {
    return step.call(Mem, s, m, encoded, Mem.allowed);
}

const amo_opcode: u32 = 0b0101111;
const width_w: u32 = 0b010;

const funct5 = struct {
    const lr: u32 = 0b00010;
    const sc: u32 = 0b00011;
    const swap: u32 = 0b00001;
    const add: u32 = 0b00000;
    const xor: u32 = 0b00100;
    const @"and": u32 = 0b01100;
    const @"or": u32 = 0b01000;
    const min: u32 = 0b10000;
    const max: u32 = 0b10100;
    const minu: u32 = 0b11000;
    const maxu: u32 = 0b11100;
};

const aq: u32 = 0b10;
const rl: u32 = 0b01;

fn code(f5: u32, ordering: u32, rs2: u32, rs1: u32, rd: u32) u32 {
    return f5 << 27 | ordering << 25 | rs2 << 20 | rs1 << 15 | width_w << 12 | rd << 7 | amo_opcode;
}

fn secondOf(f5: u32) u32 {
    return if (f5 == funct5.lr) 0 else 2;
}

fn apply(m: *Mem, f5: u32, address: u32, source: u32) !u32 {
    var s: State = .{};
    s.x[1] = address;
    s.x[2] = source;
    try std.testing.expectEqual(.next, exec(&s, m, code(f5, 0, 2, 1, 3)));
    return s.x[3];
}

fn render(c: u32) ![]const u8 {
    const S = struct {
        var buffer: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buffer);
    try disasm.write(&w, c, 0, decode.every);
    return w.buffered();
}

test "every AMO reads the word at rs1, writes the combination of it and rs2 back, and leaves the word it read in rd, section 8.4" {
    const cases = [_]struct { f5: u32, old: u32, source: u32, wrote: u32 }{
        .{ .f5 = funct5.swap, .old = 0x1111_2222, .source = 0x3333_4444, .wrote = 0x3333_4444 },
        .{ .f5 = funct5.add, .old = 0xffff_ffff, .source = 3, .wrote = 2 },
        .{ .f5 = funct5.xor, .old = 0b1100, .source = 0b1010, .wrote = 0b0110 },
        .{ .f5 = funct5.@"and", .old = 0b1100, .source = 0b1010, .wrote = 0b1000 },
        .{ .f5 = funct5.@"or", .old = 0b1100, .source = 0b1010, .wrote = 0b1110 },
        .{ .f5 = funct5.min, .old = 0xffff_fffb, .source = 3, .wrote = 0xffff_fffb },
        .{ .f5 = funct5.max, .old = 0xffff_fffb, .source = 3, .wrote = 3 },
        .{ .f5 = funct5.minu, .old = 0xffff_fffb, .source = 3, .wrote = 3 },
        .{ .f5 = funct5.maxu, .old = 0xffff_fffb, .source = 3, .wrote = 0xffff_fffb },
    };
    for (cases) |c| {
        var m: Mem = .{};
        m.put(8, c.old);
        try std.testing.expectEqual(c.old, try apply(&m, c.f5, 8, c.source));
        try std.testing.expectEqual(c.wrote, m.word(8));
    }
}

test "AMOMIN and AMOMAX order their operands as signed words and AMOMINU and AMOMAXU as unsigned ones, section 8.4" {
    var m: Mem = .{};
    m.put(4, 0x8000_0000);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(&m, funct5.min, 4, 0x7fff_ffff));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), m.word(4));
    m.put(4, 0x8000_0000);
    _ = try apply(&m, funct5.minu, 4, 0x7fff_ffff);
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), m.word(4));
    m.put(4, 0x8000_0000);
    _ = try apply(&m, funct5.max, 4, 0x7fff_ffff);
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), m.word(4));
    m.put(4, 0x8000_0000);
    _ = try apply(&m, funct5.maxu, 4, 0x7fff_ffff);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), m.word(4));
}

test "an AMO whose destination register is also its address register reaches memory before it writes rd, section 8.4" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(12, 0x0000_00ff);
    s.x[1] = 12;
    s.x[2] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.add, 0, 2, 1, 1)));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.x[1]);
    try std.testing.expectEqual(@as(u32, 0x0000_0100), m.word(12));
}

test "an AMO whose destination is x0 still writes memory, since the register file drops the write and nothing else does" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(0, 5);
    s.x[1] = 0;
    s.x[2] = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.swap, 0, 2, 1, 0)));
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);
    try std.testing.expectEqual(@as(u32, 7), m.word(0));
}

test "LR.W reads the word and takes a reservation on its address, and SC.W to that address stores and answers zero, section 8.2" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(16, 0xdead_beef);
    s.x[1] = 16;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.lr, 0, 0, 1, 3)));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.x[3]);
    try std.testing.expectEqual(@as(?u32, 16), s.reservation);
    s.x[2] = 0x5555_5555;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.sc, 0, 2, 1, 4)));
    try std.testing.expectEqual(@as(u32, 0), s.x[4]);
    try std.testing.expectEqual(@as(u32, 0x5555_5555), m.word(16));
    try std.testing.expectEqual(@as(?u32, null), s.reservation);
}

test "SC.W with no reservation held stores nothing and answers the model's fail code, section 8.2" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(16, 0xdead_beef);
    s.x[1] = 16;
    s.x[2] = 0x5555_5555;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.sc, 0, 2, 1, 4)));
    try std.testing.expectEqual(csr.sail.sc_failure, s.x[4]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), m.word(16));
}

test "SC.W against a reservation on another word stores nothing, and the reservation is gone after it either way, section 8.2" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(16, 0xdead_beef);
    s.x[1] = 20;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.lr, 0, 0, 1, 3)));
    s.x[1] = 16;
    s.x[2] = 0x5555_5555;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.sc, 0, 2, 1, 4)));
    try std.testing.expectEqual(csr.sail.sc_failure, s.x[4]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), m.word(16));
    try std.testing.expectEqual(@as(?u32, null), s.reservation);
}

test "a second SC.W after one that stored fails, because the first released the lock, section 8.2" {
    var m: Mem = .{};
    var s: State = .{};
    s.x[1] = 16;
    _ = exec(&s, &m, code(funct5.lr, 0, 0, 1, 3));
    s.x[2] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.sc, 0, 2, 1, 4)));
    try std.testing.expectEqual(@as(u32, 0), s.x[4]);
    s.x[2] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.sc, 0, 2, 1, 4)));
    try std.testing.expectEqual(csr.sail.sc_failure, s.x[4]);
    try std.testing.expectEqual(@as(u32, 1), m.word(16));
}

test "a misaligned address in LR.W or SC.W is refused whatever the model answers for a misaligned load, section 8.2" {
    for ([_]u32{ funct5.lr, funct5.sc }) |f5| {
        var m: Mem = .{};
        var s: State = .{};
        s.x[1] = 6;
        try std.testing.expectEqual(.unaligned, exec(&s, &m, code(f5, 0, secondOf(f5), 1, 3)));
        try std.testing.expectEqual(@as(?u32, null), s.reservation);
    }
}

test "a misaligned AMO follows the model, answered where a misaligned load is and refused where it is not, section 8.4" {
    var m: Mem = .{};
    var s: State = .{};
    m.put(4, 0x1111_2222);
    m.put(8, 0x4444_3333);
    s.x[1] = 6;
    s.x[2] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.add, 0, 2, 1, 3)));
    try std.testing.expectEqual(@as(u32, 0x3333_1111), s.x[3]);
    try std.testing.expectEqual(@as(u32, 0x1112_2222), m.word(4));
    try std.testing.expectEqual(@as(u32, 0x4444_3333), m.word(8));

    s.csr.implementation.misaligned = .refused;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, code(funct5.add, 0, 2, 1, 3)));
}

test "a misaligned SC.W is refused even where it holds no reservation and would have stored nothing, section 8.2" {
    var m: Mem = .{};
    var s: State = .{};
    s.x[1] = 2;
    s.x[3] = 0x1234;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, code(funct5.sc, 0, 2, 1, 3)));
    try std.testing.expectEqual(@as(u32, 0x1234), s.x[3]);
}

test "an atomic the memory answers nothing for is a data fault and changes no register, section 8.4" {
    for ([_]u32{ funct5.lr, funct5.swap, funct5.max }) |f5| {
        var m: Mem = .{};
        var s: State = .{};
        s.x[1] = Mem.refused;
        s.x[3] = 0x1234;
        try std.testing.expectEqual(.data_fault, exec(&s, &m, code(f5, 0, secondOf(f5), 1, 3)));
        try std.testing.expectEqual(@as(u32, 0x1234), s.x[3]);
        try std.testing.expectEqual(@as(?u32, null), s.reservation);
    }
}

test "an SC.W the memory answers nothing for is a data fault rather than a fail code, since it held the reservation the store needed" {
    var m: Mem = .{};
    var s: State = .{};
    s.reservation = Mem.refused;
    s.x[1] = Mem.refused;
    s.x[3] = 0x1234;
    try std.testing.expectEqual(.data_fault, exec(&s, &m, code(funct5.sc, 0, 2, 1, 3)));
    try std.testing.expectEqual(@as(u32, 0x1234), s.x[3]);
}

test "the acquire and release bits are accepted and ignored, so all four combinations do the same thing, section 8.1" {
    for ([_]u32{ 0, aq, rl, aq | rl }) |ordering| {
        var m: Mem = .{};
        var s: State = .{};
        m.put(8, 10);
        s.x[1] = 8;
        s.x[2] = 5;
        try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.add, ordering, 2, 1, 3)));
        try std.testing.expectEqual(@as(u32, 10), s.x[3]);
        try std.testing.expectEqual(@as(u32, 15), m.word(8));
        try std.testing.expectEqual(.next, exec(&s, &m, code(funct5.lr, ordering, 0, 1, 3)));
        try std.testing.expectEqual(@as(?u32, 8), s.reservation);
    }
}

test "a row prints the ordering suffix the assembler wrote and its operands in the order the manual writes them, section 8.1" {
    try std.testing.expectEqualStrings("lr.w a0, (a1)", try render(code(funct5.lr, 0, 0, 11, 10)));
    try std.testing.expectEqualStrings("lr.w.aq a0, (a1)", try render(code(funct5.lr, aq, 0, 11, 10)));
    try std.testing.expectEqualStrings("lr.w.rl a0, (a1)", try render(code(funct5.lr, rl, 0, 11, 10)));
    try std.testing.expectEqualStrings("lr.w.aqrl a0, (a1)", try render(code(funct5.lr, aq | rl, 0, 11, 10)));
    try std.testing.expectEqualStrings("sc.w.aqrl a0, a2, (a1)", try render(code(funct5.sc, aq | rl, 12, 11, 10)));
    try std.testing.expectEqualStrings("amoswap.w a0, a2, (a1)", try render(code(funct5.swap, 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amoadd.w.aq a0, a2, (a1)", try render(code(funct5.add, aq, 12, 11, 10)));
    try std.testing.expectEqualStrings("amoxor.w a0, a2, (a1)", try render(code(funct5.xor, 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amoand.w a0, a2, (a1)", try render(code(funct5.@"and", 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amoor.w a0, a2, (a1)", try render(code(funct5.@"or", 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amomin.w a0, a2, (a1)", try render(code(funct5.min, 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amomax.w a0, a2, (a1)", try render(code(funct5.max, 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amominu.w a0, a2, (a1)", try render(code(funct5.minu, 0, 12, 11, 10)));
    try std.testing.expectEqualStrings("amomaxu.w a0, a2, (a1)", try render(code(funct5.maxu, 0, 12, 11, 10)));
}

test "an AMO on a doubleword is no row of a 32-bit hart, section 8.4" {
    try std.testing.expectEqualStrings("undefined", try render(funct5.swap << 27 | 0b011 << 12 | amo_opcode));
    try std.testing.expectEqualStrings("undefined", try render(funct5.lr << 27 | 0b011 << 12 | amo_opcode));
}

test "the A rows are a group of their own, so a word that leaves the group out decodes none of them" {
    const without_a = comptime decode.only(&.{ .rv32i, .m, .c, .zicsr });
    inline for (.{ funct5.lr, funct5.sc, funct5.swap, funct5.add, funct5.xor, funct5.@"and", funct5.@"or", funct5.min, funct5.max, funct5.minu, funct5.maxu }) |f5| {
        try std.testing.expectEqual(tree.undefined_index, tree.indexWide(code(f5, 0, 2, 1, 3), without_a));
    }
}
