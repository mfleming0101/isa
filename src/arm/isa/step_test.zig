//! Tests of the step loop over a small in-memory host: program counter advance,
//! branches, breakpoints, undefined and unimplemented codes, fetch and data faults,
//! alignment, IT blocks, BTI landing and the branch future instructions.
const std = @import("std");
const State = @import("state.zig").State;
const step = @import("step.zig");
const Stop = step.Stop;
const free: step.Model.Costs = @splat(.{ .cycles = 0, .taken = 0 });
const Architecture = @import("architecture.zig").Architecture;
const instruction = @import("instruction.zig");
const Class = instruction.Class;
const decode = @import("decode.zig");

const Mem = struct {
    const Self = @This();

    bytes: [16]u8,
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

    /// The FP extension is present.
    pub fn treatAsSecure(_: *Self) bool {
        return true;
    }

    /// MVE is present.
    pub fn mve(_: *Self) bool {
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

    /// The bytes from an address, or empty when out of range.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []u8 {
        _ = self.slice(address, a.bytes) orelse return &.{};
        return self.bytes[address..];
    }

    /// Refuses every access no span answered.
    pub fn access(_: *Self, _: u32, comptime _: anytype, _: u32) error{DataFault}!u32 {
        return error.DataFault;
    }

    fn poke(self: *Self, comptime T: type, address: u32, value: T) ?void {
        std.mem.writeInt(T, self.slice(address, @sizeOf(T)) orelse return null, value, .little);
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
};

fn host(p: Architecture) Mem {
    return .{ .bytes = @splat(0), .model = .{ .decoding = decode.selectionOf(p), .costs = free }, .priority_bits = if (p == .armv6m) 2 else 4 };
}

fn memory(codes: []const u16) Mem {
    var m = host(.armv6m);
    for (codes, 0..) |code, i| std.mem.writeInt(u16, m.bytes[2 * i ..][0..2], code, .little);
    return m;
}

fn memory7(codes: []const u16) Mem {
    var m = host(.armv7m);
    for (codes, 0..) |code, i| std.mem.writeInt(u16, m.bytes[2 * i ..][0..2], code, .little);
    return m;
}

fn run(s: *State, m: anytype) step.Result {
    const Host = @TypeOf(m.*);
    return step.step(Host, null, s, m, m.model);
}

test "a 16-bit instruction advances the program counter by two and reports its class" {
    var m = memory(&.{0x2001});
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.retired(0x2001, .data_processing, 0, false), r);
    try std.testing.expectEqual(@as(u32, 2), s.pc);
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
}

test "a taken branch leaves the program counter at the target and says so" {
    var m = memory(&.{0xe001});
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.retired(0xe001, .branch, 0, true), r);
    try std.testing.expectEqual(@as(u32, 6), s.pc);
}

test "a breakpoint stops with the program counter still at the BKPT" {
    var m = memory(&.{ 0x2001, 0xbe00 });
    var s: State = .{ .pc = 2, .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0xbe00, .breakpoint), r);
    try std.testing.expectEqual(@as(u32, 2), s.pc);
    try std.testing.expect(!s.lockup);
}

test "an undefined halfword is a fault whose result carries the code, A6.7.72" {
    var m = memory(&.{0xde00});
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0xde00, .undefined_instruction), r);
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "a step outside T32 state is a fault before fetching, A2.3.1" {
    var m = memory(&.{0x2001});
    var s: State = .{ .xpsr = 0 };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(null, .not_t32_state), r);
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
}

test "a fetch that no memory answers is a fetch fault" {
    var m = memory(&.{});
    var s: State = .{ .pc = 0x1000, .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(null, .fetch_fault), r);
}

test "a load that no memory answers is a data fault that leaves the program counter" {
    var m = memory(&.{0x6808});
    var s: State = .{ .xpsr = State.flag_t };
    s.r[1] = 0x1000;
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0x6808, .data_fault), r);
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "a word load from an address that is not a multiple of four is an unaligned access fault, A3.2.1" {
    var m = memory(&.{0x6808});
    var s: State = .{ .xpsr = State.flag_t };
    s.r[1] = 2;
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0x6808, .unaligned_access), r);
}

