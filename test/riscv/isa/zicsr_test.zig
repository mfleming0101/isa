//! Tests of the Zicsr rows and the CSR file: the reset value and write mask of every register the
//! default model implements, the six CSR operations and their x0 forms, illegal accesses, misa,
//! mstatus, mtvec and mepc masking, MRET, WFI, rendering, and the model fields mie, mip and mcause
//! are decided by.
const std = @import("std");
const State = @import("../../../src/riscv/isa/state.zig").State;
const instruction = @import("../../../src/riscv/isa/instruction.zig");
const decode = @import("../../../src/riscv/isa/decode.zig");
const step = @import("../../../src/riscv/isa/step.zig");
const disasm = @import("riscv_disasm");
const csr = @import("../../../src/riscv/isa/csr.zig");

const Mem = struct {
    /// Every group, so each row decodes.
    pub const allowed = decode.every;
    const Self = @This();

    /// Host requirement: a touched address is ignored here.
    pub fn touch(_: *Self, _: u32) void {}

    /// No memory at all: no Zicsr row reaches it.
    pub fn span(_: *Self, _: u32, comptime _: anytype) []u8 {
        return &.{};
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

fn exec(s: *State, code: u32) instruction.Outcome {
    var m: Mem = .{};
    return step.call(Mem, s, &m, code, Mem.allowed);
}

const system: u32 = 0b1110011;

const Form = enum(u3) { swap = 1, set = 2, clear = 3, swap_immediate = 5, set_immediate = 6, clear_immediate = 7 };

fn access(form: Form, rd: u32, csr_number: u32, source: u32) u32 {
    return csr_number << 20 | source << 15 | @as(u32, @intFromEnum(form)) << 12 | rd << 7 | system;
}

const mret: u32 = 0x3020_0073;
const wfi: u32 = 0x1050_0073;

fn number(n: csr.Number) u32 {
    return @intFromEnum(n);
}

fn render(code: u32) ![]const u8 {
    const S = struct {
        var buffer: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buffer);
    try disasm.write(&w, code, 0x4200_0000, decode.every);
    return w.buffered();
}

const Register = struct { number: csr.Number, reset: u32, write_mask: u32 };

const table = [_]Register{
    .{ .number = .mstatus, .reset = 0x0000_0000, .write_mask = 0x0020_7888 },
    .{ .number = .misa, .reset = 0x4034_11af, .write_mask = 0x0000_0000 },
    .{ .number = .mtvec, .reset = 0x0000_0000, .write_mask = 0xffff_fffc },
    .{ .number = .mscratch, .reset = 0x0000_0000, .write_mask = 0xffff_ffff },
    .{ .number = .mepc, .reset = 0x0000_0000, .write_mask = 0xffff_fffe },
    .{ .number = .mcause, .reset = 0x0000_0000, .write_mask = 0xffff_ffff },
    .{ .number = .mtval, .reset = 0x0000_0000, .write_mask = 0xffff_ffff },
    .{ .number = .mie, .reset = 0x0000_0000, .write_mask = 0xffff_ffff },
    .{ .number = .mip, .reset = 0x0000_0000, .write_mask = 0x0000_0000 },
    .{ .number = .mvendorid, .reset = 0x0000_0000, .write_mask = 0x0000_0000 },
    .{ .number = .marchid, .reset = 0x0000_0000, .write_mask = 0x0000_0000 },
    .{ .number = .mimpid, .reset = 0x0000_0000, .write_mask = 0x0000_0000 },
    .{ .number = .mhartid, .reset = 0x0000_0000, .write_mask = 0x0000_0000 },
};

test "each CSR of the default model reads its reset value and keeps only the bits the model makes writable, section 2.2" {
    for (table) |r| {
        var s: State = .{};
        s.x[1] = 0xffff_ffff;
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 2, number(r.number), 0)));
        try std.testing.expectEqual(r.reset, s.x[2]);

        const written = exec(&s, access(.swap, 0, number(r.number), 1));
        try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 3, number(r.number), 0)));
        if (written == .illegal) {
            try std.testing.expectEqual(r.reset, s.x[3]);
        } else {
            try std.testing.expectEqual(r.reset | r.write_mask, s.x[3]);
        }
    }
}

