//! Tests of the RV32C rows: each compressed instruction runs beside the 32-bit form the manual
//! expands it into and must leave registers and memory alike, section 27.1. Also the reserved code
//! points, HINTs, unallocated encodings, mixed-width streams, cycle classes, group selection and
//! rendering.
const std = @import("std");
const State = @import("state.zig").State;
const instruction = @import("instruction.zig");
const Class = instruction.Class;
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

    fn fill(self: *Self) void {
        for (&self.bytes, 0..) |*b, i| b.* = @intCast(i);
    }

    fn place(self: *Self, address: u32, halves: []const u16) void {
        for (halves, 0..) |half, i| _ = self.poke(u16, address + @as(u32, @intCast(i)) * 2, half);
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

    fn poke(self: *Self, comptime T: type, address: u32, value: T) ?void {
        std.mem.writeInt(T, self.slice(address, @sizeOf(T)) orelse return null, value, .little);
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

fn ciw(nzuimm: u32, rd: u32) u16 {
    return @intCast(((nzuimm >> 4) & 3) << 11 | ((nzuimm >> 6) & 0xf) << 7 |
        ((nzuimm >> 2) & 1) << 6 | ((nzuimm >> 3) & 1) << 5 | (rd - 8) << 2);
}

fn cl(funct3: u32, offset: u32, rs1: u32, rd: u32) u16 {
    return @intCast(funct3 << 13 | ((offset >> 3) & 7) << 10 | (rs1 - 8) << 7 |
        ((offset >> 2) & 1) << 6 | ((offset >> 6) & 1) << 5 | (rd - 8) << 2);
}

fn ci(funct3: u32, imm: u32, rd: u32, op: u32) u16 {
    return @intCast(funct3 << 13 | ((imm >> 5) & 1) << 12 | rd << 7 | (imm & 0x1f) << 2 | op);
}

fn lwsp(offset: u32, rd: u32) u16 {
    return @intCast(0b010 << 13 | ((offset >> 5) & 1) << 12 | rd << 7 |
        ((offset >> 2) & 7) << 4 | ((offset >> 6) & 3) << 2 | 0b10);
}

fn swsp(offset: u32, rs2: u32) u16 {
    return @intCast(0b110 << 13 | ((offset >> 2) & 0xf) << 9 | ((offset >> 6) & 3) << 7 | rs2 << 2 | 0b10);
}

fn cj(funct3: u32, offset: i32) u16 {
    const imm: u32 = @bitCast(offset);
    return @intCast(funct3 << 13 | ((imm >> 11) & 1) << 12 | ((imm >> 4) & 1) << 11 |
        ((imm >> 8) & 3) << 9 | ((imm >> 10) & 1) << 8 | ((imm >> 6) & 1) << 7 |
        ((imm >> 7) & 1) << 6 | ((imm >> 1) & 7) << 3 | ((imm >> 5) & 1) << 2 | 0b01);
}

fn cb(funct3: u32, offset: i32, rs1: u32) u16 {
    const imm: u32 = @bitCast(offset);
    return @intCast(funct3 << 13 | ((imm >> 8) & 1) << 12 | ((imm >> 3) & 3) << 10 | (rs1 - 8) << 7 |
        ((imm >> 6) & 3) << 5 | ((imm >> 1) & 3) << 3 | ((imm >> 5) & 1) << 2 | 0b01);
}

fn cbi(funct2: u32, imm: u32, rd: u32) u16 {
    return @intCast(0b100 << 13 | ((imm >> 5) & 1) << 12 | funct2 << 10 | (rd - 8) << 7 |
        (imm & 0x1f) << 2 | 0b01);
}

fn ca(funct2: u32, rd: u32, rs2: u32) u16 {
    return @intCast(0b100011 << 10 | (rd - 8) << 7 | funct2 << 5 | (rs2 - 8) << 2 | 0b01);
}

fn cr(funct4: u32, rd: u32, rs2: u32) u16 {
    return @intCast(funct4 << 12 | rd << 7 | rs2 << 2 | 0b10);
}

fn addi16sp(nzimm: i32) u16 {
    const imm: u32 = @bitCast(nzimm);
    return @intCast(0b011 << 13 | ((imm >> 9) & 1) << 12 | 2 << 7 | ((imm >> 4) & 1) << 6 |
        ((imm >> 6) & 1) << 5 | ((imm >> 7) & 3) << 3 | ((imm >> 5) & 1) << 2 | 0b01);
}

fn clui(imm: u32, rd: u32) u16 {
    return @intCast(0b011 << 13 | ((imm >> 17) & 1) << 12 | rd << 7 | ((imm >> 12) & 0x1f) << 2 | 0b01);
}

fn typeR(funct7: u32, rs2: u32, rs1: u32, funct3: u32, rd: u32, opcode: u32) u32 {
    return funct7 << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode;
}

fn typeI(imm: i32, rs1: u32, funct3: u32, rd: u32, opcode: u32) u32 {
    const value: u32 = @as(u12, @truncate(@as(u32, @bitCast(imm))));
    return value << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode;
}

fn typeS(imm: i32, rs2: u32, rs1: u32, funct3: u32) u32 {
    const value: u32 = @as(u12, @truncate(@as(u32, @bitCast(imm))));
    return (value >> 5) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | (value & 0x1f) << 7 | 0b0100011;
}

fn typeB(imm: i32, rs2: u32, rs1: u32, funct3: u32) u32 {
    const value: u32 = @as(u13, @truncate(@as(u32, @bitCast(imm))));
    return (value >> 12) << 31 | ((value >> 5) & 0x3f) << 25 | rs2 << 20 | rs1 << 15 |
        funct3 << 12 | ((value >> 1) & 0xf) << 8 | ((value >> 11) & 1) << 7 | 0b1100011;
}

const op_imm: u32 = 0b0010011;
const op_reg: u32 = 0b0110011;
const zero: u32 = 0;
const sp: u32 = 2;

fn addi(rd: u32, rs1: u32, imm: i32) u32 {
    return typeI(imm, rs1, 0b000, rd, op_imm);
}

fn lui(rd: u32, imm: u32) u32 {
    return imm << 12 | rd << 7 | 0b0110111;
}

const Start = struct { at: u5, value: u32 };

fn expands(start: []const Start, parcel: u16, code: u32) !void {
    var cs: State = .{};
    var bs: State = .{};
    var cm: Mem = .{};
    var bm: Mem = .{};
    cm.fill();
    bm.fill();
    for (start) |r| {
        cs.x[r.at] = r.value;
        bs.x[r.at] = r.value;
    }
    try std.testing.expectEqual(exec(&bs, &bm, code), exec(&cs, &cm, parcel));
    try std.testing.expectEqualSlices(u32, &bs.x, &cs.x);
    try std.testing.expectEqualSlices(u8, &bm.bytes, &cm.bytes);
    try std.testing.expectEqual(bs.pc, cs.pc);
}

fn apply(start: []const Start, parcel: u16, read: u5) !u32 {
    var s: State = .{};
    var m: Mem = .{};
    m.fill();
    for (start) |r| s.x[r.at] = r.value;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, parcel));
    return s.x[read];
}