test "a load multiple reports the number of registers in its list" {
    var m = memory(&.{0xc90c});
    var s: State = .{ .xpsr = State.flag_t };
    s.r[1] = 4;
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.retired(0xc90c, .load_multiple, 2, false), r);
    try std.testing.expectEqual(@as(u32, 12), s.r[1]);
}

test "a 32-bit instruction fetches its second halfword, advances the program counter by four when it does not branch, and carries both halfwords in its code" {
    var m = memory(&.{ 0xf000, 0xf802 });
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.retired(0xf000_f802, .branch_link, 0, true), r);
    try std.testing.expectEqual(@as(u32, 8), s.pc);
    try std.testing.expectEqual(@as(u32, 5), s.lr);
}

test "a 32-bit code that no row of Armv6-M matches is undefined, since its 32-bit set is closed, A5.3" {
    var m = memory(&.{ 0xf241, 0x2034 });
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0xf241_2034, .undefined_instruction), r);
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "a 32-bit prefix whose second halfword no memory answers is a fetch fault" {
    var m = memory(&.{ 0, 0, 0, 0, 0, 0, 0, 0xf000 });
    var s: State = .{ .pc = 14, .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(null, .fetch_fault), r);
}

test "a row that runs to an undefined outcome is reported as an undefined instruction" {
    var m = memory(&.{ 0xf7f0, 0xa000 });
    var s: State = .{ .xpsr = State.flag_t };
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Result.stopped(0xf7f0_a000, .undefined_instruction), r);
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "an access to a coprocessor this part does not carry is NOCP, and the rest of the undefined space stays UNDEFINSTR, A4.4.2" {
    var s: State = .{ .xpsr = State.flag_t };
    var mcr = memory7(&.{ 0xee07, 0x0f17 });
    try std.testing.expectEqual(step.Result.stopped(0xee07_0f17, .no_coprocessor), run(&s, &mcr));
    s = .{ .xpsr = State.flag_t };
    var ldc = memory7(&.{ 0xed90, 0x5500 });
    try std.testing.expectEqual(step.Result.stopped(0xed90_5500, .no_coprocessor), run(&s, &ldc));
    s = .{ .xpsr = State.flag_t };
    var narrow = memory(&.{ 0xee07, 0x0f17 });
    try std.testing.expectEqual(step.Result.stopped(0xee07_0f17, .undefined_instruction), run(&s, &narrow));
}

