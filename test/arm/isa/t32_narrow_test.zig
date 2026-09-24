//! Tests of the 16-bit T32 rows driven one code at a time over a small in-memory host:
//! data processing, flags, loads and stores, stack operations, branches and the
//! system rows.
const std = @import("std");
const State = @import("../../../src/arm/isa/state.zig").State;
const instruction = @import("../../../src/arm/isa/instruction.zig");
const Architecture = @import("../../../src/arm/isa/architecture.zig").Architecture;
const decode = @import("../../../src/arm/isa/decode.zig");
const step = @import("../../../src/arm/isa/step.zig");
const free: step.Model.Costs = @splat(.{ .cycles = 0, .taken = 0 });

const Mem = struct {
    const Self = @This();

    bytes: [64]u8 = @splat(0),
    model: step.Model,
    priority_bits: u4,

    /// Priority bits the test core implements.
    pub fn priorityBits(self: *Self) u4 {
        return self.priority_bits;
    }

    /// The architecture the test host decodes for.
    pub fn architecture(self: *Self) Architecture {
        return self.model.decoding.architecture;
    }

    /// No Security Extension.
    pub fn security(_: *Self) bool {
        return false;
    }

    /// Double precision is present.
    pub fn doublePrecision(_: *Self) bool {
        return true;
    }

    /// Half precision is present.
    pub fn halfPrecision(_: *Self) bool {
        return true;
    }

    /// FPv5 is present.
    pub fn fpv5(_: *Self) bool {
        return true;
    }

    /// PACBTI is present on Armv8.1-M only.
    pub fn pacbti(self: *Self) bool {
        return self.model.decoding.architecture == .armv8_1m_main;
    }

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    /// Ignores an access notice.
    pub fn touch(_: *Self, _: u32) void {}

    /// Ignores a step event.
    pub fn signal(_: *Self, _: step.Signal) void {}

    /// Host requirement: nothing re-arms here.
    pub fn rearm(_: *Self) void {}

    /// Ignores a sleep request.
    pub fn sleep(_: *Self, _: step.Wait) void {}

    /// Ignores an event.
    pub fn event(_: *Self) void {}

    /// Unaligned accesses are not trapped.
    pub fn trapsUnaligned(_: *Self) bool {
        return false;
    }

    /// Divide by zero is not trapped.
    pub fn trapsDivideByZero(_: *Self) bool {
        return false;
    }

    /// The coprocessor is enabled.
    pub fn coprocessorEnabled(_: *Self) bool {
        return true;
    }

    /// MVE is present.
    pub fn mve(_: *Self) bool {
        return true;
    }

    /// Automatic FP state preservation is on.
    pub fn automaticFpState(_: *Self) bool {
        return true;
    }

    /// FPSCR reset value.
    pub fn defaultFpscr(_: *Self) u32 {
        return 0;
    }

    /// Non-secure FPSCR value.
    pub fn nonSecureFpscr(_: *Self) u32 {
        return 0;
    }

    /// No lazy FP frame is pending.
    pub fn lazyFpFrame(_: *Self) ?u32 {
        return null;
    }

    /// No lazy callee-saved FP state.
    pub fn lazyFpCallee(_: *Self) bool {
        return false;
    }

    /// Lazy FP state preservation is on.
    pub fn lazyFpEnabled(_: *Self) bool {
        return true;
    }

    /// Ignores a lazy FP frame update.
    pub fn setLazyFp(_: *Self, _: ?u32) void {}

    /// The floating-point context is treated as Secure.
    pub fn treatAsSecure(_: *Self) bool {
        return true;
    }

    /// The bytes from an address, or empty when out of range.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        _ = self.slice(address, a.bytes) orelse return &.{};
        return self.bytes[address..];
    }

    /// Refuses every access no span answered.
    pub fn access(_: *Self, _: u32, comptime _: anytype, _: u32) error{DataFault}!u32 {
        return error.DataFault;
    }

    fn peek(self: *Self, comptime T: type, address: u32) ?T {
        return std.mem.readInt(T, self.slice(address, @sizeOf(T)) orelse return null, .little);
    }

    fn poke(self: *Self, comptime T: type, address: u32, value: T) ?void {
        std.mem.writeInt(T, self.slice(address, @sizeOf(T)) orelse return null, value, .little);
    }
};

fn memory(p: Architecture) Mem {
    return .{ .model = .{ .decoding = decode.selectionOf(p), .costs = free }, .priority_bits = if (p == .armv6m) 2 else 4 };
}