const costs: step.Model.Costs = blk: {
    var out: step.Model.Costs = @splat(.{ .cycles = 1, .taken = 0 });
    out[@intFromEnum(Class.load)] = .{ .cycles = 2, .taken = 0 };
    out[@intFromEnum(Class.jump)] = .{ .cycles = 1, .taken = 1 };
    break :blk out;
};

fn run(s: *State, m: *Mem, groups: decode.Groups) step.Result {
    return step.step(Mem, null, s, m, .{ .decoding = groups, .costs = costs });
}

fn render(code: u32, groups: decode.Groups) ![]const u8 {
    const S = struct {
        var buffer: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buffer);
    try disasm.write(&w, code, 0x4200_0000, groups);
    return w.buffered();
}

fn decoded(parcel: u16) bool {
    return tree.indexNarrow(parcel, comptime decode.only(&.{ .rv32i, .m, .a, .c, .zicsr })) != tree.undefined_index;
}

test "C.ADDI4SPN adds the zero-extended immediate, scaled by four, to the stack pointer, section 27.5.2" {
    const start = [_]Start{.{ .at = 2, .value = 0x1000 }};
    try expands(&start, ciw(4, 10), addi(10, sp, 4));
    try expands(&start, ciw(1020, 15), addi(15, sp, 1020));
    try expands(&start, ciw(12, 8), addi(8, sp, 12));
    try std.testing.expectEqual(@as(u32, 0x1000 + 1020), try apply(&start, ciw(1020, 15), 15));
}