test "CSRRW swaps the register with the CSR, CSRRS raises the bits it names and CSRRC lowers them, section 6.1" {
    var s: State = .{};
    s.x[1] = 0x1234_5678;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 2, number(.mscratch), 1)));
    try std.testing.expectEqual(@as(u32, 0), s.x[2]);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), s.csr.mscratch);

    s.x[1] = 0x0000_ff00;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 3, number(.mscratch), 1)));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), s.x[3]);
    try std.testing.expectEqual(@as(u32, 0x1234_ff78), s.csr.mscratch);

    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.clear, 4, number(.mscratch), 1)));
    try std.testing.expectEqual(@as(u32, 0x1234_ff78), s.x[4]);
    try std.testing.expectEqual(@as(u32, 0x1234_0078), s.csr.mscratch);
}

test "the immediate forms take the same three operations over a zero-extended five-bit immediate, section 6.1" {
    var s: State = .{};
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap_immediate, 1, number(.mscratch), 31)));
    try std.testing.expectEqual(@as(u32, 31), s.csr.mscratch);
    try std.testing.expectEqual(@as(u32, 0), s.x[1]);

    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.clear_immediate, 2, number(.mscratch), 0b101)));
    try std.testing.expectEqual(@as(u32, 0b11010), s.csr.mscratch);
    try std.testing.expectEqual(@as(u32, 31), s.x[2]);

    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set_immediate, 3, number(.mscratch), 0b101)));
    try std.testing.expectEqual(@as(u32, 31), s.csr.mscratch);
}

test "CSRRS and CSRRC whose source is x0 or a zero immediate do not write, so a read-only CSR does not refuse them, section 6.1" {
    var s: State = .{};
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 1, number(.mvendorid), 0)));
    try std.testing.expectEqual(csr.sail.vendor_id, s.x[1]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.clear_immediate, 2, number(.mvendorid), 0)));
    try std.testing.expectEqual(csr.sail.vendor_id, s.x[2]);

    s.x[5] = 0;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set, 1, number(.mvendorid), 5)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set_immediate, 1, number(.mvendorid), 1)));
}

test "CSRRW whose destination is x0 writes the CSR without reading it, and a set whose source is x0 reads it without writing, section 6.1" {
    var s: State = .{};
    s.x[1] = 0xdead_beef;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mscratch), 1)));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.csr.mscratch);
    try std.testing.expectEqual(@as(u32, 0), s.x[0]);

    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 2, number(.mscratch), 0)));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.x[2]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.csr.mscratch);
}

test "a CSR this file does not implement is an illegal instruction, the counters of section 2.2 included" {
    var s: State = .{};
    const absent = [_]u32{ 0x306, 0x320, 0xb00, 0xb02, 0xb80, 0xb82, 0xc00, 0xc01, 0xc02, 0xc80, 0xc81, 0xc82 };
    for (absent) |n| {
        try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set, 1, n, 0)));
        try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.swap, 0, n, 1)));
    }
}

test "a write to a read-only CSR is an illegal instruction whether or not it keeps the old value, section 2.1" {
    var s: State = .{};
    s.x[1] = 0xffff_ffff;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.swap, 2, number(.marchid), 1)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.swap, 0, number(.marchid), 1)));
    try std.testing.expectEqual(csr.sail.architecture_id, s.csr.read(.marchid));
}

test "every CSR of this part is a machine-mode one, so a user-mode access to any of them is an illegal instruction, section 2.1" {
    var s: State = .{ .privilege = .user };
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set, 1, number(.mstatus), 0)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set, 1, number(.mvendorid), 0)));
    s.privilege = .machine;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 1, number(.mstatus), 0)));
}