fn exec(s: *State, m: anytype, code: u32) instruction.Outcome {
    const Host = @TypeOf(m.*);
    return step.call(Host, s, m, code, m.model.decoding.groups);
}

test "MOVS immediate writes the immediate to Rd and sets N and Z from it, A6.7.39" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x2001));
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x2700));
    try std.testing.expectEqual(@as(u32, 0), s.r[7]);
    try std.testing.expectEqual(State.flag_z, s.xpsr);
}

test "ADDS immediate adds the three-bit immediate to Rn into Rd and sets the four flags, A6.7.2" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1c81));
    try std.testing.expectEqual(@as(u32, 3), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
    s.r[0] = 0xffff_ffff;
    _ = exec(&s, &m, 0x1c41);
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 0x7fff_ffff;
    _ = exec(&s, &m, 0x1c41);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[1]);
    try std.testing.expectEqual(State.flag_n | State.flag_v, s.xpsr);
}

test "B writes PC plus 4 plus the sign-extended offset, A6.7.10" {
    var s: State = .{ .pc = 0x0c };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe000));
    try std.testing.expectEqual(@as(u32, 0x10), s.pc);
    s.pc = 0x100;
    _ = exec(&s, &m, 0xe7fe);
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);
    s.pc = 0x100;
    _ = exec(&s, &m, 0xe3ff);
    try std.testing.expectEqual(@as(u32, 0x100 + 4 + 0x7fe), s.pc);
}

test "BKPT stops the core and changes no register, A6.7.12" {
    var s: State = .{ .pc = 0x10, .xpsr = State.flag_t };
    var m = memory(.armv6m);
    const before = s;
    try std.testing.expectEqual(.breakpoint, exec(&s, &m, 0xbe00));
    try std.testing.expectEqual(before, s);
}

test "STR and LDR immediate address Rn plus four times imm5 and move a word, A6.7.59 and A6.7.26" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0xdead_beef;
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x6048));
    try std.testing.expectEqual(@as(?u32, 0xdead_beef), m.peek(u32, 0x14));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x684a));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), s.r[2]);
}

test "STRB and LDRB immediate address Rn plus imm5 and move the low byte with zero extension, A6.7.61 and A6.7.29" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0x1234_56ab;
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x7048));
    try std.testing.expectEqual(@as(?u32, 0xab00), m.peek(u32, 0x10));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x784a));
    try std.testing.expectEqual(@as(u32, 0xab), s.r[2]);
}

test "STRH and LDRH immediate address Rn plus twice imm5 and move the low halfword with zero extension, A6.7.63 and A6.7.31" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0x1234_56ab;
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x8048));
    try std.testing.expectEqual(@as(?u32, 0x56ab_0000), m.peek(u32, 0x10));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x884a));
    try std.testing.expectEqual(@as(u32, 0x56ab), s.r[2]);
}

test "STR and LDR relative to SP address the selected stack pointer plus four times imm8, A6.7.59 and A6.7.26" {
    var s: State = .{ .msp = 0x20 };
    var m = memory(.armv6m);
    s.r[0] = 0x0bad_f00d;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x9001));
    try std.testing.expectEqual(@as(?u32, 0x0bad_f00d), m.peek(u32, 0x24));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x9b01));
    try std.testing.expectEqual(@as(u32, 0x0bad_f00d), s.r[3]);
}

test "LDR literal addresses the word-aligned PC plus 4 plus four times imm8, A6.7.27" {
    var s: State = .{ .pc = 6 };
    var m = memory(.armv6m);
    _ = m.poke(u32, 0xc, 0xcafe_babe);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4801));
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), s.r[0]);
    s.pc = 4;
    s.r[0] = 0;
    _ = exec(&s, &m, 0x4801);
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), s.r[0]);
}

test "STR, STRH, STRB and their loads with a register offset address Rn plus Rm, A6.7.60 A6.7.64 A6.7.62 A6.7.28 A6.7.32 A6.7.30" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0x89ab_cdef;
    s.r[1] = 0x10;
    s.r[2] = 4;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5088));
    try std.testing.expectEqual(@as(?u32, 0x89ab_cdef), m.peek(u32, 0x14));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x588b));
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), s.r[3]);
    s.r[2] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5288));
    try std.testing.expectEqual(@as(?u32, 0xcdef), m.peek(u32, 0x18));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5a8b));
    try std.testing.expectEqual(@as(u32, 0xcdef), s.r[3]);
    s.r[2] = 12;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5488));
    try std.testing.expectEqual(@as(?u32, 0xef), m.peek(u32, 0x1c));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5c8b));
    try std.testing.expectEqual(@as(u32, 0xef), s.r[3]);
}