test "the C.ADDI4SPN code points with nzuimm zero are reserved, and the parcel of all zeroes is one of them, sections 27.5.2 and 27.5.4" {
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, ciw(0, 10)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, @as(u16, 0)));
    m.place(0, &.{0x0000});
    try std.testing.expectEqual(step.Trap.illegal_instruction, run(&s, &m, decode.every).trap);
}

test "C.LW and C.SW scale their offset by four and reach the eight registers of table 38, section 27.3.2" {
    const start = [_]Start{ .{ .at = 13, .value = 8 }, .{ .at = 14, .value = 0xdead_beef }, .{ .at = 12, .value = 0x1234_5678 } };
    try expands(&start, cl(0b010, 0, 13, 14), typeI(0, 13, 0b010, 14, 0b0000011));
    try expands(&start, cl(0b010, 20, 13, 14), typeI(20, 13, 0b010, 14, 0b0000011));
    try expands(&start, cl(0b110, 4, 13, 12), typeS(4, 12, 13, 0b010));
    try expands(&start, cl(0b110, 52, 13, 12), typeS(52, 12, 13, 0b010));
    try std.testing.expectEqual(@as(u32, 0x1b1a_1918), try apply(&start, cl(0b010, 16, 13, 14), 14));
}

test "C.LWSP and C.SWSP reach the stack through x2 and carry the wider offset the CI and CSS formats hold, section 27.3.1" {
    const start = [_]Start{ .{ .at = 2, .value = 4 }, .{ .at = 5, .value = 0x0f0f_0f0f } };
    try expands(&start, lwsp(0, 5), typeI(0, sp, 0b010, 5, 0b0000011));
    try expands(&start, lwsp(56, 5), typeI(56, sp, 0b010, 5, 0b0000011));
    try expands(&start, swsp(8, 5), typeS(8, 5, sp, 0b010));
    try std.testing.expectEqual(@as(u32, 0x0b0a_0908), try apply(&start, lwsp(4, 5), 5));
}

test "the C.LWSP code points with rd=x0 are reserved, section 27.3.1" {
    var s: State = .{};
    var m: Mem = .{};
    m.fill();
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, lwsp(0, 0)));
    try std.testing.expect(!decoded(lwsp(0, 0)));
}

test "C.LI loads and C.ADDI adds the sign-extended six-bit immediate, sections 27.5.1 and 27.5.2" {
    const start = [_]Start{.{ .at = 10, .value = 100 }};
    try expands(&start, ci(0b010, 5, 10, 0b01), addi(10, zero, 5));
    try expands(&start, ci(0b010, 0x3f, 10, 0b01), addi(10, zero, -1));
    try expands(&start, ci(0b010, 0x20, 10, 0b01), addi(10, zero, -32));
    try expands(&start, ci(0b000, 5, 10, 0b01), addi(10, 10, 5));
    try expands(&start, ci(0b000, 0x3f, 10, 0b01), addi(10, 10, -1));
    try std.testing.expectEqual(@as(u32, 0xffff_ffe0), try apply(&start, ci(0b010, 0x20, 10, 0b01), 10));
    try std.testing.expectEqual(@as(u32, 99), try apply(&start, ci(0b000, 0x3f, 10, 0b01), 10));
}