test "misa reads the model's word and ignores what is written to it, Privileged 3.1.1" {
    var s: State = .{};
    s.x[1] = 0xffff_ffff;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 2, number(.misa), 1)));
    try std.testing.expectEqual(csr.sail.isa, s.x[2]);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 3, number(.misa), 0)));
    try std.testing.expectEqual(csr.sail.isa, s.x[3]);

    s.csr.implementation.isa = 0x4010_1104;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 4, number(.misa), 0)));
    try std.testing.expectEqual(@as(u32, 0x4010_1104), s.x[4]);
}

test "mstatus keeps the fields the model makes writable, and the higher bit of MPP follows its lower one, Privileged 3.1.6" {
    var s: State = .{};
    s.x[1] = 1 << 3 | 1 << 7 | 1 << 21;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mstatus), 1)));
    try std.testing.expect(s.csr.mstatus.mie);
    try std.testing.expect(s.csr.mstatus.mpie);
    try std.testing.expect(s.csr.mstatus.tw);
    try std.testing.expectEqual(csr.Privilege.user, s.csr.mstatus.mpp);

    s.x[1] = 1 << 11;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 2, number(.mstatus), 1)));
    try std.testing.expectEqual(csr.Privilege.machine, s.csr.mstatus.mpp);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 3, number(.mstatus), 0)));
    try std.testing.expectEqual(@as(u32, 0x0000_1800), s.x[3]);
}

test "a field the model leaves out of mstatus_writable keeps its value, Privileged 3.1.6" {
    var s: State = .{};
    s.csr.implementation.mstatus_writable = 0x0000_0008;
    s.csr.mstatus.tw = true;
    s.x[1] = 1 << 3 | 1 << 7;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mstatus), 1)));
    try std.testing.expect(s.csr.mstatus.mie);
    try std.testing.expect(!s.csr.mstatus.mpie);
    try std.testing.expect(s.csr.mstatus.tw);
}

test "mtvec keeps the base bits the model makes writable and takes a MODE the model implements, Privileged 3.1.8" {
    var s: State = .{};
    s.x[1] = 0x4200_00ff;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mtvec), 1)));
    try std.testing.expectEqual(@as(u32, 0x4200_00fc), s.csr.mtvec);

    s.x[1] = 0x4200_0001;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mtvec), 1)));
    try std.testing.expectEqual(@as(u32, 0x4200_0001), s.csr.mtvec);

    s.csr.implementation.tvec_modes = .vectored;
    s.csr.implementation.tvec_base_mask = 0xffff_ff00;
    s.x[1] = 0x4200_00fe;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mtvec), 1)));
    try std.testing.expectEqual(@as(u32, 0x4200_0001), s.csr.mtvec);
}

test "an interrupt enters at the base in direct mode and four bytes a source above it in vectored mode, Privileged 3.1.8" {
    var s: State = .{};
    s.csr.mtvec = 0x4200_0000;
    try std.testing.expectEqual(@as(u32, 0x4200_0000), s.csr.interrupt(&s.privilege, 7, 0x100));
    s.csr.mtvec = 0x4200_0001;
    try std.testing.expectEqual(@as(u32, 0x4200_001c), s.csr.interrupt(&s.privilege, 7, 0x100));
}

test "mcause keeps the bits the model's code field is wide, which is WLRL, Privileged 3.1.15" {
    var s: State = .{};
    s.x[1] = 0xffff_ffff;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mcause), 1)));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.csr.mcause);

    s.csr.implementation.cause_mask = 0x8000_001f;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mcause), 1)));
    try std.testing.expectEqual(@as(u32, 0x8000_001f), s.csr.mcause);
}

test "mepc drops its lowest bit and keeps bit 1, since C takes IALIGN down to sixteen, section 3.1.14" {
    var s: State = .{};
    s.x[1] = 0x4200_0007;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 0, number(.mepc), 1)));
    try std.testing.expectEqual(@as(u32, 0x4200_0006), s.csr.mepc);
}