test "LDRSB and LDRSH sign-extend what they load, A6.7.33 and A6.7.34" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[1] = 0x10;
    s.r[2] = 4;
    _ = m.poke(u8, 0x14, 0x80);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x568b));
    try std.testing.expectEqual(@as(u32, 0xffff_ff80), s.r[3]);
    _ = m.poke(u8, 0x14, 0x7f);
    _ = exec(&s, &m, 0x568b);
    try std.testing.expectEqual(@as(u32, 0x7f), s.r[3]);
    _ = m.poke(u16, 0x14, 0x8000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x5e8b));
    try std.testing.expectEqual(@as(u32, 0xffff_8000), s.r[3]);
    _ = exec(&s, &m, 0x5a8b);
    try std.testing.expectEqual(@as(u32, 0x8000), s.r[3]);
}

test "STM stores the listed registers upward from Rn and writes the final address back, A6.7.58" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0x10;
    s.r[1] = 1;
    s.r[2] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xc006));
    try std.testing.expectEqual(@as(?u32, 1), m.peek(u32, 0x10));
    try std.testing.expectEqual(@as(?u32, 2), m.peek(u32, 0x14));
    try std.testing.expectEqual(@as(u32, 0x18), s.r[0]);
}

test "LDM loads the listed registers upward from Rn and writes back only when Rn is not in the list, A6.7.25" {
    var s: State = .{};
    var m = memory(.armv6m);
    _ = m.poke(u32, 0x10, 7);
    _ = m.poke(u32, 0x14, 8);
    s.r[3] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xcb06));
    try std.testing.expectEqual(@as(u32, 7), s.r[1]);
    try std.testing.expectEqual(@as(u32, 8), s.r[2]);
    try std.testing.expectEqual(@as(u32, 0x18), s.r[3]);
    s.r[1] = 0x10;
    s.r[2] = 0;
    _ = exec(&s, &m, 0xc906);
    try std.testing.expectEqual(@as(u32, 7), s.r[1]);
    try std.testing.expectEqual(@as(u32, 8), s.r[2]);
}

test "PUSH stores the list and LR below SP and lowers SP by four per register, A6.7.50" {
    var s: State = .{ .msp = 0x20, .lr = 0x101 };
    var m = memory(.armv6m);
    s.r[0] = 1;
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb503));
    try std.testing.expectEqual(@as(u32, 0x14), s.msp);
    try std.testing.expectEqual(@as(?u32, 1), m.peek(u32, 0x14));
    try std.testing.expectEqual(@as(?u32, 2), m.peek(u32, 0x18));
    try std.testing.expectEqual(@as(?u32, 0x101), m.peek(u32, 0x1c));
}

test "POP loads the list from SP upward and raises SP; a list with PC branches to the loaded address with bit 0 cleared, A6.7.49" {
    var s: State = .{ .msp = 0x14 };
    var m = memory(.armv6m);
    _ = m.poke(u32, 0x14, 1);
    _ = m.poke(u32, 0x18, 2);
    _ = m.poke(u32, 0x1c, 0x101);
    _ = m.poke(u32, 0x20, 0x31);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xbc0c));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(@as(u32, 2), s.r[3]);
    try std.testing.expectEqual(@as(u32, 0x1c), s.msp);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xbd10));
    try std.testing.expectEqual(@as(u32, 0x101), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0x30), s.pc);
    try std.testing.expectEqual(@as(u32, 0x24), s.msp);
}

test "POP with PC sets the T bit from bit 0 of the loaded address, A6.7.49" {
    var s: State = .{ .msp = 0x10, .xpsr = State.flag_t };
    var m = memory(.armv6m);
    _ = m.poke(u32, 0x10, 0x20);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xbd00));
    try std.testing.expectEqual(@as(u32, 0x20), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
    s.msp = 0x10;
    _ = m.poke(u32, 0x10, 0x21);
    _ = exec(&s, &m, 0xbd00);
    try std.testing.expectEqual(@as(u32, 0x20), s.pc);
    try std.testing.expectEqual(State.flag_t, s.xpsr);
}