test "C.LUI writes the immediate to bits 17 to 12 and sign-extends bit 17 upwards, and its zero immediate is reserved, section 27.5.1" {
    try expands(&.{}, clui(0x1f000, 10), lui(10, 0x1f));
    try expands(&.{}, clui(0xfffe_0000, 10), lui(10, 0xf_ffe0));
    try std.testing.expectEqual(@as(u32, 0x0001_f000), try apply(&.{}, clui(0x1f000, 10), 10));
    try std.testing.expectEqual(@as(u32, 0xfffe_0000), try apply(&.{}, clui(0x2_0000, 10), 10));
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, clui(0, 10)));
    try std.testing.expect(!decoded(clui(0, 10)));
}

test "C.ADDI16SP scales its immediate by sixteen, and its zero immediate is reserved, section 27.5.2" {
    const start = [_]Start{.{ .at = 2, .value = 0x1000 }};
    try expands(&start, addi16sp(48), addi(sp, sp, 48));
    try expands(&start, addi16sp(-512), addi(sp, sp, -512));
    try expands(&start, addi16sp(496), addi(sp, sp, 496));
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, addi16sp(0)));
    try std.testing.expect(!decoded(addi16sp(0)));
}

test "C.SRLI, C.SRAI and C.ANDI work on rd′ in place, the shifts zero-extending their amount and the mask sign-extending its immediate, section 27.5.2" {
    const start = [_]Start{.{ .at = 13, .value = 0x8000_00f0 }};
    try expands(&start, cbi(0b00, 1, 13), typeI(1, 13, 0b101, 13, op_imm));
    try expands(&start, cbi(0b00, 31, 13), typeI(31, 13, 0b101, 13, op_imm));
    try expands(&start, cbi(0b01, 31, 13), typeR(0b0100000, 31, 13, 0b101, 13, op_imm));
    try expands(&start, cbi(0b10, 0x3f, 13), typeI(-1, 13, 0b111, 13, op_imm));
    try expands(&start, cbi(0b10, 0x0f, 13), typeI(15, 13, 0b111, 13, op_imm));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), try apply(&start, cbi(0b00, 31, 13), 13));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(&start, cbi(0b01, 31, 13), 13));
}

test "the RV32 code points of C.SRLI, C.SRAI and C.SLLI with shamt bit five set belong to custom extensions, so no row of this core decodes them, section 27.5.2" {
    try std.testing.expect(!decoded(cbi(0b00, 32, 13)));
    try std.testing.expect(!decoded(cbi(0b01, 32, 13)));
    try std.testing.expect(!decoded(ci(0b000, 32, 10, 0b10)));
    try std.testing.expect(decoded(cbi(0b10, 32, 13)));
}

test "C.SLLI shifts rd in place by the shamt the CI format holds, section 27.5.2" {
    const start = [_]Start{.{ .at = 10, .value = 3 }};
    try expands(&start, ci(0b000, 1, 10, 0b10), typeI(1, 10, 0b001, 10, op_imm));
    try expands(&start, ci(0b000, 31, 10, 0b10), typeI(31, 10, 0b001, 10, op_imm));
    try std.testing.expectEqual(@as(u32, 6), try apply(&start, ci(0b000, 1, 10, 0b10), 10));
}

test "the CA-format C.SUB, C.XOR, C.OR and C.AND take rd′ as their first source, section 27.5.3" {
    const start = [_]Start{ .{ .at = 13, .value = 0xf0f0_ff00 }, .{ .at = 14, .value = 0x0f0f_00ff } };
    try expands(&start, ca(0b00, 13, 14), typeR(0b0100000, 14, 13, 0b000, 13, op_reg));
    try expands(&start, ca(0b01, 13, 14), typeR(0, 14, 13, 0b100, 13, op_reg));
    try expands(&start, ca(0b10, 13, 14), typeR(0, 14, 13, 0b110, 13, op_reg));
    try expands(&start, ca(0b11, 13, 14), typeR(0, 14, 13, 0b111, 13, op_reg));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), try apply(&start, ca(0b10, 13, 14), 13));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), try apply(&start, ca(0b11, 13, 14), 13));
}

