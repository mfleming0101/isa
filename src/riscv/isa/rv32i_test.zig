//! Tests of the RV32I rows over a stub memory: immediate and register arithmetic, shifts, LUI and
//! AUIPC, jumps and branches, loads and stores with sign extension, a misaligned access under a
//! model that answers one and under a model that refuses it, unanswered accesses, FENCE, ECALL and
//! EBREAK. Registered in `src/tests.zig`.
const std = @import("std");
const State = @import("state.zig").State;
const instruction = @import("instruction.zig");
const decode = @import("decode.zig");
const csr = @import("csr.zig");
const step = @import("step.zig");

/// A 64-byte stub memory that answers every requirement a row can call.
pub const Mem = struct {
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

    fn peek(self: *Self, comptime T: type, address: u32) ?T {
        return std.mem.readInt(T, self.slice(address, @sizeOf(T)) orelse return null, .little);
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

const refusing: csr.Implementation = blk: {
    var out = csr.sail;
    out.misaligned = .refused;
    break :blk out;
};

const op_imm: u32 = 0b0010011;
const op_reg: u32 = 0b0110011;
const op_load: u32 = 0b0000011;
const op_store: u32 = 0b0100011;
const op_branch: u32 = 0b1100011;
const op_lui: u32 = 0b0110111;
const op_auipc: u32 = 0b0010111;
const op_jal: u32 = 0b1101111;
const op_jalr: u32 = 0b1100111;

fn typeR(funct7: u32, rs2: u32, rs1: u32, funct3: u32, rd: u32, opcode: u32) u32 {
    return funct7 << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode;
}

fn typeI(imm: i32, rs1: u32, funct3: u32, rd: u32, opcode: u32) u32 {
    const value: u32 = @as(u12, @truncate(@as(u32, @bitCast(imm))));
    return value << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode;
}

fn typeS(imm: i32, rs2: u32, rs1: u32, funct3: u32) u32 {
    const value: u32 = @as(u12, @truncate(@as(u32, @bitCast(imm))));
    return (value >> 5) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | (value & 0x1f) << 7 | op_store;
}

fn typeB(imm: i32, rs2: u32, rs1: u32, funct3: u32) u32 {
    const value: u32 = @as(u13, @truncate(@as(u32, @bitCast(imm))));
    return (value >> 12) << 31 | ((value >> 5) & 0x3f) << 25 | rs2 << 20 | rs1 << 15 |
        funct3 << 12 | ((value >> 1) & 0xf) << 8 | ((value >> 11) & 1) << 7 | op_branch;
}

fn typeU(imm: u32, rd: u32, opcode: u32) u32 {
    return imm << 12 | rd << 7 | opcode;
}

fn typeJ(imm: i32, rd: u32) u32 {
    const value: u32 = @as(u21, @truncate(@as(u32, @bitCast(imm))));
    return (value >> 20) << 31 | ((value >> 1) & 0x3ff) << 21 | ((value >> 11) & 1) << 20 |
        ((value >> 12) & 0xff) << 12 | rd << 7 | op_jal;
}

test "ADDI adds the sign-extended immediate to rs1, section 2.4.1" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 10;
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(5, 1, 0b000, 2, op_imm)));
    try std.testing.expectEqual(@as(u32, 15), s.x[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(-12, 1, 0b000, 3, op_imm)));
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), s.x[3]);
}

test "a result written to x0 is discarded, section 2.1" {
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(5, 0, 0b000, 0, op_imm)));
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);
}

test "SLTI and SLTIU compare rs1 against the same sign-extended immediate, one as signed and one as unsigned, section 2.4.1" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(1, 1, 0b010, 2, op_imm)));
    try std.testing.expectEqual(@as(u32, 1), s.x[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(1, 1, 0b011, 3, op_imm)));
    try std.testing.expectEqual(@as(u32, 0), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(-1, 1, 0b011, 4, op_imm)));
    try std.testing.expectEqual(@as(u32, 0), s.x[4]);
}

test "XORI, ORI and ANDI combine rs1 with the sign-extended immediate, section 2.4.1" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0b1100;
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(0b1010, 1, 0b100, 2, op_imm)));
    try std.testing.expectEqual(@as(u32, 0b0110), s.x[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(0b1010, 1, 0b110, 3, op_imm)));
    try std.testing.expectEqual(@as(u32, 0b1110), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(-1, 1, 0b111, 4, op_imm)));
    try std.testing.expectEqual(@as(u32, 0b1100), s.x[4]);
}