test "PUSH and POP use the process stack when CONTROL.SPSEL is set, B1.4.4" {
    var s: State = .{ .msp = 0x40, .psp = 0x20, .control = State.control_spsel };
    var m = memory(.armv6m);
    s.r[0] = 9;
    _ = exec(&s, &m, 0xb401);
    try std.testing.expectEqual(@as(u32, 0x1c), s.psp);
    try std.testing.expectEqual(@as(u32, 0x40), s.msp);
    try std.testing.expectEqual(@as(?u32, 9), m.peek(u32, 0x1c));
    _ = exec(&s, &m, 0xbc02);
    try std.testing.expectEqual(@as(u32, 9), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0x20), s.psp);
}

test "an access no memory answers is a data fault and leaves the destination register alone" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[0] = 0x55;
    s.r[1] = 0x1000;
    try std.testing.expectEqual(.data_fault, exec(&s, &m, 0x6808));
    try std.testing.expectEqual(@as(u32, 0x55), s.r[0]);
    try std.testing.expectEqual(.data_fault, exec(&s, &m, 0x6008));
    try std.testing.expectEqual(.data_fault, exec(&s, &m, 0xc901));
    try std.testing.expectEqual(@as(u32, 0x1000), s.r[1]);
}

test "word and halfword accesses must be aligned to their size while byte accesses need not be, A3.2.1" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[1] = 2;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0x6808));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0x6008));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x8808));
    s.r[1] = 1;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0x8808));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0x8008));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x7808));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x7008));
}

test "words counts the registers an LDM, STM, PUSH, or POP moves, LR and PC included, Table 3-1" {
    try std.testing.expectEqual(@as(u8, 2), instruction.words(.load_multiple, 0xc906));
    try std.testing.expectEqual(@as(u8, 8), instruction.words(.store_multiple, 0xc0ff));
    try std.testing.expectEqual(@as(u8, 3), instruction.words(.push, 0xb503));
    try std.testing.expectEqual(@as(u8, 2), instruction.words(.pop, 0xbc0c));
    try std.testing.expectEqual(@as(u8, 2), instruction.words(.pop_pc, 0xbd10));
    try std.testing.expectEqual(@as(u8, 0), instruction.words(.load, 0x6808));
}

test "Armv7-M lets a single word or halfword access be unaligned while list operations stay strict, A3.2.1" {
    var s: State = .{};
    var m = memory(.armv7m);
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x6008));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x6808));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xc901));
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x8008));
    try std.testing.expectEqual(.next, exec(&s, &m, 0x8808));
    s.msp = 2;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xbc01));
}

test "CBZ and CBNZ compare Rn with zero and branch forward by the scaled immediate without touching the flags, A7.7.21" {
    var s: State = .{ .xpsr = 0, .pc = 0x10 };
    var m = memory(.armv7m);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xb109));
    try std.testing.expectEqual(@as(u32, 0x16), s.pc);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb909));
    s.r[1] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb109));
    s.pc = 0x10;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xbbf9));
    try std.testing.expectEqual(@as(u32, 0x92), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "LSLS immediate shifts left, moves the last bit out into C, and with a zero shift is MOVS that keeps C, A6.7.35 A6.7.40" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0x8000_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0041));
    try std.testing.expectEqual(@as(u32, 2), s.r[1]);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.r[0] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0001));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[1]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0101));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(State.flag_z, s.xpsr);
}

test "LSRS immediate shifts right, moves the last bit out into C, and a zero encoding means a shift by 32, A6.7.37" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0841));
    try std.testing.expectEqual(@as(u32, 1), s.r[1]);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.r[0] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x0801));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
}

test "ASRS immediate keeps the sign, moves the last bit out into C, and a zero encoding means a shift by 32, A6.7.8" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0x8000_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1041));
    try std.testing.expectEqual(@as(u32, 0xc000_0000), s.r[1]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1001));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[1]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
    s.r[0] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1001));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(State.flag_z, s.xpsr);
}

test "ADDS register sets C on an unsigned carry and V on a signed overflow, A6.7.3" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0xffff_ffff;
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1842));
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 0x7fff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1842));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[2]);
    try std.testing.expectEqual(State.flag_n | State.flag_v, s.xpsr);
}

test "SUBS register and immediate set C when no borrow happens and clear it when one does, A6.7.66 A6.7.65" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 5;
    s.r[1] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1a42));
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x1e41));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[1]);
    try std.testing.expectEqual(State.flag_n, s.xpsr);
    s.r[0] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x3801));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[0]);
    try std.testing.expectEqual(State.flag_c | State.flag_v, s.xpsr);
}

test "CMP immediate sets the flags of a subtraction and leaves the register alone, A6.7.17" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x2805));
    try std.testing.expectEqual(@as(u32, 5), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x2806));
    try std.testing.expectEqual(@as(u32, 5), s.r[0]);
    try std.testing.expectEqual(State.flag_n, s.xpsr);
}