test "C.MV expands to an add of x0 and C.ADD to an add of rd, section 27.5.3" {
    const start = [_]Start{ .{ .at = 10, .value = 7 }, .{ .at = 11, .value = 35 } };
    try expands(&start, cr(0b1000, 10, 11), typeR(0, 11, zero, 0b000, 10, op_reg));
    try expands(&start, cr(0b1001, 10, 11), typeR(0, 11, 10, 0b000, 10, op_reg));
    try std.testing.expectEqual(@as(u32, 35), try apply(&start, cr(0b1000, 10, 11), 10));
    try std.testing.expectEqual(@as(u32, 42), try apply(&start, cr(0b1001, 10, 11), 10));
}

test "C.J takes the sign-extended CJ offset from the jump itself and C.JAL links the parcel after it, section 27.4" {
    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cj(0b101, 32)));
    try std.testing.expectEqual(@as(u32, 0x4200_0120), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.x[1]);

    s = .{ .pc = 0x4200_0100 };
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cj(0b101, -2048)));
    try std.testing.expectEqual(@as(u32, 0x41ff_f900), s.pc);

    s = .{ .pc = 0x4200_0100 };
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cj(0b001, 2046)));
    try std.testing.expectEqual(@as(u32, 0x4200_08fe), s.pc);
    try std.testing.expectEqual(@as(u32, 0x4200_0102), s.x[1]);
}

test "C.BEQZ and C.BNEZ compare rs1′ against zero and reach the sign-extended CB offset, section 27.4" {
    const taken = [_]Start{.{ .at = 13, .value = 0 }};
    const not = [_]Start{.{ .at = 13, .value = 1 }};
    try expands(&taken, cb(0b110, 24, 13), typeB(24, zero, 13, 0b000));
    try expands(&not, cb(0b110, 24, 13), typeB(24, zero, 13, 0b000));
    try expands(&taken, cb(0b111, -8, 13), typeB(-8, zero, 13, 0b001));
    try expands(&not, cb(0b111, -256, 13), typeB(-256, zero, 13, 0b001));

    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cb(0b110, -256, 13)));
    try std.testing.expectEqual(@as(u32, 0x4200_0000), s.pc);
}

test "C.JR jumps to rs1 with its low bit cleared and C.JALR links the parcel after it, section 27.4" {
    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    s.x[15] = 0x4200_0201;
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cr(0b1000, 15, 0)));
    try std.testing.expectEqual(@as(u32, 0x4200_0200), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.x[1]);

    s.pc = 0x4200_0100;
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, &m, cr(0b1001, 15, 0)));
    try std.testing.expectEqual(@as(u32, 0x4200_0200), s.pc);
    try std.testing.expectEqual(@as(u32, 0x4200_0102), s.x[1]);
}

test "the C.JR code point with rs1=x0 is reserved and the C.JALR one is C.EBREAK, sections 27.4 and 27.5.6" {
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, cr(0b1000, 0, 0)));
    try std.testing.expectEqual(instruction.Outcome.breakpoint, exec(&s, &m, cr(0b1001, 0, 0)));
    try std.testing.expectEqual(@as(u16, 0x9002), cr(0b1001, 0, 0));
}

test "the HINT code points of table 39 are executed as the computations they encode, so they change nothing" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[11] = 42;
    inline for (.{
        ci(0b000, 1, 0, 0b01),
        ci(0b000, 0, 10, 0b01),
        ci(0b010, 5, 0, 0b01),
        clui(0x1f000, 0),
        cr(0b1000, 0, 11),
        cr(0b1001, 0, 11),
        ci(0b000, 0, 10, 0b10),
        cbi(0b00, 0, 13),
        cbi(0b01, 0, 13),
    }) |parcel| {
        const before = s;
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, @as(u16, parcel)));
        try std.testing.expectEqualSlices(u32, &before.x, &s.x);
        try std.testing.expectEqual(before.pc, s.pc);
    }
}

