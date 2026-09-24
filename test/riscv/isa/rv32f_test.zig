//! Tests of the RV32F rows against a model whose unit is implemented: arithmetic, the rounding modes of table 25,
//! NaN and infinity handling, FCLASS, comparisons, conversions, sign injection, transfers, single
//! rounding of the fused rows, mstatus.FS gating, and the fcsr layout.
const std = @import("std");
const State = @import("../../../src/riscv/isa/state.zig").State;
const instruction = @import("../../../src/riscv/isa/instruction.zig");
const decode = @import("../../../src/riscv/isa/decode.zig");
const csr = @import("../../../src/riscv/isa/csr.zig");
const step = @import("../../../src/riscv/isa/step.zig");
const fp = @import("../../../src/sem/riscv/fp.zig");

const Mem = struct {
    /// Every group, so each row decodes.
    pub const allowed = decode.every;
    const Self = @This();

    bytes: [32]u8 = @splat(0),

    /// Host requirement: a touched address is ignored here.
    pub fn touch(_: *Self, _: u32) void {}

    /// The bytes from an address to the end of the stub, or nothing where out of range.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        if (@as(u64, address) + a.bytes > self.bytes.len) return &.{};
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

fn hart() State {
    var s: State = .{};
    s.csr.mstatus.fs = .dirty;
    return s;
}

fn exec(s: *State, m: *Mem, code: u32) instruction.Outcome {
    return step.call(Mem, s, m, code, Mem.allowed);
}

fn wide(funct7: u32, rs2: u32, rs1: u32, rm: u32, rd: u32) u32 {
    return funct7 << 25 | rs2 << 20 | rs1 << 15 | rm << 12 | rd << 7 | 0b1010011;
}

const fadd = 0b0000000;
const fsub = 0b0000100;
const fmul = 0b0001000;
const fdiv = 0b0001100;
const fsqrt = 0b0101100;
const fsgnj = 0b0010000;
const fminmax = 0b0010100;
const fcompare = 0b1010000;
const to_word = 0b1100000;
const from_word = 0b1101000;
const move_out = 0b1110000;
const move_in = 0b1111000;

const rtz: u32 = 0b001;
const rdn: u32 = 0b010;
const rup: u32 = 0b011;
const dyn: u32 = 0b111;
const one: u32 = 0x3f80_0000;
const two: u32 = 0x4000_0000;
const three: u32 = 0x4040_0000;
const quiet_nan: u32 = 0x7fc0_0000;
const signalling_nan: u32 = 0x7f80_0001;
const infinity: u32 = 0x7f80_0000;

test "FADD.S adds two singles and leaves every accrued flag clear, section 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = one;
    s.f[2] = two;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
    try std.testing.expectEqual(three, s.f[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}

test "FCVT.S.W rounds 2^24+1, the smallest word no single holds, as each of the five modes of table 25 says, and every one is inexact" {
    const expected = [_]struct { u32, u32 }{
        .{ 0b000, 0x4b80_0000 },
        .{ 0b001, 0x4b80_0000 },
        .{ 0b010, 0x4b80_0000 },
        .{ 0b011, 0x4b80_0001 },
        .{ 0b100, 0x4b80_0001 },
    };
    for (expected) |want| {
        var s = hart();
        var m: Mem = .{};
        s.x[1] = 1 << 24 | 1;
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(from_word, 0, 1, want[0], 2)));
        try std.testing.expectEqual(want[1], s.f[2]);
        try std.testing.expectEqual(fp.inexact, s.csr.fflags);
    }
}

test "a reserved rounding mode is an illegal instruction, section 20.2" {
    for ([_]u32{ 0b101, 0b110 }) |mode| {
        var s = hart();
        var m: Mem = .{};
        try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, wide(fadd, 2, 1, mode, 3)));
    }
    var s = hart();
    var m: Mem = .{};
    s.csr.frm = 0b101;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
}

test "a NaN out of an arithmetic row is the canonical NaN and a signalling input raises invalid, sections 20.3 and 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = quiet_nan;
    s.f[2] = one;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
    try std.testing.expectEqual(fp.canonical, s.f[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);

    s.f[1] = signalling_nan;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
    try std.testing.expectEqual(fp.canonical, s.f[3]);
    try std.testing.expectEqual(fp.invalid, s.csr.fflags);
}

test "infinity less infinity and zero times infinity are invalid, section 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = infinity;
    s.f[2] = infinity;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsub, 2, 1, dyn, 3)));
    try std.testing.expectEqual(fp.canonical, s.f[3]);
    try std.testing.expectEqual(fp.invalid, s.csr.fflags);

    s.csr.fflags = 0;
    s.f[2] = 0;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fmul, 2, 1, dyn, 3)));
    try std.testing.expectEqual(fp.canonical, s.f[3]);
    try std.testing.expectEqual(fp.invalid, s.csr.fflags);
}

test "a finite divided by zero is a signed infinity and raises divide by zero, section 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = one;
    s.f[2] = 0x8000_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fdiv, 2, 1, dyn, 3)));
    try std.testing.expectEqual(infinity | 0x8000_0000, s.f[3]);
    try std.testing.expectEqual(fp.divide_by_zero, s.csr.fflags);
}