test "ADDS immediate with one register adds the eight-bit immediate into it, A6.7.2" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x3001));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x30ff));
    try std.testing.expectEqual(@as(u32, 0xff), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "ANDS, EORS, ORRS, BICS, and MVNS set N and Z from the result and leave C and V alone, A6.7.7 A6.7.23 A6.7.48 A6.7.11 A6.7.45" {
    var s: State = .{ .xpsr = State.flag_c | State.flag_v };
    var m = memory(.armv6m);
    s.r[0] = 0xf0f0_f0f0;
    s.r[1] = 0x0ff0_0ff0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4008));
    try std.testing.expectEqual(@as(u32, 0x00f0_00f0), s.r[0]);
    try std.testing.expectEqual(State.flag_c | State.flag_v, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4048));
    try std.testing.expectEqual(@as(u32, 0x0f00_0f00), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4308));
    try std.testing.expectEqual(@as(u32, 0x0ff0_0ff0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4388));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c | State.flag_v, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x43c8));
    try std.testing.expectEqual(@as(u32, 0xf00f_f00f), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_c | State.flag_v, s.xpsr);
}

test "TST sets the flags of an AND without writing a register, A6.7.71" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0x8000_0000;
    s.r[1] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4208));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
    try std.testing.expectEqual(State.flag_n, s.xpsr);
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4208));
    try std.testing.expectEqual(State.flag_z, s.xpsr);
}

test "LSLS, LSRS, and ASRS by register use the low byte of Rm, keep C when it is zero, and shift everything out past 32, A6.7.36 A6.7.38 A6.7.9" {
    var s: State = .{ .xpsr = State.flag_c };
    var m = memory(.armv6m);
    s.r[0] = 1;
    s.r[1] = 0x100;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4088));
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.r[1] = 31;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4088));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
    try std.testing.expectEqual(State.flag_n, s.xpsr);
    s.r[1] = 33;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4088));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z, s.xpsr);
    s.r[0] = 0x8000_0000;
    s.r[1] = 32;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x40c8));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 0x8000_0000;
    s.r[1] = 40;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4108));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
}

test "RORS rotates by the low byte of Rm, copies bit 31 of the result into C, and a multiple of 32 only sets C, A6.7.54" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 0x8000_0001;
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x41c8));
    try std.testing.expectEqual(@as(u32, 0xc000_0000), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
    s.r[1] = 32;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x41c8));
    try std.testing.expectEqual(@as(u32, 0xc000_0000), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
    s.r[1] = 0;
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x41c8));
    try std.testing.expectEqual(State.flag_n, s.xpsr);
}

test "ADCS and SBCS take C as the carry in, so a two-word add and subtract chain correctly, A6.7.1 A6.7.56" {
    var s: State = .{ .xpsr = State.flag_c };
    var m = memory(.armv6m);
    s.r[0] = 0xffff_ffff;
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4148));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 5;
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4188));
    try std.testing.expectEqual(@as(u32, 3), s.r[0]);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4188));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
}

test "RSBS negates Rn into Rd and sets the flags of zero minus Rn, A6.7.55" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4248));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[0]);
    try std.testing.expectEqual(State.flag_n, s.xpsr);
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4248));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[1] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4248));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_v, s.xpsr);
}

test "CMP register and CMN set the flags of a subtraction and an addition without writing, A6.7.18 A6.7.16" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[0] = 1;
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4288));
    try std.testing.expectEqual(State.flag_n, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4281));
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.r[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x42c8));
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[1]);
}

test "MULS keeps the low 32 bits of the product and sets N and Z, A6.7.44" {
    var s: State = .{ .xpsr = State.flag_c };
    var m = memory(.armv6m);
    s.r[0] = 0x1_0000;
    s.r[1] = 0x1_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4348));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 3;
    s.r[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4348));
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), s.r[0]);
    try std.testing.expectEqual(State.flag_n | State.flag_c, s.xpsr);
}

test "ADD with high registers adds without touching the flags, reads pc as the address plus four, and branches when pc is the destination, A6.7.3" {
    var s: State = .{ .pc = 0x100, .xpsr = State.flag_c };
    var m = memory(.armv6m);
    s.r[0] = 1;
    s.r[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4408));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_c, s.xpsr);
    s.r[0] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4478));
    try std.testing.expectEqual(@as(u32, 0x114), s.r[0]);
    s.r[1] = 0x21;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x448f));
    try std.testing.expectEqual(@as(u32, 0x124), s.pc);
    s.lr = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4486));
    try std.testing.expectEqual(@as(u32, 0x119), s.lr);
}