test "SLLI, SRLI and SRAI shift by the shift amount, and only SRAI carries the sign in, section 2.4.1" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0x8000_0010;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 4, 1, 0b001, 2, op_imm)));
    try std.testing.expectEqual(@as(u32, 0x0000_0100), s.x[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 4, 1, 0b101, 3, op_imm)));
    try std.testing.expectEqual(@as(u32, 0x0800_0001), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0b0100000, 4, 1, 0b101, 4, op_imm)));
    try std.testing.expectEqual(@as(u32, 0xf800_0001), s.x[4]);
}

test "LUI writes the immediate to the high twenty bits and AUIPC adds it to the address of the instruction, section 2.4.1" {
    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    try std.testing.expectEqual(.next, exec(&s, &m, typeU(0x3fc80, 1, op_lui)));
    try std.testing.expectEqual(@as(u32, 0x3fc8_0000), s.x[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeU(1, 2, op_auipc)));
    try std.testing.expectEqual(@as(u32, 0x4200_1100), s.x[2]);
}

test "ADD, SUB and the register-register logic operate on two registers, section 2.4.2" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 7;
    s.x[2] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b000, 3, op_reg)));
    try std.testing.expectEqual(@as(u32, 10), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0b0100000, 2, 1, 0b000, 4, op_reg)));
    try std.testing.expectEqual(@as(u32, 4), s.x[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b100, 5, op_reg)));
    try std.testing.expectEqual(@as(u32, 4), s.x[5]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b110, 6, op_reg)));
    try std.testing.expectEqual(@as(u32, 7), s.x[6]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b111, 7, op_reg)));
    try std.testing.expectEqual(@as(u32, 3), s.x[7]);
}

test "SUB wraps rather than trapping on overflow, section 2.4.2" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0;
    s.x[2] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0b0100000, 2, 1, 0b000, 3, op_reg)));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.x[3]);
}

test "SLT reads the pair as signed and SLTU reads the same pair as unsigned, section 2.4.2" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0xffff_ffff;
    s.x[2] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b010, 3, op_reg)));
    try std.testing.expectEqual(@as(u32, 1), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b011, 4, op_reg)));
    try std.testing.expectEqual(@as(u32, 0), s.x[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 1, 1, 0b010, 5, op_reg)));
    try std.testing.expectEqual(@as(u32, 0), s.x[5]);
}

test "SLL, SRL and SRA take their amount from the low five bits of rs2, section 2.4.2" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0x8000_0010;
    s.x[2] = 0x24;
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b001, 3, op_reg)));
    try std.testing.expectEqual(@as(u32, 0x0000_0100), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0, 2, 1, 0b101, 4, op_reg)));
    try std.testing.expectEqual(@as(u32, 0x0800_0001), s.x[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeR(0b0100000, 2, 1, 0b101, 5, op_reg)));
    try std.testing.expectEqual(@as(u32, 0xf800_0001), s.x[5]);
}

test "JAL jumps by the multiple of two the offset spells and links the instruction after it, section 2.5.1" {
    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    try std.testing.expectEqual(.branched, exec(&s, &m, typeJ(-0x20, 1)));
    try std.testing.expectEqual(@as(u32, 0x4200_00e0), s.pc);
    try std.testing.expectEqual(@as(u32, 0x4200_0104), s.x[1]);
}

test "JALR clears the lowest bit of the sum and links the instruction after it, section 2.5.1" {
    var s: State = .{ .pc = 0x4200_0100 };
    var m: Mem = .{};
    s.x[1] = 0x4200_0203;
    try std.testing.expectEqual(.branched, exec(&s, &m, typeI(-4, 1, 0b000, 1, op_jalr)));
    try std.testing.expectEqual(@as(u32, 0x4200_01fe), s.pc);
    try std.testing.expectEqual(@as(u32, 0x4200_0104), s.x[1]);
}

test "the six branches jump by a multiple of two when the pair they compare agrees, section 2.5.2" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0xffff_ffff;
    s.x[2] = 1;
    const cases = [_]struct { funct3: u32, taken: bool }{
        .{ .funct3 = 0b000, .taken = false },
        .{ .funct3 = 0b001, .taken = true },
        .{ .funct3 = 0b100, .taken = true },
        .{ .funct3 = 0b101, .taken = false },
        .{ .funct3 = 0b110, .taken = false },
        .{ .funct3 = 0b111, .taken = true },
    };
    for (cases) |c| {
        s.pc = 0x4200_0100;
        const outcome = exec(&s, &m, typeB(-0x10, 2, 1, c.funct3));
        if (c.taken) {
            try std.testing.expectEqual(.branched, outcome);
            try std.testing.expectEqual(@as(u32, 0x4200_00f0), s.pc);
        } else {
            try std.testing.expectEqual(.next, outcome);
            try std.testing.expectEqual(@as(u32, 0x4200_0100), s.pc);
        }
    }
}