test "MRET resumes at mepc, restores MIE from MPIE and sets MPIE, Privileged 3.3.2" {
    var s: State = .{};
    s.csr.mepc = 0x4200_0010;
    s.csr.mstatus = .{ .mie = false, .mpie = true, .mpp = .machine };
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, mret));
    try std.testing.expectEqual(@as(u32, 0x4200_0010), s.pc);
    try std.testing.expect(s.csr.mstatus.mie);
    try std.testing.expect(s.csr.mstatus.mpie);
    try std.testing.expectEqual(csr.Privilege.machine, s.privilege);
    try std.testing.expectEqual(csr.Privilege.user, s.csr.mstatus.mpp);
}

test "MRET takes the hart to the privilege MPP names, and is an illegal instruction below machine mode, section 3.3.2" {
    var s: State = .{};
    s.csr.mepc = 0x4200_0020;
    s.csr.mstatus = .{ .mpp = .user };
    try std.testing.expectEqual(instruction.Outcome.branched, exec(&s, mret));
    try std.testing.expectEqual(csr.Privilege.user, s.privilege);
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, mret));
}

test "WFI executes as a NOP, and mstatus.TW makes it an illegal instruction in user mode, Privileged 3.3.3" {
    var s: State = .{};
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, wfi));
    s.csr.mstatus.tw = true;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, wfi));
    s.privilege = .user;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, wfi));
    s.csr.mstatus.tw = false;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, wfi));
}

test "each row renders as the assembler writes it, with the pseudo-instructions of section 6.1 for the operands that are x0" {
    try std.testing.expectEqualStrings("csrrw a0, mstatus, a1", try render(access(.swap, 10, number(.mstatus), 11)));
    try std.testing.expectEqualStrings("csrw mtvec, a1", try render(access(.swap, 0, number(.mtvec), 11)));
    try std.testing.expectEqualStrings("csrrs a0, mcause, a1", try render(access(.set, 10, number(.mcause), 11)));
    try std.testing.expectEqualStrings("csrr a0, mepc", try render(access(.set, 10, number(.mepc), 0)));
    try std.testing.expectEqualStrings("csrs mstatus, a1", try render(access(.set, 0, number(.mstatus), 11)));
    try std.testing.expectEqualStrings("csrrc a0, mtval, a1", try render(access(.clear, 10, number(.mtval), 11)));
    try std.testing.expectEqualStrings("csrc mstatus, a1", try render(access(.clear, 0, number(.mstatus), 11)));
    try std.testing.expectEqualStrings("csrrwi a0, mscratch, 8", try render(access(.swap_immediate, 10, number(.mscratch), 8)));
    try std.testing.expectEqualStrings("csrrsi a0, mscratch, 31", try render(access(.set_immediate, 10, number(.mscratch), 31)));
    try std.testing.expectEqualStrings("csrrci a0, mhartid, 1", try render(access(.clear_immediate, 10, number(.mhartid), 1)));
    try std.testing.expectEqualStrings("csrr a0, 0xc00", try render(access(.set, 10, 0xc00, 0)));
    try std.testing.expectEqualStrings("mret", try render(mret));
    try std.testing.expectEqualStrings("wfi", try render(wfi));
}

test "mie and mip answer on a hart whose model has them and on no other, Privileged 3.1.10" {
    var s: State = .{};
    s.x[1] = 0x0000_0020;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 2, number(.mie), 1)));
    try std.testing.expectEqual(@as(u32, 0x0000_0020), s.csr.mie);
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.set, 3, number(.mip), 0)));
    try std.testing.expectEqual(@as(u32, 0), s.x[3]);

    s.csr.implementation.interrupt_csrs = false;
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.swap, 2, number(.mie), 1)));
    try std.testing.expectEqual(instruction.Outcome.illegal, exec(&s, access(.set, 3, number(.mip), 0)));
}

test "a write to mip is dropped, since MEIP, MTIP and MSIP are driven by the platform, Privileged 3.1.10" {
    var s: State = .{};
    s.csr.mip = 0x0000_0020;
    s.x[1] = 0xffff_ffff;
    try std.testing.expectEqual(instruction.Outcome.next, exec(&s, access(.swap, 2, number(.mip), 1)));
    try std.testing.expectEqual(@as(u32, 0x0000_0020), s.csr.mip);
    try std.testing.expectEqual(@as(u32, 0x0000_0020), s.x[2]);
}