test "CMP with high registers sets the flags of the subtraction, A6.7.18" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.lr = 7;
    s.msp = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x45f5));
    try std.testing.expectEqual(State.flag_z | State.flag_c, s.xpsr);
    s.r[0] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4586));
    try std.testing.expectEqual(State.flag_n, s.xpsr);
}

test "MOV with high registers copies without touching the flags and MOV pc, lr returns to the address with its low bit cleared, A6.7.40" {
    var s: State = .{ .pc = 0x100, .xpsr = State.flag_t | State.flag_n };
    var m = memory(.armv6m);
    s.r[0] = 0x1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4680));
    try std.testing.expectEqual(@as(u32, 0x1234), s.r[8]);
    try std.testing.expectEqual(State.flag_t | State.flag_n, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x4641));
    try std.testing.expectEqual(@as(u32, 0x1234), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0x467a));
    try std.testing.expectEqual(@as(u32, 0x104), s.r[2]);
    s.lr = 0x201;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x46f7));
    try std.testing.expectEqual(@as(u32, 0x200), s.pc);
    try std.testing.expectEqual(State.flag_t | State.flag_n, s.xpsr);
}

test "BX branches to Rm with its low bit as the T bit, so an even address leaves T32 state, A6.7.15" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv6m);
    s.lr = 0x301;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4770));
    try std.testing.expectEqual(@as(u32, 0x300), s.pc);
    try std.testing.expectEqual(State.flag_t, s.xpsr);
    s.r[0] = 0x400;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4700));
    try std.testing.expectEqual(@as(u32, 0x400), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "BLX writes the address of the next instruction with the T bit into LR and branches like BX, A6.7.14" {
    var s: State = .{ .pc = 0x100, .xpsr = State.flag_t };
    var m = memory(.armv6m);
    s.r[0] = 0x501;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4780));
    try std.testing.expectEqual(@as(u32, 0x103), s.lr);
    try std.testing.expectEqual(@as(u32, 0x500), s.pc);
    try std.testing.expectEqual(State.flag_t, s.xpsr);
}

test "each conditional branch is taken exactly on the flags of Table A6-1 and steps past itself otherwise, A6.7.10 A6.3" {
    const n = State.flag_n;
    const z = State.flag_z;
    const c = State.flag_c;
    const v = State.flag_v;
    const cases = [_]struct { code: u16, taken: []const u32, not_taken: []const u32 }{
        .{ .code = 0xd002, .taken = &.{z}, .not_taken = &.{0} },
        .{ .code = 0xd102, .taken = &.{0}, .not_taken = &.{z} },
        .{ .code = 0xd202, .taken = &.{c}, .not_taken = &.{0} },
        .{ .code = 0xd302, .taken = &.{0}, .not_taken = &.{c} },
        .{ .code = 0xd402, .taken = &.{n}, .not_taken = &.{0} },
        .{ .code = 0xd502, .taken = &.{0}, .not_taken = &.{n} },
        .{ .code = 0xd602, .taken = &.{v}, .not_taken = &.{0} },
        .{ .code = 0xd702, .taken = &.{0}, .not_taken = &.{v} },
        .{ .code = 0xd802, .taken = &.{c}, .not_taken = &.{ c | z, 0 } },
        .{ .code = 0xd902, .taken = &.{ c | z, 0 }, .not_taken = &.{c} },
        .{ .code = 0xda02, .taken = &.{ 0, n | v }, .not_taken = &.{ n, v } },
        .{ .code = 0xdb02, .taken = &.{ n, v }, .not_taken = &.{ 0, n | v } },
        .{ .code = 0xdc02, .taken = &.{ 0, n | v }, .not_taken = &.{ z, n, v, z | n | v } },
        .{ .code = 0xdd02, .taken = &.{ z, n, v, z | n | v }, .not_taken = &.{ 0, n | v } },
    };
    var m = memory(.armv6m);
    for (cases) |case| {
        for (case.taken) |flags| {
            var s: State = .{ .pc = 0x100, .xpsr = flags };
            try std.testing.expectEqual(.branched, exec(&s, &m, case.code));
            try std.testing.expectEqual(@as(u32, 0x108), s.pc);
        }
        for (case.not_taken) |flags| {
            var s: State = .{ .pc = 0x100, .xpsr = flags };
            try std.testing.expectEqual(.next, exec(&s, &m, case.code));
            try std.testing.expectEqual(@as(u32, 0x100), s.pc);
        }
    }
}

