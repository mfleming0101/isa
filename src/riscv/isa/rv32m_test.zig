//! Tests of the RV32M rows: how the four multiplies read their operands, division rounding, the
//! divide-by-zero and overflow cases of table 11, rendering, and that an M row is undefined without
//! the M group.
const std = @import("std");
const State = @import("state.zig").State;
const instruction = @import("instruction.zig");
const decode = @import("decode.zig");
const csr = @import("csr.zig");
const step = @import("step.zig");
const disasm = @import("riscv_disasm");
const tree = @import("riscv_decode");

const Mem = struct {
    /// Every group, so each row decodes.
    pub const allowed = decode.every;
    const Self = @This();

    bytes: [64]u8 = @splat(0),

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    /// Host requirement: a touched address is ignored here.
    pub fn touch(_: *Self, _: u32) void {}

    /// The bytes from an address to the end of the stub, or nothing where out of range.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        _ = self.slice(address, a.bytes) orelse return &.{};
        return self.bytes[address..];
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
};

fn exec(s: *State, m: *Mem, code: u32) instruction.Outcome {
    return step.call(Mem, s, m, code, Mem.allowed);
}

const op_reg: u32 = 0b0110011;
const muldiv: u32 = 0b0000001;

const funct3 = struct {
    const mul: u32 = 0b000;
    const mulh: u32 = 0b001;
    const mulhsu: u32 = 0b010;
    const mulhu: u32 = 0b011;
    const div: u32 = 0b100;
    const divu: u32 = 0b101;
    const rem: u32 = 0b110;
    const remu: u32 = 0b111;
};

fn typeR(f7: u32, rs2: u32, rs1: u32, f3: u32, rd: u32, opcode: u32) u32 {
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opcode;
}

fn apply(f3: u32, a: u32, b: u32) !u32 {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = a;
    s.x[2] = b;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(muldiv, 2, 1, f3, 3, op_reg)));
    return s.x[3];
}

fn render(code: u32, groups: decode.Groups) ![]const u8 {
    const S = struct {
        var buffer: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buffer);
    try disasm.write(&w, code, 0, groups);
    return w.buffered();
}

test "MUL keeps the lower thirty-two bits of the product, which the signedness of the operands cannot change, section 12.1" {
    try std.testing.expectEqual(@as(u32, 42), try apply(funct3.mul, 6, 7));
    try std.testing.expectEqual(@as(u32, 0xffff_ffe2), try apply(funct3.mul, 6, 0xffff_fffb));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), try apply(funct3.mul, 0xffff_ffff, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(funct3.mul, 0x8000_0000, 0x0000_0002));
}

test "MULH takes the upper half of the product of two signed operands, section 12.1" {
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(funct3.mulh, 6, 7));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.mulh, 6, 0xffff_fffb));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), try apply(funct3.mulh, 0x8000_0000, 0x8000_0000));
}

test "MULHU takes the upper half of the product of two unsigned operands, section 12.1" {
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(funct3.mulhu, 6, 7));
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), try apply(funct3.mulhu, 0xffff_ffff, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), try apply(funct3.mulhu, 0x8000_0000, 0x8000_0000));
}

test "MULHSU reads rs1 as signed and rs2 as unsigned, which is the multi-word case the manual gives it for, section 12.1" {
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(funct3.mulhsu, 6, 7));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.mulhsu, 0xffff_ffff, 0x0000_0002));
    try std.testing.expectEqual(@as(u32, 0xc000_0000), try apply(funct3.mulhsu, 0x8000_0000, 0x8000_0000));
}

test "the four multiply rows differ only in how they read the same pair of words, section 12.1" {
    const a: u32 = 0xffff_ffff;
    const b: u32 = 0x8000_0000;
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(funct3.mul, a, b));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(funct3.mulh, a, b));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.mulhsu, a, b));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), try apply(funct3.mulhu, a, b));
}