test "FSQRT.S of a negative is invalid and of a negative zero is itself, section 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = one | 0x8000_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsqrt, 0, 1, dyn, 2)));
    try std.testing.expectEqual(fp.canonical, s.f[2]);
    try std.testing.expectEqual(fp.invalid, s.csr.fflags);

    s.csr.fflags = 0;
    s.f[1] = 0x8000_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsqrt, 0, 1, dyn, 2)));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.f[2]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}

test "FMIN.S and FMAX.S are minimumNumber and maximumNumber, section 20.6: two NaNs canonicalise, one NaN gives the other, and minus zero is the smaller" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = quiet_nan;
    s.f[2] = two;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fminmax, 2, 1, 0, 3)));
    try std.testing.expectEqual(two, s.f[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);

    s.f[2] = signalling_nan;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fminmax, 2, 1, 0, 3)));
    try std.testing.expectEqual(fp.canonical, s.f[3]);
    try std.testing.expectEqual(fp.invalid, s.csr.fflags);

    s.csr.fflags = 0;
    s.f[1] = 0;
    s.f[2] = 0x8000_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fminmax, 2, 1, 0, 3)));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.f[3]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fminmax, 2, 1, 1, 3)));
    try std.testing.expectEqual(@as(u32, 0), s.f[3]);
}

test "FCLASS.S names every kind a single can be, section 20.9 table 29, from minus infinity at bit 0 up to a quiet NaN at bit 9" {
    const cases = [_]struct { u32, u32 }{
        .{ 0xff80_0000, 1 << 0 },
        .{ 0xbf80_0000, 1 << 1 },
        .{ 0x8000_0001, 1 << 2 },
        .{ 0x8000_0000, 1 << 3 },
        .{ 0x0000_0000, 1 << 4 },
        .{ 0x0000_0001, 1 << 5 },
        .{ 0x3f80_0000, 1 << 6 },
        .{ 0x7f80_0000, 1 << 7 },
        .{ 0x7f80_0001, 1 << 8 },
        .{ 0x7fc0_0000, 1 << 9 },
    };
    var s = hart();
    var m: Mem = .{};
    for (cases) |c| {
        s.f[1] = c[0];
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(move_out, 0, 1, 0b001, 2)));
        try std.testing.expectEqual(c[1], s.x[2]);
    }
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}

test "the comparisons answer zero for a NaN, section 20.8, and FLT and FLE raise invalid for any of them where FEQ raises it only for a signalling one" {
    const rows = [_]struct { u32, u32, u5 }{
        .{ 0b010, quiet_nan, 0 },
        .{ 0b001, quiet_nan, fp.invalid },
        .{ 0b000, quiet_nan, fp.invalid },
        .{ 0b010, signalling_nan, fp.invalid },
    };
    for (rows) |r| {
        var s = hart();
        var m: Mem = .{};
        s.f[1] = r[1];
        s.f[2] = r[1];
        s.x[3] = 0xffff_ffff;
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fcompare, 2, 1, r[0], 3)));
        try std.testing.expectEqual(@as(u32, 0), s.x[3]);
        try std.testing.expectEqual(r[2], s.csr.fflags);
    }
}

test "FCVT.W.S and FCVT.WU.S answer the end of the range a NaN or an out-of-range value ran past and raise invalid rather than inexact, table 28" {
    const cases = [_]struct { u32, u32, u32, u5 }{
        .{ to_word, quiet_nan, 0x7fff_ffff, fp.invalid },
        .{ to_word, 0x4f00_0000, 0x7fff_ffff, fp.invalid },
        .{ to_word, 0xcf00_0000, 0x8000_0000, 0 },
        .{ to_word, 0xcf00_0001, 0x8000_0000, fp.invalid },
        .{ to_word, 0x3fc0_0000, 2, fp.inexact },
        .{ to_word | 1, 0xbf80_0000, 0, fp.invalid },
    };
    for (cases) |c| {
        var s = hart();
        var m: Mem = .{};
        s.f[1] = c[1];
        const rs2: u32 = if (c[0] & 1 != 0) 1 else 0;
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(to_word, rs2, 1, 0, 2)));
        try std.testing.expectEqual(c[2], s.x[2]);
        try std.testing.expectEqual(c[3], s.csr.fflags);
    }
}