test "IT conditions the instructions that follow it, and ITSTATE advances past each one whether it ran or not, A7.7.38 B1.4.2" {
    var m = memory7(&.{ 0xbf14, 0x2001, 0x2102, 0x2203 });
    var s: State = .{ .xpsr = State.flag_t | State.flag_z };
    _ = run(&s, &m);
    try std.testing.expectEqual(@as(u8, 0x14), s.itState());
    try std.testing.expectEqual(@as(u32, 2), s.pc);
    try std.testing.expectEqual(step.Result.retired(0x2001, .data_processing, 0, false), run(&s, &m));
    try std.testing.expectEqual(@as(u32, 4), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(@as(u8, 0x08), s.itState());
    _ = run(&s, &m);
    try std.testing.expectEqual(@as(u32, 2), s.r[1]);
    try std.testing.expectEqual(@as(u8, 0), s.itState());
    _ = run(&s, &m);
    try std.testing.expectEqual(@as(u32, 3), s.r[2]);
}

test "a BKPT in the slot of an IT block whose condition fails breaks all the same, A7.7.17" {
    var m = memory7(&.{ 0xbf08, 0xbe00, 0x2001 });
    var s: State = .{ .xpsr = State.flag_t };
    _ = run(&s, &m);
    const r = run(&s, &m);
    try std.testing.expectEqual(@as(?step.Stop, .breakpoint), r.halt());
    try std.testing.expectEqual(@as(u32, 2), s.pc);
    try std.testing.expectEqual(@as(u8, 0x08), s.itState());
}

test "a 32-bit instruction whose IT condition fails is skipped whole, leaving the program counter four on" {
    var m = memory7(&.{ 0xbf08, 0xf240, 0x0134, 0x2205 });
    var s: State = .{ .xpsr = State.flag_t };
    _ = run(&s, &m);
    try std.testing.expectEqual(step.Result.retired(0xf240_0134, .data_processing, 0, false), run(&s, &m));
    try std.testing.expectEqual(@as(u32, 6), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(@as(u8, 0), s.itState());
    _ = run(&s, &m);
    try std.testing.expectEqual(@as(u32, 5), s.r[2]);
}

test "Armv6-M has no ITSTATE, so bits 26 to 25 and 15 to 10 of xPSR condition nothing" {
    var m = memory(&.{0x2001});
    var s: State = .{ .xpsr = State.flag_t | State.it_mask };
    _ = run(&s, &m);
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(State.flag_t | State.it_mask, s.xpsr);
}

test "a branch to a register sets EPSR.B where BTI is enabled, and only BTI, SG, PACBTI and BKPT may follow it, B6.1.2" {
    var s: State = .{ .xpsr = State.flag_t, .control = State.control_bti_en, .pc = 0 };
    var m = host(.armv8_1m_main);
    _ = m.poke(u16, 0, 0x4788);
    for ([_][2]u16{ .{ 0xf3af, 0x800f }, .{ 0xf3af, 0x800d }, .{ 0xe97f, 0xe97f }, .{ 0xbe00, 0 } }, [_]?Stop{ null, null, null, .breakpoint }) |code, expected| {
        s.pc = 0;
        s.xpsr = State.flag_t;
        s.r[1] = 5;
        _ = m.poke(u16, 4, code[0]);
        _ = m.poke(u16, 6, code[1]);
        try std.testing.expectEqual(@as(?Stop, null), run(&s, &m).halt());
        try std.testing.expect(s.xpsr & State.flag_b != 0);
        try std.testing.expectEqual(expected, run(&s, &m).halt());
    }
    s.pc = 0;
    s.xpsr = State.flag_t;
    s.r[1] = 5;
    _ = m.poke(u16, 4, 0xbf00);
    try std.testing.expectEqual(@as(?Stop, null), run(&s, &m).halt());
    try std.testing.expectEqual(@as(?Stop, .not_branch_target), run(&s, &m).halt());
}

test "BX through LR, POP and a core with BTI disabled leave EPSR.B alone, B6.1.2" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 0, .control = State.control_bti_en };
    var m = host(.armv8_1m_main);
    _ = m.poke(u16, 0, 0x4770);
    s.lr = 5;
    try std.testing.expectEqual(@as(?Stop, null), run(&s, &m).halt());
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_b);
    s.pc = 0;
    s.xpsr = State.flag_t;
    s.control = 0;
    s.r[1] = 5;
    _ = m.poke(u16, 0, 0x4788);
    try std.testing.expectEqual(@as(?Stop, null), run(&s, &m).halt());
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_b);
}

test "the branch future instructions retire as a NOP, which the manual permits and the fallback code covers, C2.4.20" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 0 };
    var m = host(.armv8_1m_main);
    for ([_]u32{ 0xf240e809, 0xf200c809, 0xf262e001, 0xf272e001, 0xf082e003, 0xf0dfeffd }) |code| {
        s.pc = 0;
        s.r[2] = 7;
        _ = m.poke(u16, 0, @truncate(code >> 16));
        _ = m.poke(u16, 2, @truncate(code));
        try std.testing.expectEqual(@as(?Stop, null), run(&s, &m).halt());
        try std.testing.expectEqual(@as(u32, 4), s.pc);
        try std.testing.expectEqual(@as(u32, 7), s.r[2]);
        try std.testing.expectEqual(@as(u32, 0), s.lr);
    }
}