test "a branch comparing a register with itself is always equal, section 2.5.2" {
    var s: State = .{ .pc = 8 };
    var m: Mem = .{};
    try std.testing.expectEqual(.branched, exec(&s, &m, typeB(4, 1, 1, 0b000)));
    try std.testing.expectEqual(@as(u32, 12), s.pc);
}

test "LW and SW move a word at the address rs1 and the offset name, section 2.6" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 16;
    s.x[2] = 0xdead_beef;
    try std.testing.expectEqual(.next, exec(&s, &m, typeS(4, 2, 1, 0b010)));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), m.peek(u32, 20).?);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(4, 1, 0b010, 3, op_load)));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.x[3]);
}

test "LB and LH sign-extend what they load and LBU and LHU do not, section 2.6" {
    var s: State = .{};
    var m: Mem = .{};
    _ = m.poke(u32, 16, 0x8001_80ff);
    s.x[1] = 16;
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(0, 1, 0b000, 2, op_load)));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.x[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(0, 1, 0b100, 3, op_load)));
    try std.testing.expectEqual(@as(u32, 0x0000_00ff), s.x[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(2, 1, 0b001, 4, op_load)));
    try std.testing.expectEqual(@as(u32, 0xffff_8001), s.x[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(2, 1, 0b101, 5, op_load)));
    try std.testing.expectEqual(@as(u32, 0x0000_8001), s.x[5]);
}

test "SB and SH store the low bits of rs2 and leave the rest of the word alone, section 2.6" {
    var s: State = .{};
    var m: Mem = .{};
    _ = m.poke(u32, 16, 0xffff_ffff);
    s.x[1] = 16;
    s.x[2] = 0xaabb_ccdd;
    try std.testing.expectEqual(.next, exec(&s, &m, typeS(0, 2, 1, 0b000)));
    try std.testing.expectEqual(@as(u32, 0xffff_ffdd), m.peek(u32, 16).?);
    try std.testing.expectEqual(.next, exec(&s, &m, typeS(2, 2, 1, 0b001)));
    try std.testing.expectEqual(@as(u32, 0xccdd_ffdd), m.peek(u32, 16).?);
}

test "a hart whose model answers a misaligned load or store reads and writes the bytes at the address itself, Privileged 3.6" {
    var s: State = .{};
    var m: Mem = .{};
    _ = m.poke(u32, 16, 0x1234_5678);
    _ = m.poke(u32, 20, 0xaabb_ccdd);
    s.x[1] = 16;
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(1, 1, 0b010, 2, op_load)));
    try std.testing.expectEqual(@as(u32, 0xdd12_3456), s.x[2]);

    s.x[3] = 0x1122_3344;
    try std.testing.expectEqual(.next, exec(&s, &m, typeS(2, 3, 1, 0b010)));
    try std.testing.expectEqual(@as(u32, 0x3344_5678), m.peek(u32, 16).?);
    try std.testing.expectEqual(@as(u32, 0xaabb_1122), m.peek(u32, 20).?);
}

test "a hart whose model refuses a misaligned load or store faults before it reaches memory, Privileged 3.6" {
    var s: State = .{ .csr = .{ .implementation = refusing } };
    var m: Mem = .{};
    s.x[1] = 17;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, typeI(0, 1, 0b010, 2, op_load)));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, typeI(0, 1, 0b001, 2, op_load)));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, typeS(0, 2, 1, 0b010)));
    try std.testing.expectEqual(.next, exec(&s, &m, typeI(0, 1, 0b000, 2, op_load)));
}

test "a load or a store no memory answers faults, section 2.6" {
    var s: State = .{};
    var m: Mem = .{};
    s.x[1] = 0x1000;
    try std.testing.expectEqual(.data_fault, exec(&s, &m, typeI(0, 1, 0b010, 2, op_load)));
    try std.testing.expectEqual(.data_fault, exec(&s, &m, typeS(0, 2, 1, 0b000)));
}

test "FENCE orders nothing on a hart that runs one instruction at a time, section 2.7" {
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0ff0_000f));
    try std.testing.expectEqual(@as(u32, 0), s.x[1]);
}

test "ECALL and EBREAK hand the hart to its environment, section 2.8" {
    var s: State = .{};
    var m: Mem = .{};
    try std.testing.expectEqual(.environment_call, exec(&s, &m, 0x0000_0073));
    try std.testing.expectEqual(.breakpoint, exec(&s, &m, 0x0010_0073));
}