test "the sign-injection rows take every bit but the sign from rs1 and raise nothing, section 20.6, so a signalling NaN passes through uncanonicalised" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = signalling_nan;
    s.f[2] = 0x8000_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsgnj, 2, 1, 0b000, 3)));
    try std.testing.expectEqual(signalling_nan | 0x8000_0000, s.f[3]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsgnj, 2, 1, 0b001, 3)));
    try std.testing.expectEqual(signalling_nan, s.f[3]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsgnj, 2, 1, 0b010, 3)));
    try std.testing.expectEqual(signalling_nan | 0x8000_0000, s.f[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}

test "FMV.W.X and FMV.X.W move the bits unmodified, section 20.7, and FLEN=32 leaves the NaN boxing of section 21.2 with no box to check" {
    var s = hart();
    var m: Mem = .{};
    s.x[1] = 0x7f81_2345;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(move_in, 0, 1, 0, 2)));
    try std.testing.expectEqual(@as(u32, 0x7f81_2345), s.f[2]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(move_out, 0, 2, 0, 3)));
    try std.testing.expectEqual(@as(u32, 0x7f81_2345), s.x[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}

test "FSW then FLW carries a word through memory, section 20.5" {
    var s = hart();
    var m: Mem = .{};
    s.f[2] = 0xdead_beef;
    s.x[1] = 4;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, 2 << 20 | 1 << 15 | 0b010 << 12 | 4 << 7 | 0b0100111));
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, 8 << 20 | 0 << 15 | 0b010 << 12 | 3 << 7 | 0b0000111));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.f[3]);
}

test "an overflowing product is an infinity under RNE and the largest single under RTZ, section 20.6" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = 0x7f00_0000;
    s.f[2] = 0x7f00_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fmul, 2, 1, 0b000, 3)));
    try std.testing.expectEqual(infinity, s.f[3]);
    try std.testing.expectEqual(fp.inexact | fp.overflow, s.csr.fflags);

    s.csr.fflags = 0;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fmul, 2, 1, 0b001, 3)));
    try std.testing.expectEqual(@as(u32, 0x7f7f_ffff), s.f[3]);
    try std.testing.expectEqual(fp.inexact | fp.overflow, s.csr.fflags);
}

test "a product that rounds into the subnormals raises underflow with inexact, section 20.4, since tininess is detected after rounding" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = 0x0080_0000;
    s.f[2] = 0x3f00_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fmul, 2, 1, 0b000, 3)));
    try std.testing.expectEqual(@as(u32, 0x0040_0000), s.f[3]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);

    s.f[1] = 0x0000_0003;
    s.f[2] = 0x3f00_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fmul, 2, 1, 0b000, 3)));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), s.f[3]);
    try std.testing.expectEqual(fp.inexact | fp.underflow, s.csr.fflags);
}

test "mstatus.FS gates the extension, privileged section 3.1.6.7: with it off every row is illegal, and a row that runs leaves it dirty" {
    var s = hart();
    var m: Mem = .{};
    s.csr.mstatus.fs = .off;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, wide(move_out, 0, 1, 0, 2)));

    const csrr_fflags = 0x001 << 20 | 0b010 << 12 | 2 << 7 | 0b1110011;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, csrr_fflags));

    s.csr.mstatus.fs = .dirty;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fadd, 2, 1, dyn, 3)));
    try std.testing.expectEqual(csr.ContextStatus.dirty, s.csr.mstatus.fs);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, csrr_fflags));
}

test "fcsr holds frm above fflags, section 20.2, and a hart without the unit has none of the three, privileged section 3.1.6.7" {
    var s = hart();
    var m: Mem = .{};
    const csrrw = 0x003 << 20 | 1 << 15 | 0b001 << 12 | 2 << 7 | 0b1110011;
    s.x[1] = 0b010_00011;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, csrrw));
    try std.testing.expectEqual(@as(u3, 0b010), s.csr.frm);
    try std.testing.expectEqual(@as(u5, 0b00011), s.csr.fflags);
    try std.testing.expectEqual(@as(u32, 0b010_00011), s.csr.read(.fcsr));

    s.csr.implementation.float = false;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, &m, csrrw));
}

test "a fused row rounds its product and addend once, section 20.6, where rounding the sum to a double first would land on a midpoint the exact value only passed" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = 0x42c2_0000;
    s.f[2] = 0x4828_e840;
    s.f[3] = 0x3080_0000;
    const fmadd = 3 << 27 | 2 << 20 | 1 << 15 | dyn << 12 | 4 << 7 | 0b1000011;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, fmadd));
    try std.testing.expectEqual(@as(u32, 0x4b80_0001), s.f[4]);
    try std.testing.expectEqual(fp.inexact, s.csr.fflags);
}

test "a directed mode decides on bits a double does not keep, section 20.2: one plus 2^-100 is the next single up under RUP where rounding to a double first would answer one" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = one;
    s.f[2] = 0x0d80_0000;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fadd, 2, 1, rup, 3)));
    try std.testing.expectEqual(@as(u32, 0x3f80_0001), s.f[3]);
    try std.testing.expectEqual(fp.inexact, s.csr.fflags);
}

test "a difference that cancels exactly is minus zero under RDN and plus zero under the rest, which chapter 20 takes from IEEE 754-2008 section 6.3" {
    var s = hart();
    var m: Mem = .{};
    s.f[1] = one;
    s.f[2] = one;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsub, 2, 1, rdn, 3)));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.f[3]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, &m, wide(fsub, 2, 1, rtz, 4)));
    try std.testing.expectEqual(@as(u32, 0), s.f[4]);
    try std.testing.expectEqual(@as(u5, 0), s.csr.fflags);
}