test "a conditional branch offset is the eight-bit immediate doubled and sign-extended, so 0xfe branches to itself, A6.7.10" {
    var s: State = .{ .pc = 0x100, .xpsr = State.flag_z };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xd0fe));
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xd080));
    try std.testing.expectEqual(@as(u32, 0x4), s.pc);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xd07f));
    try std.testing.expectEqual(@as(u32, 0x106), s.pc);
}

test "ADR adds the scaled immediate to the word-aligned pc plus four, A6.7.6" {
    var s: State = .{ .pc = 0x102 };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xa003));
    try std.testing.expectEqual(@as(u32, 0x110), s.r[0]);
}

test "ADD Rd, SP adds the scaled immediate to the current stack pointer and ADD SP and SUB SP move it, A6.7.4 A6.7.67" {
    var s: State = .{ .xpsr = 0, .msp = 0x1000 };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xa902));
    try std.testing.expectEqual(@as(u32, 0x1008), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb002));
    try std.testing.expectEqual(@as(u32, 0x1008), s.msp);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb0ff));
    try std.testing.expectEqual(@as(u32, 0xe0c), s.msp);
    s.control = State.control_spsel;
    s.psp = 0x2000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb081));
    try std.testing.expectEqual(@as(u32, 0x1ffc), s.psp);
    try std.testing.expectEqual(@as(u32, 0xe0c), s.msp);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "SXTH, SXTB, UXTH, and UXTB extend the low halfword or byte with or without the sign, A6.7.70 A6.7.69 A6.7.74 A6.7.73" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv6m);
    s.r[1] = 0x1234_8080;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb208));
    try std.testing.expectEqual(@as(u32, 0xffff_8080), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb248));
    try std.testing.expectEqual(@as(u32, 0xffff_ff80), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb288));
    try std.testing.expectEqual(@as(u32, 0x8080), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb2c8));
    try std.testing.expectEqual(@as(u32, 0x80), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "REV reverses the four bytes, REV16 reverses within each halfword, and REVSH reverses and sign-extends the low halfword, A6.7.51 A6.7.52 A6.7.53" {
    var s: State = .{};
    var m = memory(.armv6m);
    s.r[1] = 0x1234_5680;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xba08));
    try std.testing.expectEqual(@as(u32, 0x8056_3412), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xba48));
    try std.testing.expectEqual(@as(u32, 0x3412_8056), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xbac8));
    try std.testing.expectEqual(@as(u32, 0xffff_8056), s.r[0]);
}

test "CPSID sets PRIMASK and CPSIE clears it when privileged, and both do nothing when unprivileged, A6.7.19 B1.4.3" {
    var s: State = .{};
    var m = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb672));
    try std.testing.expect(s.primask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb662));
    try std.testing.expect(!s.primask);
    s.control = State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb672));
    try std.testing.expect(!s.primask);
}

test "the F forms of CPS move FAULTMASK, which only clears at HardFault priority, and the IF forms move both masks, A7.7.20 B5.2.3" {
    var s: State = .{};
    var m = memory(.armv7m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb671));
    try std.testing.expect(s.faultmask);
    try std.testing.expect(!s.primask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb661));
    try std.testing.expect(!s.faultmask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb673));
    try std.testing.expect(s.faultmask);
    try std.testing.expect(s.primask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb663));
    try std.testing.expect(!s.faultmask);
    try std.testing.expect(!s.primask);
    s.xpsr |= 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb671));
    try std.testing.expect(!s.faultmask);
    s.xpsr = 0;
    s.control = State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xb671));
    try std.testing.expect(!s.faultmask);
}

test "NOP, YIELD, WFE, WFI, SEV, and the unallocated hints execute as NOPs, A6.7.47 A6.7.77 A6.7.75 A6.7.76 A6.7.57 A5.2.5" {
    var m = memory(.armv6m);
    for ([_]u16{ 0xbf00, 0xbf10, 0xbf20, 0xbf30, 0xbf40, 0xbf50, 0xbf60, 0xbf70, 0xbf80, 0xbff0 }) |code| {
        var s: State = .{ .pc = 0x100, .xpsr = State.flag_c };
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(State{ .pc = 0x100, .xpsr = State.flag_c }, s);
    }
}