test "MULHSU is not symmetric, so exchanging its operands changes the answer, section 12.1" {
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.mulhsu, 0xffff_ffff, 0x8000_0000));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(funct3.mulhsu, 0x8000_0000, 0xffff_ffff));
}

test "DIV rounds towards zero rather than downwards, and REM carries the sign of the dividend, section 12.2" {
    try std.testing.expectEqual(@as(u32, 3), try apply(funct3.div, 7, 2));
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), try apply(funct3.div, 0xffff_fff9, 2));
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), try apply(funct3.div, 7, 0xffff_fffe));
    try std.testing.expectEqual(@as(u32, 1), try apply(funct3.rem, 7, 2));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.rem, 0xffff_fff9, 2));
    try std.testing.expectEqual(@as(u32, 1), try apply(funct3.rem, 7, 0xffff_fffe));
}

test "DIVU and REMU read the same pair of words as unsigned, section 12.2" {
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), try apply(funct3.divu, 0xffff_ffff, 2));
    try std.testing.expectEqual(@as(u32, 1), try apply(funct3.remu, 0xffff_ffff, 2));
    try std.testing.expectEqual(@as(u32, 0), try apply(funct3.div, 0xffff_ffff, 2));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.rem, 0xffff_ffff, 2));
}

test "a division by zero returns all ones and its remainder is the dividend, and neither stops the hart, table 11" {
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.div, 17, 0));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.divu, 17, 0));
    try std.testing.expectEqual(@as(u32, 17), try apply(funct3.rem, 17, 0));
    try std.testing.expectEqual(@as(u32, 17), try apply(funct3.remu, 17, 0));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(funct3.div, 0x8000_0000, 0));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(funct3.rem, 0x8000_0000, 0));
}

test "the most negative word divided by minus one is the one signed overflow, and it yields the dividend and a remainder of zero, table 11" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(funct3.div, 0x8000_0000, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0), try apply(funct3.rem, 0x8000_0000, 0xffff_ffff));
}

test "an unsigned division cannot overflow, so the same pair of words divides as any other, table 11" {
    try std.testing.expectEqual(@as(u32, 0), try apply(funct3.divu, 0x8000_0000, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), try apply(funct3.remu, 0x8000_0000, 0xffff_ffff));
}

test "the eight mnemonics render with the register names the calling convention gives, sections 12.1 and 12.2" {
    try std.testing.expectEqualStrings("mul a0, a1, a2", try render(0x02c5_8533, decode.every));
    try std.testing.expectEqualStrings("mulh a0, a1, a2", try render(0x02c5_9533, decode.every));
    try std.testing.expectEqualStrings("mulhsu a0, a1, a2", try render(0x02c5_a533, decode.every));
    try std.testing.expectEqualStrings("mulhu a0, a1, a2", try render(0x02c5_b533, decode.every));
    try std.testing.expectEqualStrings("div a0, a1, a2", try render(0x02c5_c533, decode.every));
    try std.testing.expectEqualStrings("divu a0, a1, a2", try render(0x02c5_d533, decode.every));
    try std.testing.expectEqualStrings("rem a0, a1, a2", try render(0x02c5_e533, decode.every));
    try std.testing.expectEqualStrings("remu a0, a1, a2", try render(0x02c5_f533, decode.every));
}

const without_m = decode.only(&.{.rv32i});

test "an M row is undefined on a core whose Spec does not select the M group, section 12.1" {
    inline for (.{ funct3.mul, funct3.mulh, funct3.mulhsu, funct3.mulhu, funct3.div, funct3.divu, funct3.rem, funct3.remu }) |f3| {
        const code = typeR(muldiv, 12, 11, f3, 10, op_reg);
        try std.testing.expect(!std.mem.eql(u8, "undefined", try render(code, decode.every)));
        try std.testing.expectEqualStrings("undefined", try render(code, without_m));
    }
    try std.testing.expectEqualStrings("undefined", try render(0x02c5_8533, without_m));
    try std.testing.expectEqualStrings("add a0, a1, a2", try render(0x00c5_8533, without_m));
}