test "the code points figures 3, 4 and 5 leave unallocated on RV32 decode to no row at all" {
    try std.testing.expect(!decoded(0b001 << 13 | 0b00));
    try std.testing.expect(!decoded(0b011 << 13 | 0b00));
    try std.testing.expect(!decoded(0b100 << 13 | 0b00));
    try std.testing.expect(!decoded(0b101 << 13 | 0b00));
    try std.testing.expect(!decoded(0b111 << 13 | 0b00));
    try std.testing.expect(!decoded(0b100111 << 10 | 0b00 << 5 | 0b01));
    try std.testing.expect(!decoded(0b100111 << 10 | 0b01 << 5 | 0b01));
    try std.testing.expect(!decoded(0b100111 << 10 | 0b10 << 5 | 0b01));
    try std.testing.expect(!decoded(0b001 << 13 | 0b10));
    try std.testing.expect(!decoded(0b011 << 13 | 0b10));
    try std.testing.expect(!decoded(0b101 << 13 | 0b10));
    try std.testing.expect(!decoded(0b111 << 13 | 0b10));
}

test "a stream of 16-bit and 32-bit instructions advances the program counter by two and by four, section 27.1" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{ ci(0b010, 5, 10, 0b01), 0x0593, 0x0035, cr(0b1001, 10, 11), 0x9002 });
    const first = run(&s, &m, decode.every);
    try std.testing.expectEqual(@as(?u32, 0x4515), first.fetchedCode());
    try std.testing.expectEqual(@as(u32, 2), s.pc);
    try std.testing.expectEqual(@as(u32, 5), s.x[10]);

    const second = run(&s, &m, decode.every);
    try std.testing.expectEqual(@as(?u32, 0x0035_0593), second.fetchedCode());
    try std.testing.expectEqual(@as(u32, 6), s.pc);
    try std.testing.expectEqual(@as(u32, 8), s.x[11]);

    const third = run(&s, &m, decode.every);
    try std.testing.expectEqual(@as(?u32, 0x952e), third.fetchedCode());
    try std.testing.expectEqual(@as(u32, 8), s.pc);
    try std.testing.expectEqual(@as(u32, 13), s.x[10]);

    try std.testing.expectEqual(@as(?step.Stop, .breakpoint), run(&s, &m, decode.every).halt());
    try std.testing.expectEqual(@as(u32, 8), s.pc);
}

test "a compressed row is charged the class of the instruction it expands to, so its shorter encoding costs nothing and saves nothing" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[13] = 8;
    m.place(0, &.{ cl(0b010, 0, 13, 14), cj(0b101, 2), ci(0b010, 5, 10, 0b01) });
    const load = run(&s, &m, decode.every);
    try std.testing.expectEqual(Class.load, load.class);
    try std.testing.expectEqual(@as(u8, 2), load.cycles);
    const jump = run(&s, &m, decode.every);
    try std.testing.expectEqual(Class.jump, jump.class);
    try std.testing.expectEqual(@as(u8, 2), jump.cycles);
    try std.testing.expect(jump.branched);
    const compute = run(&s, &m, decode.every);
    try std.testing.expectEqual(Class.data_processing, compute.class);
    try std.testing.expectEqual(@as(u8, 1), compute.cycles);
}

test "a jump lands two past a word boundary and the instruction there executes, since C makes IALIGN sixteen, section 27.1" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{ cj(0b101, 6), 0x0000, 0x0000, 0x0593, 0x0035 });
    try std.testing.expect(run(&s, &m, decode.every).branched);
    try std.testing.expectEqual(@as(u32, 6), s.pc);
    const straddling = run(&s, &m, decode.every);
    try std.testing.expectEqual(@as(?u32, 0x0035_0593), straddling.fetchedCode());
    try std.testing.expectEqual(@as(u32, 10), s.pc);
    try std.testing.expectEqual(@as(u32, 3), s.x[11]);
}

const without_c = decode.only(&.{ .rv32i, .m });

test "a compressed row is undefined on a core whose Spec does not select the C group, table 40" {
    try std.testing.expect(decoded(0x4515));
    try std.testing.expectEqualStrings("undefined", try render(0x4515, without_c));
    try std.testing.expectEqualStrings("c.li a0, 5", try render(0x4515, decode.every));

    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{0x4515});
    const r = run(&s, &m, without_c);
    try std.testing.expectEqual(step.Trap.illegal_instruction, r.trap);
    try std.testing.expectEqual(@as(?u32, 0x4515), r.fetchedCode());
    try std.testing.expectEqual(@as(u32, 0), s.x[10]);
}