test "IT writes its condition and mask into ITSTATE, and in the block the 16-bit encodings that write a register leave the flags alone, A7.7.38 A7.7.76" {
    var s: State = .{};
    var m = memory(.armv7m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xbf1c));
    try std.testing.expectEqual(@as(u8, 0x1c), s.itState());
    const flags = State.flag_n | State.flag_z | State.flag_c | State.flag_v;
    for ([_]u16{ 0x2000, 0x1c00, 0x0040, 0x4008, 0x4348, 0x4240 }) |code| {
        s.setItState(0x1c);
        s.xpsr &= ~flags;
        s.r[0] = 0;
        s.r[1] = 0;
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(@as(u32, 0), s.xpsr & flags);
    }
    for ([_]u16{ 0x2800, 0x4200, 0x42c0 }) |code| {
        s.setItState(0x1c);
        s.xpsr &= ~flags;
        s.r[0] = 0;
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expect(s.xpsr & State.flag_z != 0);
    }
    s.setItState(0);
    s.xpsr &= ~flags;
    try std.testing.expectEqual(.next, exec(&s, &m, 0x2000));
    try std.testing.expectEqual(State.flag_z, s.xpsr & flags);
}

test "BXNS leaves Secure state when bit 0 of the target is clear, C2.4.29 E2.1.33" {
    var s: State = .{ .secure = true, .control = State.control_sfpa | State.control_spsel };
    var m = memory(.armv8m_main);
    s.r[0] = 0x40;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4704));
    try std.testing.expect(!s.secure);
    try std.testing.expectEqual(@as(u32, 0x40), s.pc);
    try std.testing.expectEqual(@as(u32, State.flag_t), s.xpsr);
    try std.testing.expectEqual(@as(u32, State.control_spsel), s.control);
}

test "BXNS stays in Secure state when bit 0 of the target is set, C2.4.29" {
    var s: State = .{ .secure = true };
    var m = memory(.armv8m_main);
    s.r[0] = 0x41;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4704));
    try std.testing.expect(s.secure);
    try std.testing.expectEqual(@as(u32, 0x40), s.pc);
}

test "BXNS is undefined in Non-secure state, C2.4.29" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[0] = 0x40;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0x4704));
}

test "BLXNS stacks the return address and the partial RETPSR, hands back FNC_RETURN and leaves Secure state, C2.4.20 B3.16" {
    var s: State = .{ .secure = true, .control = State.control_sfpa, .msp = 0x40 };
    var m = memory(.armv8m_main);
    s.pc = 0x20;
    s.r[0] = 0x80;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4784));
    try std.testing.expect(!s.secure);
    try std.testing.expectEqual(@as(u32, 0x80), s.pc);
    try std.testing.expectEqual(@as(u32, 0xfeff_ffff), s.lr);
    try std.testing.expectEqual(@as(u32, 0x38), s.msp);
    try std.testing.expectEqual(@as(?u32, 0x23), m.peek(u32, 0x38));
    try std.testing.expectEqual(@as(?u32, 1 << 20), m.peek(u32, 0x3c));
    try std.testing.expectEqual(@as(u32, 0), s.control & State.control_sfpa);
}

test "BLXNS stays in Secure state when bit 0 of the target is set, C2.4.20" {
    var s: State = .{ .secure = true, .msp = 0x40 };
    var m = memory(.armv8m_main);
    s.pc = 0x20;
    s.r[0] = 0x81;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4784));
    try std.testing.expect(s.secure);
    try std.testing.expectEqual(@as(u32, 0x80), s.pc);
    try std.testing.expectEqual(@as(u32, 0x23), s.lr);
    try std.testing.expectEqual(@as(u32, 0x40), s.msp);
}

test "BLXNS is undefined in Non-secure state, C2.4.20" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[0] = 0x80;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0x4784));
}

test "a branch to FNC_RETURN from Non-secure state asks for the function return, B3.17" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[0] = 0xfeff_ffff;
    try std.testing.expectEqual(.function_return, exec(&s, &m, 0x4700));
    var secure: State = .{ .secure = true };
    secure.r[0] = 0xfeff_ffff;
    try std.testing.expectEqual(.branched, exec(&secure, &m, 0x4700));
}

test "a branch to FNC_RETURN sets no landing pad, because the Secure caller it returns to is not one, E2.1.34 E2.1.183" {
    var s: State = .{ .xpsr = State.flag_t, .control = State.control_bti_en };
    var m = memory(.armv8_1m_main);
    s.r[3] = 0xfeff_ffff;
    try std.testing.expectEqual(.function_return, exec(&s, &m, 0x4718));
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_b);
    s.r[3] = 0x40;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0x4718));
    try std.testing.expectEqual(State.flag_b, s.xpsr & State.flag_b);
}