test "each row renders as the mnemonic and operands the assembler takes for it, section 27.8" {
    try std.testing.expectEqualStrings("c.addi4spn a0, sp, 4", try render(0x0048, decode.every));
    try std.testing.expectEqualStrings("c.addi4spn a5, sp, 1020", try render(0x1ffc, decode.every));
    try std.testing.expectEqualStrings("c.lw a4, 0(a3)", try render(0x4298, decode.every));
    try std.testing.expectEqualStrings("c.lw a4, 124(a3)", try render(0x5ef8, decode.every));
    try std.testing.expectEqualStrings("c.sw a2, 4(a1)", try render(0xc1d0, decode.every));
    try std.testing.expectEqualStrings("c.nop", try render(0x0001, decode.every));
    try std.testing.expectEqualStrings("c.addi a0, 5", try render(0x0515, decode.every));
    try std.testing.expectEqualStrings("c.addi a0, -32", try render(0x1501, decode.every));
    try std.testing.expectEqualStrings("c.jal 0x42000002", try render(0x2009, decode.every));
    try std.testing.expectEqualStrings("c.li a0, 5", try render(0x4515, decode.every));
    try std.testing.expectEqualStrings("c.li a0, -1", try render(0x557d, decode.every));
    try std.testing.expectEqualStrings("c.addi16sp sp, 48", try render(0x6145, decode.every));
    try std.testing.expectEqualStrings("c.addi16sp sp, -512", try render(0x7101, decode.every));
    try std.testing.expectEqualStrings("c.lui a0, 0x1f", try render(0x657d, decode.every));
    try std.testing.expectEqualStrings("c.lui a0, 0xfffe0", try render(0x7501, decode.every));
    try std.testing.expectEqualStrings("c.srli a3, 1", try render(0x8285, decode.every));
    try std.testing.expectEqualStrings("c.srai a3, 31", try render(0x86fd, decode.every));
    try std.testing.expectEqualStrings("c.andi a3, -1", try render(0x9afd, decode.every));
    try std.testing.expectEqualStrings("c.sub a3, a4", try render(0x8e99, decode.every));
    try std.testing.expectEqualStrings("c.xor a3, a4", try render(0x8eb9, decode.every));
    try std.testing.expectEqualStrings("c.or a3, a4", try render(0x8ed9, decode.every));
    try std.testing.expectEqualStrings("c.and a3, a4", try render(0x8ef9, decode.every));
    try std.testing.expectEqualStrings("c.j 0x42000002", try render(0xa009, decode.every));
    try std.testing.expectEqualStrings("c.beqz a3, 0x42000002", try render(0xc289, decode.every));
    try std.testing.expectEqualStrings("c.bnez a3, 0x42000002", try render(0xe289, decode.every));
    try std.testing.expectEqualStrings("c.slli a0, 1", try render(0x0506, decode.every));
    try std.testing.expectEqualStrings("c.lwsp a0, 0(sp)", try render(0x4502, decode.every));
    try std.testing.expectEqualStrings("c.lwsp a0, 252(sp)", try render(0x557e, decode.every));
    try std.testing.expectEqualStrings("c.jr a5", try render(0x8782, decode.every));
    try std.testing.expectEqualStrings("c.mv a0, a1", try render(0x852e, decode.every));
    try std.testing.expectEqualStrings("c.ebreak", try render(0x9002, decode.every));
    try std.testing.expectEqualStrings("c.jalr a5", try render(0x9782, decode.every));
    try std.testing.expectEqualStrings("c.add a0, a1", try render(0x952e, decode.every));
    try std.testing.expectEqualStrings("c.swsp a0, 0(sp)", try render(0xc02a, decode.every));
    try std.testing.expectEqualStrings("c.swsp a0, 252(sp)", try render(0xdfaa, decode.every));
}
