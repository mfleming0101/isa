//! Tests of the 32-bit T32 rows over an in-memory host with banked Secure state, an
//! exclusive monitor and address attribution: branches, data processing, loads and
//! stores, system instructions, DSP, long shifts and the Armv8-M security rows.
const std = @import("std");
const State = @import("../../../src/arm/isa/state.zig").State;
const decode = @import("../../../src/arm/isa/decode.zig");
const fp = @import("../../../src/arm/isa/fp.zig");
const instruction = @import("../../../src/arm/isa/instruction.zig");
const step = @import("../../../src/arm/isa/step.zig");
const free: step.Model.Costs = @splat(.{ .cycles = 0, .taken = 0 });
const sau = struct {
    const Attribution = struct { ns: bool, nsc: bool = false, region: ?u8 = null };
};
const Architecture = @import("../../../src/arm/isa/architecture.zig").Architecture;

/// Test host with memory, a decode model, banked state and the fitted extensions.
pub const Mem = struct {
    const Self = @This();

    bytes: [64]u8 = @splat(0),
    non_secure: bool = false,
    model: step.Model,
    priority_bits: u4,
    secure_extension: bool,
    pacbti_extension: bool,
    invalid: bool = false,
    exclusive: ?u32 = null,
    fp_extension: bool = true,
    other: State.Banked = .{},

    /// Priority bits the test core implements.
    pub fn priorityBits(self: *Self) u4 {
        return self.priority_bits;
    }

    /// The architecture the test host decodes for.
    pub fn architecture(self: *Self) Architecture {
        return self.model.decoding.architecture;
    }

    /// Whether the Security Extension is fitted.
    pub fn security(self: *Self) bool {
        return self.secure_extension;
    }

    /// Whether the FP extension is fitted.
    pub fn floatingPoint(self: *Self) bool {
        return self.fp_extension;
    }

    pub fn treatAsSecure(_: *Self) bool {
        return true;
    }

    /// The banked registers of the other security state.
    pub fn alternate(self: *Self) *State.Banked {
        return &self.other;
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

    /// FPSCR reset value with the architecture's fixed fields.
    pub fn defaultFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
    }

    /// Non-secure FPSCR value with the architecture's fixed fields.
    pub fn nonSecureFpscr(self: *Self) u32 {
        return fp.fixedFields(self.model.decoding.architecture, 0);
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

    /// MVE is present.
    pub fn mve(_: *Self) bool {
        return true;
    }

    /// Records that the core signalled an invalid state.
    pub fn invalidState(self: *Self) void {
        self.invalid = true;
    }

    /// Whether PACBTI is fitted.
    pub fn pacbti(self: *Self) bool {
        return self.pacbti_extension;
    }

    /// Attribution of an address: Non-secure as the host is configured.
    pub fn attribute(self: *Self, _: u32, _: bool) sau.Attribution {
        return .{ .ns = self.non_secure };
    }

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    /// Ignores an access notice.
    pub fn touch(_: *Self, _: u32) void {}

    /// The exclusive monitor, held here so the tree and the row set share it.
    pub fn monitor(self: *Self) *?u32 {
        return &self.exclusive;
    }

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

/// A test host for an architecture with free costs and the extensions it fits.
pub fn memory(p: Architecture) Mem {
    return .{
        .model = .{ .decoding = decode.selectionOf(p), .costs = free },
        .priority_bits = if (p == .armv6m) 2 else 4,
        .secure_extension = p == .armv8m_main or p == .armv8_1m_main,
        .pacbti_extension = p == .armv8_1m_main,
    };
}

fn exec(s: *State, m: anytype, code: u32) instruction.Outcome {
    const Host = @TypeOf(m.*);
    return step.call(Host, s, m, code, m.model.decoding.groups);
}

test "BL writes the return address with the T bit into LR and branches by the sign-extended 25-bit offset, A7.7.18" {
    var s: State = .{ .pc = 0x10 };
    var m = memory(.armv7em);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf000_f802));
    try std.testing.expectEqual(@as(u32, 0x15), s.lr);
    try std.testing.expectEqual(@as(u32, 0x18), s.pc);
    s.pc = 0x1000;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf7ff_fffe));
    try std.testing.expectEqual(@as(u32, 0x1000), s.pc);
    try std.testing.expectEqual(@as(u32, 0x1005), s.lr);
}

test "B.W branches by the sign-extended 25-bit offset and reaches sixteen megabytes either way, A7.7.12" {
    var s: State = .{ .pc = 0x7f_0002 };
    var m = memory(.armv7em);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf7ff_bffd));
    try std.testing.expectEqual(@as(u32, 0x7f_0000), s.pc);
    s.pc = 0x7f_0006;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf40f_b7fb));
    try std.testing.expectEqual(@as(u32, 0), s.pc);
    s.pc = 0x7f_000e;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf3f0_b001));
    try std.testing.expectEqual(@as(u32, 0xfe_0014), s.pc);
    try std.testing.expectEqual(@as(u32, 0), s.lr);
}

test "B<cond>.W branches by the sign-extended 21-bit offset only when the condition holds, A7.7.12" {
    var s: State = .{ .pc = 0x10, .xpsr = State.flag_z };
    var m = memory(.armv7em);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf000_8001));
    try std.testing.expectEqual(@as(u32, 0x16), s.pc);
    s.pc = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf040_8001));
    try std.testing.expectEqual(@as(u32, 0x10), s.pc);
    s.pc = 0xf_000a;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf000_806b));
    try std.testing.expectEqual(@as(u32, 0xf_00e4), s.pc);
    s.pc = 0xf_0006;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf40f_87fb));
    try std.testing.expectEqual(@as(u32, 0), s.pc);
    s.xpsr = 0;
    for ([_]u32{ 0xf000_8001, 0xf040_8001, 0xf080_8001, 0xf0c0_8001, 0xf100_8001, 0xf140_8001, 0xf180_8001, 0xf1c0_8001, 0xf200_8001, 0xf240_8001, 0xf280_8001, 0xf2c0_8001, 0xf300_8001, 0xf340_8001 }, 0..) |code, cond| {
        s.pc = 0x10;
        const taken = s.condition(@intCast(cond));
        try std.testing.expectEqual(if (taken) instruction.Outcome.branched else .next, exec(&s, &m, code));
        try std.testing.expectEqual(@as(u32, if (taken) 0x16 else 0x10), s.pc);
    }
}

test "the T4 forms index by an eight-bit offset before or after the access and write the base back, A7.7.42 A7.7.158" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8c1_0000));
    s.r[0] = 0xdead_beef;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf841_0b04));
    try std.testing.expectEqual(@as(u32, 0x24), s.r[1]);
    try std.testing.expectEqual(@as(?u32, 0xdead_beef), m.peek(u32, 0x20));
    s.r[2] = 0x5678;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf841_2d04));
    try std.testing.expectEqual(@as(u32, 0x20), s.r[1]);
    try std.testing.expectEqual(@as(?u32, 0x5678), m.peek(u32, 0x20));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf851_3f04));
    try std.testing.expectEqual(@as(u32, 0x24), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf851_4c04));
    try std.testing.expectEqual(@as(u32, 0x24), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0x5678), s.r[4]);
}

test "a post-indexed byte store walks a buffer, which is what compiled code does, A7.7.163" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 4;
    for ([_]u32{ 0x41, 0x42, 0x43 }) |byte| {
        s.r[1] = byte;
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf802_1b01));
    }
    try std.testing.expectEqual(@as(u32, 7), s.r[2]);
    try std.testing.expectEqual(@as(?u32, 0x0043_4241), m.peek(u32, 4));
}

test "the register forms add Rm shifted left by up to three, A7.7.44 A7.7.160" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0x10;
    s.r[2] = 3;
    s.r[0] = 0x1234_5678;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf841_0022));
    try std.testing.expectEqual(@as(?u32, 0x1234_5678), m.peek(u32, 0x1c));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf851_3022));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf811_4022));
    try std.testing.expectEqual(@as(u32, 0x78), s.r[4]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf831_5022));
    try std.testing.expectEqual(@as(u32, 0x5678), s.r[5]);
}

test "LDM and STM move a register list up from Rn or down to it, and write the base back only with W, A7.7.40 A7.7.41 A7.7.156 A7.7.157" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[0] = 0x11;
    s.r[1] = 0x22;
    s.r[4] = 0x33;
    s.lr = 0x44;
    s.r[7] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8a7_4013));
    try std.testing.expectEqual(@as(u32, 0x30), s.r[7]);
    try std.testing.expectEqual(@as(?u32, 0x11), m.peek(u32, 0x20));
    try std.testing.expectEqual(@as(?u32, 0x44), m.peek(u32, 0x2c));
    s.r[0] = 0;
    s.r[1] = 0;
    s.r[4] = 0;
    s.lr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe917_4013));
    try std.testing.expectEqual(@as(u32, 0x30), s.r[7]);
    try std.testing.expectEqual([_]u32{ 0x11, 0x22 }, s.r[0..2].*);
    try std.testing.expectEqual(@as(u32, 0x33), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0x44), s.lr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe937_4013));
    try std.testing.expectEqual(@as(u32, 0x20), s.r[7]);
}

test "an LDM that faults part way through leaves every register it names as it was, base included, B1.5.10" {
    var s: State = .{};
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x3c..0x40], 0x1234_5678, .little);
    s.r[0] = 0x3c;
    s.r[2] = 0x99;
    try std.testing.expectEqual(instruction.Outcome.data_fault, exec(&s, &m, 0xe890_0005));
    try std.testing.expectEqual(@as(u32, 0x3c), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x99), s.r[2]);
}

test "an LDM whose list holds pc branches to it and interworks, A7.7.40" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[3] = 0x20;
    _ = m.poke(u32, 0x20, 0x55);
    _ = m.poke(u32, 0x24, 0x101);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8b3_8002));
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);
    try std.testing.expectEqual(State.flag_t, s.xpsr & State.flag_t);
    try std.testing.expectEqual(@as(u32, 0x55), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0x28), s.r[3]);
}

test "the wide literal forms read from the aligned program counter in both directions, A7.7.44" {
    var s: State = .{ .pc = 0x10 };
    var m = memory(.armv7em);
    _ = m.poke(u32, 0x20, 0xcafe_f00d);
    _ = m.poke(u32, 0x08, 0x0bad_f00d);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8df_000c));
    try std.testing.expectEqual(@as(u32, 0xcafe_f00d), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf85f_000c));
    try std.testing.expectEqual(@as(u32, 0x0bad_f00d), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf85f_100c));
    try std.testing.expectEqual(@as(u32, 0x0bad_f00d), s.r[1]);
    _ = m.poke(u32, 0x0c, 0x0000_00aa);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf81f_2008));
    try std.testing.expectEqual(@as(u32, 0xaa), s.r[2]);
}

test "MOVW writes the 16-bit immediate zero-extended and MOVT replaces only the top half, A7.7.76 A7.7.79" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv7em);
    s.r[0] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf241_2034));
    try std.testing.expectEqual(@as(u32, 0x1234), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf2c5_6078));
    try std.testing.expectEqual(@as(u32, 0x5678_1234), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "TT and TTT report read and write access to every address, because without an MPU an unprivileged access is permitted wherever a privileged one is, C2.4.254" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[1] = 0xe000_e010;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_f300));
    try std.testing.expectEqual(@as(u32, 0x000c_0000), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_f340));
    try std.testing.expectEqual(@as(u32, 0x000c_0000), s.r[3]);
}

test "TT and TTT read as zero from an unprivileged mode, because neither names the alternate domain, C2.4.254" {
    var s: State = .{ .control = State.control_npriv };
    var m = memory(.armv8m_main);
    s.r[1] = 0xe000_e010;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_f300));
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_f340));
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
}

test "TT reports neither a Security attribute nor an SAU region, because this core has no Security Extension, D1.2.269" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[1] = 0x2000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_f300));
    try std.testing.expectEqual(@as(u32, 0), s.r[3] & 0xffc3_0000);
}

test "STL, STLH, and STLB store the low bits of Rt at Rn and LDA, LDAH, and LDAB load them back zero-extended, C2.4.68 C2.4.69 C2.4.73 C2.4.216 C2.4.217 C2.4.221" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[0] = 0x8765_4321;
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_0faf));
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x43, 0x65, 0x87 }, m.bytes[0x10..0x14]);
    s.r[1] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_0f9f));
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x43, 0, 0 }, m.bytes[0x20..0x24]);
    s.r[1] = 0x30;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_0f8f));
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0, 0, 0 }, m.bytes[0x30..0x34]);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_2faf));
    try std.testing.expectEqual(@as(u32, 0x8765_4321), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_2f9f));
    try std.testing.expectEqual(@as(u32, 0x4321), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_2f8f));
    try std.testing.expectEqual(@as(u32, 0x21), s.r[2]);
}

test "LDA and STL fault on an unaligned address although LDR and STR may not, B7.6" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    s.r[1] = 0x12;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe8d1_2faf));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe8c1_0faf));
    s.r[1] = 0x11;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe8d1_2f9f));
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe8c1_0f9f));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_2f8f));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_0f8f));
    s.r[1] = 0x40;
    try std.testing.expectEqual(.data_fault, exec(&s, &m, 0xe8d1_2faf));
}

test "a four-bit register field reaches lr and sp, which only r13 and r15 leave UNPREDICTABLE, C2.4.68 C2.4.76 C2.4.79 C2.4.216 C2.4.254" {
    var s: State = .{ .msp = 0x20 };
    var m = memory(.armv8m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf240_0e01));
    try std.testing.expectEqual(@as(u32, 1), s.lr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf2c0_0e02));
    try std.testing.expectEqual(@as(u32, 0x0002_0001), s.lr);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_efaf));
    try std.testing.expectEqual(@as(u32, 0x0002_0001), m.peek(u32, 0x10).?);
    s.lr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_efaf));
    try std.testing.expectEqual(@as(u32, 0x0002_0001), s.lr);
    s.lr = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8de_2faf));
    try std.testing.expectEqual(@as(u32, 0x0002_0001), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8dd_3faf));
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_fe00));
    try std.testing.expectEqual(@as(u32, 0x000c_0000), s.lr);
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x20), s.msp);
}

test "MRS reads the APSR flags, the IPSR, both stack pointers, PRIMASK, and CONTROL, and only an unprivileged Thread-mode read of a stack pointer or PRIMASK is zero, B4.2.2 B1.4.1" {
    var s: State = .{ .xpsr = 0xf000_0105, .msp = 0x2000_1000, .psp = 0x2000_2000, .primask = true, .control = State.control_spsel };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8000));
    try std.testing.expectEqual(@as(u32, 0xf000_0000), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8005));
    try std.testing.expectEqual(@as(u32, 0x0000_0105), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8003));
    try std.testing.expectEqual(@as(u32, 0xf000_0105), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8006));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8108));
    try std.testing.expectEqual(@as(u32, 0x2000_1000), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8109));
    try std.testing.expectEqual(@as(u32, 0x2000_2000), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8210));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8214));
    try std.testing.expectEqual(@as(u32, 2), s.r[2]);
    s.control |= State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8108));
    try std.testing.expectEqual(@as(u32, 0x2000_1000), s.r[1]);
    s.xpsr &= ~State.ipsr_mask;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8108));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8210));
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8214));
    try std.testing.expectEqual(@as(u32, 3), s.r[2]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8200));
    try std.testing.expectEqual(@as(u32, 0xf000_0000), s.r[2]);
}

test "MSR writes the APSR flags, a stack pointer with its low bits cleared, PRIMASK, and CONTROL, and only the flags when unprivileged, B4.2.3" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv6m);
    s.r[0] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8800));
    try std.testing.expectEqual(@as(u32, 0xf000_0000 | State.flag_t), s.xpsr);
    s.r[0] = 0x2000_0ff3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8808));
    try std.testing.expectEqual(@as(u32, 0x2000_0ff0), s.msp);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8809));
    try std.testing.expectEqual(@as(u32, 0x2000_0ff0), s.psp);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8810));
    try std.testing.expect(s.primask);
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf381_8814));
    try std.testing.expectEqual(State.control_spsel, s.control);
    try std.testing.expectEqual(@as(u32, 0x2000_0ff0), s.sp());
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf381_8814));
    try std.testing.expectEqual(State.control_npriv, s.control);
    s.r[0] = 0x2000_2000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8808));
    try std.testing.expectEqual(@as(u32, 0x2000_0ff0), s.msp);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(State.control_npriv, s.control);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8810));
    try std.testing.expect(s.primask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8800));
    try std.testing.expectEqual(State.flag_t, s.xpsr);
}

test "DSB, DMB, and ISB complete without touching the state, A6.7.22 A6.7.23 A6.7.36" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 8 };
    var m = memory(.armv6m);
    for ([_]u32{ 0xf3bf_8f4f, 0xf3bf_8f5f, 0xf3bf_8f6f }) |code| {
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(State{ .xpsr = State.flag_t, .pc = 8 }, s);
    }
}

test "UDF.W is a permanently undefined 32-bit encoding, A6.7.73" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv6m);
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xf7ff_afff));
}

test "MSR and MRS reach BASEPRI, BASEPRI_MAX, and FAULTMASK on Armv7-M, keeping the implemented priority bits, lowering only through BASEPRI_MAX, and refusing FAULTMASK at HardFault priority, B5.2.2 B5.2.3" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv7em);
    s.r[0] = 0x41;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8811));
    try std.testing.expectEqual(@as(u8, 0x40), s.basepri);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8112));
    try std.testing.expectEqual(@as(u32, 0x40), s.r[1]);
    s.r[0] = 0x60;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8812));
    try std.testing.expectEqual(@as(u8, 0x40), s.basepri);
    s.r[0] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8812));
    try std.testing.expectEqual(@as(u8, 0x20), s.basepri);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8812));
    try std.testing.expectEqual(@as(u8, 0x20), s.basepri);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8811));
    try std.testing.expectEqual(@as(u8, 0), s.basepri);
    s.r[0] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8813));
    try std.testing.expect(s.faultmask);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8113));
    try std.testing.expectEqual(@as(u32, 1), s.r[1]);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8813));
    try std.testing.expect(!s.faultmask);
    s.xpsr |= 3;
    s.r[0] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8813));
    try std.testing.expect(!s.faultmask);
    s.control = State.control_npriv;
    s.xpsr = State.flag_t;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8811));
    try std.testing.expectEqual(@as(u8, 0), s.basepri);
    s.basepri = 0x40;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8111));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
}

test "a special register this architecture does not allocate reads zero and drops its write, and only the ones still to be modelled stop as unimplemented, A7.7.82" {
    var s: State = .{ .xpsr = State.flag_t };
    s.r[0] = 0xffff_ffff;
    s.r[1] = 0xffff_ffff;
    var m6 = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m6, 0xf380_8811));
    try std.testing.expectEqual(.next, exec(&s, &m6, 0xf3ef_8113));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    var m8 = memory(.armv8m_main);
    try std.testing.expectEqual(.next, exec(&s, &m8, 0xf3ef_8118));
    s.r[1] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m8, 0xf3ef_818c));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
}

test "MSPLIM and PSPLIM hold a limit with its low three bits cleared, and belong to the Secure state alone without the Main Extension, D1.2.177" {
    var s: State = .{ .xpsr = State.flag_t, .secure = true };
    var m = memory(.armv8m_main);
    s.r[0] = 0x2000_010f;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_880a));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_810a));
    try std.testing.expectEqual(@as(u32, 0x2000_0108), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_880b));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_810b));
    try std.testing.expectEqual(@as(u32, 0x2000_0108), s.r[1]);
    var base = memory(.armv8m_base);
    s.psplim = 0;
    s.secure = false;
    try std.testing.expectEqual(.next, exec(&s, &base, 0xf380_880b));
    try std.testing.expectEqual(@as(u32, 0), s.psplim);
    s.secure = true;
    try std.testing.expectEqual(.next, exec(&s, &base, 0xf380_880b));
    try std.testing.expectEqual(@as(u32, 0x2000_0108), s.psplim);
}

test "the _NS forms reach the other Security state's copy of each banked register, C2.4.126" {
    var s: State = .{ .xpsr = State.flag_t, .secure = true };
    var m = memory(.armv8m_main);
    for ([_]struct { m: u32, read: u32 }{
        .{ .m = 0x88, .read = 0x2000_0ffc },
        .{ .m = 0x89, .read = 0x2000_0ffc },
        .{ .m = 0x8a, .read = 0x2000_0ff8 },
        .{ .m = 0x8b, .read = 0x2000_0ff8 },
        .{ .m = 0x90, .read = 1 },
        .{ .m = 0x91, .read = 0xf0 },
        .{ .m = 0x93, .read = 1 },
        .{ .m = 0x94, .read = 7 },
    }) |case| {
        s.r[0] = 0x2000_0fff;
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8800 | case.m));
        s.r[1] = 0;
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8100 | case.m));
        try std.testing.expectEqual(case.read, s.r[1]);
    }
    try std.testing.expectEqual(@as(u32, 0), s.msp);
    s.secure = false;
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8188));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
}

test "SP_NS names whichever Non-secure stack the current mode would select, C2.4.126" {
    var s: State = .{ .xpsr = State.flag_t, .secure = true };
    var m = memory(.armv8m_main);
    s.r[0] = 0x2000_0800;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8898));
    try std.testing.expectEqual(@as(u32, 0x2000_0800), m.other.msp);
    m.other.control = State.control_spsel;
    s.r[0] = 0x2000_0400;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8898));
    try std.testing.expectEqual(@as(u32, 0x2000_0400), m.other.psp);
    s.xpsr |= 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8198));
    try std.testing.expectEqual(@as(u32, 0x2000_0800), s.r[1]);
}

test "MSR APSR writes only the four condition flags on Armv6-M and the Q flag as well on Armv7-M, B1.4.2 A6.7.42" {
    var s: State = .{ .xpsr = State.flag_t };
    s.r[0] = 0x0800_0000;
    var m6 = memory(.armv6m);
    try std.testing.expectEqual(.next, exec(&s, &m6, 0xf380_8800));
    try std.testing.expectEqual(State.flag_t, s.xpsr);
    var m7 = memory(.armv7em);
    try std.testing.expectEqual(.next, exec(&s, &m7, 0xf380_8800));
    try std.testing.expectEqual(@as(u32, 0x0800_0000 | State.flag_t), s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m7, 0xf3ef_8100));
    try std.testing.expectEqual(@as(u32, 0x0800_0000), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m6, 0xf3ef_8100));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
}

const flag_n = State.flag_n;
const flag_z = State.flag_z;
const flag_c = State.flag_c;

test "the immediate data-processing rows expand the modified immediate, write the flags only with S, take pc as the destination of TST and CMP, and as the source of MOV and MVN, A5.3.2 A7.7.8 A7.7.91 A7.7.188 A7.7.76 A7.7.85 A7.7.3 A7.7.174 A7.7.27 A7.7.119 A7.7.1 A7.7.124 A7.7.15 A7.7.35" {
    var s: State = .{ .xpsr = 0, .pc = 0x100 };
    var m = memory(.armv7em);
    s.r[1] = 0x1234_5678;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf011_10ff));
    try std.testing.expectEqual(@as(u32, 0x0034_0078), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf051_4000));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
    try std.testing.expectEqual(flag_n | flag_c, s.xpsr);
    s.r[1] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf011_0f01));
    try std.testing.expectEqual(flag_z | flag_c, s.xpsr);
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf04f_305a));
    try std.testing.expectEqual(@as(u32, 0x5a5a_5a5a), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf06f_0000));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[0]);
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf501_7080));
    try std.testing.expectEqual(@as(u32, 0x101), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf1b1_0001));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(flag_z | flag_c, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf1b1_0f02));
    try std.testing.expectEqual(flag_n, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf1c1_0000));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[0]);
    s.xpsr = flag_c;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf151_0000));
    try std.testing.expectEqual(@as(u32, 2), s.r[0]);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf171_0000));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(flag_z | flag_c, s.xpsr);
    s.r[1] = 0xff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf021_000f));
    try std.testing.expectEqual(@as(u32, 0xf0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf081_00ff));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
}

test "the register data-processing rows shift the second operand by the immediate, RRX through the carry, and take pc as the source of MOV and MVN and the destination of TST and CMP, A7.7.9 A7.7.92 A7.7.77 A7.7.118 A7.7.4 A7.7.175 A7.7.28 A7.7.90 A7.7.86 A7.7.16 A7.7.36 A7.7.2 A7.7.125 A7.7.120" {
    var s: State = .{ .xpsr = 0, .pc = 0x100 };
    var m = memory(.armv7em);
    s.r[1] = 0xff;
    s.r[2] = 0xf;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea01_1002));
    try std.testing.expectEqual(@as(u32, 0xf0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea11_0f02));
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
    try std.testing.expectEqual(@as(u32, 0x100), s.pc);
    s.r[1] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea4f_0011));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    s.xpsr = flag_c;
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea5f_0031));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
    try std.testing.expectEqual(flag_n | flag_c, s.xpsr);
    s.xpsr = 0;
    s.r[1] = 5;
    s.r[2] = 0xffff_fffc;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeb11_0062));
    try std.testing.expectEqual(@as(u32, 3), s.r[0]);
    try std.testing.expectEqual(flag_c, s.xpsr);
    s.r[1] = 3;
    s.r[2] = 0x100;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeba1_2032));
    try std.testing.expectEqual(@as(u32, 2), s.r[0]);
    s.r[1] = 0xf0;
    s.r[2] = 0x0f;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea61_0002));
    try std.testing.expectEqual(@as(u32, 0xffff_fff0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea6f_0002));
    try std.testing.expectEqual(@as(u32, 0xffff_fff0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea21_0002));
    try std.testing.expectEqual(@as(u32, 0xf0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea81_0002));
    try std.testing.expectEqual(@as(u32, 0xff), s.r[0]);
    s.xpsr = flag_c;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeb41_0002));
    try std.testing.expectEqual(@as(u32, 0x100), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeb61_0002));
    try std.testing.expectEqual(@as(u32, 0xe1), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xebc1_0002));
    try std.testing.expectEqual(@as(u32, 0xffff_ff1f), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xebb1_0f02));
    try std.testing.expectEqual(flag_c, s.xpsr);
}

test "the register-controlled shifts take the amount from the low byte of Rm and the wide extends rotate first, A7.7.69 A7.7.71 A7.7.11 A7.7.117 A7.7.184 A7.7.223 A7.7.182 A7.7.221" {
    var s: State = .{ .xpsr = 0 };
    var m = memory(.armv7em);
    s.r[1] = 1;
    s.r[2] = 0x104;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa01_f002));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa21_f002));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    s.r[1] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa51_f002));
    try std.testing.expectEqual(@as(u32, 0xf800_0000), s.r[0]);
    try std.testing.expectEqual(flag_n, s.xpsr);
    s.r[1] = 0xf;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa61_f002));
    try std.testing.expectEqual(@as(u32, 0xf000_0000), s.r[0]);
    s.r[1] = 0x8000_1234;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa0f_f0a1));
    try std.testing.expectEqual(@as(u32, 0xffff_8000), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa1f_f0a1));
    try std.testing.expectEqual(@as(u32, 0x8000), s.r[0]);
    s.r[1] = 0x0000_8034;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa4f_f091));
    try std.testing.expectEqual(@as(u32, 0xffff_ff80), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa5f_f081));
    try std.testing.expectEqual(@as(u32, 0x34), s.r[0]);
}

test "ADDW and SUBW add the plain 12-bit immediate without flags and form ADR from the word-aligned pc, A7.7.3 A7.7.174 A7.7.7" {
    var s: State = .{ .xpsr = 0, .pc = 0x102 };
    var m = memory(.armv7em);
    s.r[1] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf601_70ff));
    try std.testing.expectEqual(@as(u32, 0x1000), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf2a1_0001));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf60f_70ff));
    try std.testing.expectEqual(@as(u32, 0x1103), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf2af_0004));
    try std.testing.expectEqual(@as(u32, 0x100), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "the 12-bit offset loads and stores reach every width, sign-extend the signed forms, load literals from the word-aligned pc, and interwork when LDR writes pc, A7.7.43 A7.7.44 A7.7.46 A7.7.55 A7.7.59 A7.7.63 A7.7.161 A7.7.163 A7.7.170" {
    var s: State = .{ .pc = 0x2 };
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x8000_1234, .little);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8d1_0010));
    try std.testing.expectEqual(@as(u32, 0x8000_1234), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf891_0010));
    try std.testing.expectEqual(@as(u32, 0x34), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8b1_0010));
    try std.testing.expectEqual(@as(u32, 0x1234), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf991_0013));
    try std.testing.expectEqual(@as(u32, 0xffff_ff80), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf9b1_0012));
    try std.testing.expectEqual(@as(u32, 0xffff_8000), s.r[0]);
    s.r[0] = 0xdead_beef;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8c1_0020));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), std.mem.readInt(u32, m.bytes[0x20..0x24], .little));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf881_0024));
    try std.testing.expectEqual(@as(u8, 0xef), m.bytes[0x24]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8a1_0026));
    try std.testing.expectEqual(@as(u16, 0xbeef), std.mem.readInt(u16, m.bytes[0x26..0x28], .little));
    std.mem.writeInt(u32, m.bytes[0xc..0x10], 0x11, .little);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf8df_0008));
    try std.testing.expectEqual(@as(u32, 0x11), s.r[0]);
    std.mem.writeInt(u32, m.bytes[0x30..0x34], 0x21, .little);
    s.r[1] = 0x30;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf8d1_f000));
    try std.testing.expectEqual(@as(u32, 0x20), s.pc);
    try std.testing.expectEqual(State.flag_t, s.xpsr);
}

test "the 12-bit offset stores are UNDEFINED with the program counter for a base, since that encoding is where the literal loads live, A7.7.161 A7.7.163 A7.7.170" {
    var s: State = .{ .pc = 0x10 };
    var m = memory(.armv7em);
    s.r[0] = 0xdead_beef;
    for ([_]u32{ 0xf8cf_0010, 0xf88f_0010, 0xf8af_0010, 0xf84f_0e10, 0xf80f_0e10, 0xf82f_0e10 }) |code| {
        try std.testing.expectEqual(.undefined, exec(&s, &m, code));
    }
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, m.bytes[0x24..0x28], .little));
}

test "LDRD and STRD move two words at the scaled offset, write back the pre-indexed and post-indexed forms, load literals, and fault on an unaligned address, A7.7.50 A7.7.51 A7.7.166" {
    var s: State = .{ .pc = 0x2 };
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x18..0x1c], 1, .little);
    std.mem.writeInt(u32, m.bytes[0x1c..0x20], 2, .little);
    s.r[2] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe9d2_0102));
    try std.testing.expectEqual([_]u32{ 1, 2, 0x10 }, s.r[0..3].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe9f2_0102));
    try std.testing.expectEqual(@as(u32, 0x18), s.r[2]);
    s.r[2] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe952_0102));
    try std.testing.expectEqual([_]u32{ 1, 2, 0x20 }, s.r[0..3].*);
    s.r[2] = 0x18;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8f2_0102));
    try std.testing.expectEqual([_]u32{ 1, 2, 0x20 }, s.r[0..3].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe872_0102));
    try std.testing.expectEqual([_]u32{ 0, 0, 0x18 }, s.r[0..3].*);
    s.r[0] = 3;
    s.r[1] = 4;
    s.r[2] = 0x20;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe9c2_0102));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, m.bytes[0x28..0x2c], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, m.bytes[0x2c..0x30], .little));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe962_0102));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, m.bytes[0x18..0x1c], .little));
    try std.testing.expectEqual(@as(u32, 0x18), s.r[2]);
    s.r[0] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8e2_0102));
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, m.bytes[0x18..0x1c], .little));
    try std.testing.expectEqual(@as(u32, 0x20), s.r[2]);
    std.mem.writeInt(u32, m.bytes[0xc..0x10], 6, .little);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 7, .little);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe9df_0102));
    try std.testing.expectEqual([_]u32{ 6, 7 }, s.r[0..2].*);
    s.r[2] = 0x11;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe9d2_0000));
}

test "TBB and TBH branch forward by twice the table entry indexed from Rn, which may be pc, A7.7.185" {
    var s: State = .{ .pc = 0x10 };
    var m = memory(.armv7em);
    m.bytes[0x16] = 5;
    s.r[0] = 2;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8df_f000));
    try std.testing.expectEqual(@as(u32, 0x1e), s.pc);
    s.pc = 0x10;
    s.r[0] = 1;
    std.mem.writeInt(u16, m.bytes[0x16..0x18], 0x100, .little);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8df_f010));
    try std.testing.expectEqual(@as(u32, 0x214), s.pc);
    s.pc = 0x10;
    s.r[0] = 0;
    s.r[1] = 0x20;
    m.bytes[0x20] = 1;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8d1_f000));
    try std.testing.expectEqual(@as(u32, 0x16), s.pc);
    s.pc = 0x10;
    s.r[0] = 0x8000_0000;
    std.mem.writeInt(u16, m.bytes[0x20..0x22], 3, .little);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8d1_f010));
    try std.testing.expectEqual(@as(u32, 0x1a), s.pc);
}

test "BFI inserts the low bits of Rn at lsb, BFC clears them, and SBFX and UBFX extract a field with and without the sign, A7.7.14 A7.7.13 A7.7.126 A7.7.203" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[0] = 0xffff_ffff;
    s.r[1] = 0x12;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf361_100b));
    try std.testing.expectEqual(@as(u32, 0xffff_f12f), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf36f_100b));
    try std.testing.expectEqual(@as(u32, 0xffff_f00f), s.r[0]);
    s.r[1] = 0x0000_0f80;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf341_1007));
    try std.testing.expectEqual(@as(u32, 0xffff_fff8), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3c1_1007));
    try std.testing.expectEqual(@as(u32, 0xf8), s.r[0]);
}

test "the long multiplies write the 64-bit product with and without the accumulator, and the divides return zero for a zero divisor and the minimum for the overflowing signed case, A7.7.149 A7.7.208 A7.7.138 A7.7.207 A7.7.127 A7.7.204" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0xffff_fffe;
    s.r[3] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb82_0103));
    try std.testing.expectEqual([_]u32{ 0xffff_fffa, 0xffff_ffff }, s.r[0..2].*);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfba2_0103));
    try std.testing.expectEqual([_]u32{ 0xffff_fffa, 2 }, s.r[0..2].*);
    s.r[0] = 6;
    s.r[1] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbc2_0103));
    try std.testing.expectEqual([_]u32{ 0, 0 }, s.r[0..2].*);
    s.r[0] = 6;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbe2_0103));
    try std.testing.expectEqual([_]u32{ 0, 3 }, s.r[0..2].*);
    s.r[1] = 0xffff_fff9;
    s.r[2] = 2;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb91_f0f2));
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), s.r[0]);
    s.r[1] = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbb1_f0f2));
    try std.testing.expectEqual(@as(u32, 3), s.r[0]);
    s.r[2] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb91_f0f2));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    s.r[1] = 0x8000_0000;
    s.r[2] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb91_f0f2));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), s.r[0]);
}

test "PUSH.W and POP.W move any of r0 to r12 with lr, and POP.W with pc interworks, A7.7.101 A7.7.99" {
    var s: State = .{ .msp = 0x40 };
    var m = memory(.armv7em);
    s.r[4] = 4;
    s.r[5] = 5;
    s.r[8] = 8;
    s.lr = 0x21;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe92d_4130));
    try std.testing.expectEqual(@as(u32, 0x30), s.msp);
    try std.testing.expectEqual([_]u8{ 4, 0, 0, 0, 5, 0, 0, 0, 8, 0, 0, 0, 0x21, 0, 0, 0 }, m.bytes[0x30..0x40].*);
    s.r[4] = 0;
    s.r[5] = 0;
    s.r[8] = 0;
    s.lr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8bd_4130));
    try std.testing.expectEqual([_]u32{ 4, 5 }, s.r[4..6].*);
    try std.testing.expectEqual(@as(u32, 8), s.r[8]);
    try std.testing.expectEqual(@as(u32, 0x21), s.lr);
    try std.testing.expectEqual(@as(u32, 0x40), s.msp);
    s.msp = 0x38;
    s.r[8] = 0;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xe8bd_8100));
    try std.testing.expectEqual(@as(u32, 8), s.r[8]);
    try std.testing.expectEqual(@as(u32, 0x20), s.pc);
    try std.testing.expectEqual(@as(u32, 0x40), s.msp);
}

test "STREX succeeds only while LDREX holds its address, and reports zero on success, A7.7.66 A7.7.166" {
    var s: State = .{};
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 7, .little);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe851_0f00));
    try std.testing.expectEqual(@as(u32, 7), s.r[0]);
    try std.testing.expectEqual(@as(?u32, 0x10), s.exclusive);
    s.r[0] = 9;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
    try std.testing.expectEqual(@as(u32, 9), m.peek(u32, 0x10).?);
    try std.testing.expectEqual(@as(?u32, null), s.exclusive);
    s.r[0] = 11;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(@as(u32, 9), m.peek(u32, 0x10).?);
}

test "STREX fails when the address differs from the one LDREX held, and opens the monitor anyway, so the next STREX to the tagged address fails too, A3.4.1 A7.7.166" {
    var s: State = .{};
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 7, .little);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe851_0f00));
    try std.testing.expectEqual(@as(?u32, 0x10), s.exclusive);
    s.r[0] = 0xabcd;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_0201));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(@as(u32, 0), m.peek(u32, 0x14).?);
    try std.testing.expectEqual(@as(?u32, null), s.exclusive);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(@as(u32, 7), m.peek(u32, 0x10).?);
}

test "STREX to an unaligned address faults whatever the monitor holds, and leaves it holding it, E2.1.125" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0x11;
    s.r[0] = 5;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(?u32, null), s.exclusive);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe851_0f00));
    s.r[1] = 0x11;
    try std.testing.expectEqual(.unaligned, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(?u32, 0x10), s.exclusive);
}

test "CLREX clears the monitor so the next STREX fails, A7.7.28" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe851_0f00));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3bf_8f2f));
    try std.testing.expectEqual(@as(?u32, null), s.exclusive);
    s.r[0] = 0xabcd;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe841_0200));
    try std.testing.expectEqual(@as(u32, 1), s.r[2]);
    try std.testing.expectEqual(@as(u32, 0), m.peek(u32, 0x10).?);
}

test "the byte and halfword exclusive pairs move only their own width, A7.7.51 A7.7.52 A7.7.167 A7.7.168" {
    var s: State = .{};
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0xaabb_ccdd, .little);
    s.r[1] = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_4f4f));
    try std.testing.expectEqual(@as(u32, 0xdd), s.r[4]);
    s.r[4] = 0x11;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_4f45));
    try std.testing.expectEqual(@as(u32, 0), s.r[5]);
    try std.testing.expectEqual(@as(u32, 0xaabb_cc11), m.peek(u32, 0x10).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_6f5f));
    try std.testing.expectEqual(@as(u32, 0xcc11), s.r[6]);
    s.r[6] = 0x2233;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_6f57));
    try std.testing.expectEqual(@as(u32, 0), s.r[7]);
    try std.testing.expectEqual(@as(u32, 0xaabb_2233), m.peek(u32, 0x10).?);
}

test "the carved STREX rows reach r8 to r14 as the value register, A7.7.166" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0x10;
    for ([_]struct { u32, u4 }{ .{ 0xe841_8900, 8 }, .{ 0xe841_ca00, 12 }, .{ 0xe841_eb00, 14 } }) |pair| {
        const code, const t = pair;
        try std.testing.expectEqual(.next, exec(&s, &m, 0xe851_0f00));
        s.set(t, 0x1000 + @as(u32, t));
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(@as(u32, 0x1000 + @as(u32, t)), m.peek(u32, 0x10).?);
    }
}

test "MUL is MLA with pc as the addend, and MLS subtracts the product, A7.7.74 A7.7.73 A7.7.75" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 5;
    s.r[2] = 32;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb01_f602));
    try std.testing.expectEqual(@as(u32, 160), s.r[6]);
    s.r[3] = 0xffff_0123;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb01_3702));
    try std.testing.expectEqual(@as(u32, 0xffff_01c3), s.r[7]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb01_3812));
    try std.testing.expectEqual(@as(u32, 0xffff_0083), s.r[8]);
}

test "CLZ counts leading zeros and answers 32 for zero, A7.7.24" {
    var s: State = .{};
    var m = memory(.armv7em);
    for ([_][2]u32{ .{ 5, 29 }, .{ 0, 32 }, .{ 0x8000_0000, 0 }, .{ 1, 31 } }) |pair| {
        s.r[2] = pair[0];
        try std.testing.expectEqual(.next, exec(&s, &m, 0xfab2_f982));
        try std.testing.expectEqual(pair[1], s.r[9]);
    }
}

test "RBIT, REV.W, REV16.W and REVSH.W each reverse their own unit, A7.7.113 A7.7.114 A7.7.115 A7.7.116" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0xffff_0123;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa92_faa2));
    try std.testing.expectEqual(@as(u32, 0xc480_ffff), s.r[10]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa92_fb82));
    try std.testing.expectEqual(@as(u32, 0x2301_ffff), s.r[11]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa92_fc92));
    try std.testing.expectEqual(@as(u32, 0xffff_2301), s.r[12]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa92_f0b2));
    try std.testing.expectEqual(@as(u32, 0x0000_2301), s.r[0]);
    s.r[2] = 0x0000_00ff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa92_f0b2));
    try std.testing.expectEqual(@as(u32, 0xffff_ff00), s.r[0]);
}

test "SSAT and USAT clamp to their width, shift the operand first, and set the sticky Q flag, A7.7.128 A7.7.179" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf301_0003));
    try std.testing.expectEqual(@as(u32, 5), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_q);
    s.r[1] = 0x8000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf301_0003));
    try std.testing.expectEqual(@as(u32, 0xffff_fff8), s.r[0]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
    s.xpsr &= ~State.flag_q;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf381_0004));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
    s.xpsr &= ~State.flag_q;
    s.r[1] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf301_0387));
    try std.testing.expectEqual(@as(u32, 20), s.r[3]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_q);
    s.r[1] = 0xffff_0123;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf321_04c7));
    try std.testing.expectEqual(@as(u32, 0xffff_ff80), s.r[4]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
}

const simd_n: u32 = 0x7f01_ff80;
const simd_m: u32 = 0x0280_0110;

fn ge(s: *const State) u32 {
    return (s.xpsr & State.flag_ge) >> 16;
}

test "the six parallel prefixes each combine bytes their own way, A7.7.123 A7.7.141" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = simd_n;
    s.r[3] = simd_m;
    for ([_][2]u32{
        .{ 0xfa82_f103, 0x8181_0090 },
        .{ 0xfa82_f113, 0x7f81_0090 },
        .{ 0xfa82_f123, 0x40c0_00c8 },
        .{ 0xfa82_f143, 0x8181_0090 },
        .{ 0xfa82_f153, 0x8181_ff90 },
        .{ 0xfa82_f163, 0x4040_8048 },
    }) |pair| {
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(pair[1], s.r[1]);
    }
}

test "the halfword parallel forms pair their lanes, and ASX and SAX cross them, A7.7.121 A7.7.155" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = simd_n;
    s.r[3] = simd_m;
    for ([_][3]u32{
        .{ 0xfa92_f103, 0x8181_0090, 0xf },
        .{ 0xfad2_f103, 0x7c81_fe70, 0xc },
        .{ 0xfaa2_f103, 0x8011_fd00, 0xc },
        .{ 0xfae2_f103, 0x7df1_0200, 0xf },
    }) |triple| {
        try std.testing.expectEqual(.next, exec(&s, &m, triple[0]));
        try std.testing.expectEqual(triple[1], s.r[1]);
        try std.testing.expectEqual(triple[2], ge(&s));
    }
}

test "only the plain signed and unsigned parallel forms write GE, and SEL reads it, A7.7.124" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = simd_n;
    s.r[3] = simd_m;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa82_f103));
    try std.testing.expectEqual(@as(u32, 0xa), ge(&s));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa82_f143));
    try std.testing.expectEqual(@as(u32, 0x2), ge(&s));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa82_f113));
    try std.testing.expectEqual(@as(u32, 0x2), ge(&s));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfac2_f143));
    try std.testing.expectEqual(@as(u32, 0xb), ge(&s));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfaa2_f183));
    try std.testing.expectEqual(@as(u32, 0x7f80_ff80), s.r[1]);
}

test "MRS reads the GE bits back out of APSR, B5.2.3" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = simd_n;
    s.r[3] = simd_m;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa82_f103));
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8000));
    try std.testing.expectEqual(State.flag_ge & (0xa << 16), s.r[0] & State.flag_ge);
}

test "QADD and QDADD saturate to 32 bits and set Q, and QDADD saturates the doubling too, A7.7.94 A7.7.96" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x7fff_ffff;
    s.r[3] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa83_f182));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[1]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
    s.xpsr &= ~State.flag_q;
    s.r[2] = 0;
    s.r[3] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa83_f192));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[1]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
}

test "the accumulating extends add into Rn, reach r12 and r14 through the carve, and XTB16 does both halves, A7.7.158 A7.7.160" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x100;
    s.r[3] = 0x0000_00ff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa42_f183));
    try std.testing.expectEqual(@as(u32, 0xff), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa52_f183));
    try std.testing.expectEqual(@as(u32, 0x1ff), s.r[1]);
    s.r[12] = 0x100;
    s.lr = 0x200;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa4c_f183));
    try std.testing.expectEqual(@as(u32, 0xff), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa4e_f183));
    try std.testing.expectEqual(@as(u32, 0x1ff), s.r[1]);
    s.r[2] = 0x0010_0010;
    s.r[3] = 0x00ff_00ff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfa22_f183));
    try std.testing.expectEqual(@as(u32, 0x000f_000f), s.r[1]);
}

test "PKHBT keeps Rn low with Rm high and PKHTB shifts Rm into the low half, A7.7.91" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x1111_2222;
    s.r[3] = 0x3333_4444;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeac2_0103));
    try std.testing.expectEqual(@as(u32, 0x3333_2222), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xeac2_11e3));
    try std.testing.expectEqual(@as(u32, 0x1111_6688), s.r[1]);
}

test "SSAT16 and USAT16 clamp both halfwords and set Q, A7.7.129 A7.7.180" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x0050_0080;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf322_0103));
    try std.testing.expectEqual(@as(u32, 0x0007_0007), s.r[1]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
    s.xpsr &= ~State.flag_q;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3a2_0104));
    try std.testing.expectEqual(@as(u32, 0x000f_000f), s.r[1]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
}

test "the halfword multiplies select their halves, and SMUL is SMLA with pc, A7.7.148 A7.7.164" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x0002_0003;
    s.r[3] = 0x0004_0005;
    for ([_][2]u32{ .{ 0xfb12_f103, 15 }, .{ 0xfb12_f113, 12 }, .{ 0xfb12_f123, 10 }, .{ 0xfb12_f133, 8 } }) |pair| {
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(pair[1], s.r[1]);
    }
    s.r[4] = 100;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb12_4103));
    try std.testing.expectEqual(@as(u32, 115), s.r[1]);
}

test "the dual multiplies sum or difference both lane products and X swaps Rm, A7.7.146 A7.7.150" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x0002_0003;
    s.r[3] = 0x0004_0005;
    s.r[4] = 100;
    for ([_][2]u32{ .{ 0xfb22_4103, 123 }, .{ 0xfb22_4113, 122 }, .{ 0xfb42_4103, 107 } }) |pair| {
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(pair[1], s.r[1]);
    }
}

test "SMMUL keeps the top word and SMMLA accumulates into it, A7.7.152 A7.7.153" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x4000_0000;
    s.r[3] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb52_f103));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), s.r[1]);
    s.r[4] = 1;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb52_4103));
    try std.testing.expectEqual(@as(u32, 0x1000_0001), s.r[1]);
}

test "SMMLA wraps the 64-bit sum of the accumulator and the product instead of trapping, A7.7.152" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x7fff_ffff;
    s.r[3] = 0x7fff_ffff;
    s.r[4] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb52_4103));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[1]);
    s.r[4] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb52_4103));
    try std.testing.expectEqual(@as(u32, 0x3fff_fffe), s.r[1]);
}

test "USAD8 sums the absolute byte differences and USADA8 adds Ra, A7.7.177 A7.7.178" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x0102_0304;
    s.r[3] = 0x0403_0201;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb72_f103));
    try std.testing.expectEqual(@as(u32, 8), s.r[1]);
    s.r[4] = 10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb72_4103));
    try std.testing.expectEqual(@as(u32, 18), s.r[1]);
}

test "SMLALBB and SMLALD accumulate into the register pair, A7.7.147 A7.7.149" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[1] = 0;
    s.r[2] = 0;
    s.r[3] = 0x0000_0003;
    s.r[4] = 0x0000_0005;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbc3_1284));
    try std.testing.expectEqual(@as(u32, 15), s.r[1]);
    try std.testing.expectEqual(@as(u32, 0), s.r[2]);
    s.r[1] = 0;
    s.r[3] = 0x0002_0003;
    s.r[4] = 0x0004_0005;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbc3_12c4));
    try std.testing.expectEqual(@as(u32, 23), s.r[1]);
}

test "all eight LDRD and STRD immediate forms decode, including the subtracting pre-indexed writeback, A7.7.49 A7.7.166" {
    var s: State = .{};
    var m = memory(.armv7em);
    std.mem.writeInt(u32, m.bytes[0x10..0x14], 0x1111_1111, .little);
    std.mem.writeInt(u32, m.bytes[0x14..0x18], 0x2222_2222, .little);
    for ([_][2]u32{
        .{ 0xe972_0102, 2 },
        .{ 0xe9f2_0102, 4 },
    }) |pair| {
        s.r[2] = if (pair[1] == 2) 0x18 else 0x08;
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(@as(u32, 0x1111_1111), s.r[0]);
        try std.testing.expectEqual(@as(u32, 0x2222_2222), s.r[1]);
        try std.testing.expectEqual(@as(u32, 0x10), s.r[2]);
    }
    s.r[9] = 0x18;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe979_0102));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[9]);
    s.r[12] = 0x18;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97c_0102));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[12]);
    s.lr = 0x18;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97e_0102));
    try std.testing.expectEqual(@as(u32, 0x10), s.lr);
    s.r[2] = 0x18;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe952_0102));
    try std.testing.expectEqual(@as(u32, 0x18), s.r[2]);
}

test "a wide load or store whose base register is pc is undefined rather than unwritten, A7.7.158" {
    var s: State = .{};
    var m = memory(.armv7em);
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xf84f_0f04));
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xf84f_0004));
}

test "SG in Secure memory entered from Non-secure state switches to Secure and marks the return, C2.4.180" {
    var s: State = .{ .lr = 0x21, .control = State.control_sfpa, .xpsr = 0x0600_0000 };
    var m = memory(.armv8m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97f_e97f));
    try std.testing.expect(s.secure);
    try std.testing.expectEqual(@as(u32, 0x20), s.lr);
    try std.testing.expectEqual(@as(u32, 0), s.control);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "SG in Non-secure memory is a NOP, C2.4.180" {
    var s: State = .{ .lr = 0x21, .xpsr = 0x0600_0000 };
    var m = memory(.armv8m_main);
    m.non_secure = true;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97f_e97f));
    try std.testing.expect(!s.secure);
    try std.testing.expectEqual(@as(u32, 0x21), s.lr);
    try std.testing.expectEqual(@as(u32, 0x0600_0000), s.xpsr);
}

test "SG clears EPSR.B wherever it stands, because it is a landing pad there, B6.1.2" {
    var s: State = .{ .xpsr = State.flag_t | State.flag_b };
    var m = memory(.armv8_1m_main);
    m.non_secure = true;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97f_e97f));
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_b);
    var secure: State = .{ .secure = true, .xpsr = State.flag_t | State.flag_b };
    try std.testing.expectEqual(.next, exec(&secure, &m, 0xe97f_e97f));
    try std.testing.expectEqual(@as(u32, 0), secure.xpsr & State.flag_b);
}

test "SG reached from Secure state banks nothing and only clears the IT state, C2.4.180" {
    var s: State = .{ .secure = true, .lr = 0x21, .xpsr = 0x0600_0000 };
    var m = memory(.armv8m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe97f_e97f));
    try std.testing.expect(s.secure);
    try std.testing.expectEqual(@as(u32, 0x21), s.lr);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr);
}

test "DLS loads the loop counter into LR, LE spends one iteration of it per pass, and WLS skips a loop of no iterations, C2.4.103 C2.4.492" {
    var s: State = .{ .pc = 0x10, .fpscr = fp.ltpsize };
    var m = memory(.armv8_1m_main);
    s.r[0] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf040_e001));
    try std.testing.expectEqual(@as(u32, 3), s.lr);
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf00f_c803));
    try std.testing.expectEqual(@as(u32, 2), s.lr);
    try std.testing.expectEqual(@as(u32, 0xe), s.pc);
    s.pc = 0x10;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf00f_c803));
    try std.testing.expectEqual(@as(u32, 1), s.lr);
    s.pc = 0x10;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf00f_c803));
    try std.testing.expectEqual(@as(u32, 1), s.lr);
    s.r[1] = 0;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf041_c819));
    try std.testing.expectEqual(@as(u32, 0x46), s.pc);
    try std.testing.expectEqual(@as(u32, 1), s.lr);
    s.pc = 0x10;
    s.r[1] = 5;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf041_c819));
    try std.testing.expectEqual(@as(u32, 5), s.lr);
    s.pc = 0x20;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf02f_c805));
    try std.testing.expectEqual(@as(u32, 0x1a), s.pc);
    try std.testing.expectEqual(@as(u32, 5), s.lr);
}

test "CLRM zeroes the registers its list names, and only those, C2.4.36" {
    var s: State = .{ .pc = 0x10, .lr = 0x99 };
    var m = memory(.armv8_1m_main);
    s.r[0] = 1;
    s.r[1] = 2;
    s.r[2] = 3;
    s.r[4] = 4;
    s.r[12] = 5;
    s.xpsr = State.flag_n | State.flag_z | State.flag_ge | State.flag_t;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe89f_9013));
    try std.testing.expectEqual([_]u32{ 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, s.r);
    try std.testing.expectEqual(@as(u32, 0x99), s.lr);
    try std.testing.expectEqual(State.flag_t, s.xpsr);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe89f_4000));
    try std.testing.expectEqual(@as(u32, 0), s.lr);
}

test "the conditional selects take the first register when the condition holds and the second incremented, inverted or negated when it does not, and read register 15 as zero, C2.4.45 C2.4.48 C2.4.49 C2.4.50" {
    var s: State = .{ .pc = 0x10 };
    var m = memory(.armv8_1m_main);
    s.r[1] = 7;
    s.r[2] = 9;
    s.xpsr = State.flag_z;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_8002));
    try std.testing.expectEqual(@as(u32, 7), s.r[0]);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_8002));
    try std.testing.expectEqual(@as(u32, 9), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_9002));
    try std.testing.expectEqual(@as(u32, 10), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_a002));
    try std.testing.expectEqual(@as(u32, 0xffff_fff6), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_b002));
    try std.testing.expectEqual(@as(u32, 0xffff_fff7), s.r[0]);
    s.xpsr = State.flag_z;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_830f));
    try std.testing.expectEqual(@as(u32, 7), s.r[3]);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea51_830f));
    try std.testing.expectEqual(@as(u32, 0), s.r[3]);
    s.xpsr = State.flag_z;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea5f_931f));
    try std.testing.expectEqual(@as(u32, 1), s.r[3]);
}

test "the mask field of MSR picks the flags, the GE bits or both, and the GE bits move only where the DSP extension is, A7.7.82" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[0] = 0xf80f_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8400));
    try std.testing.expectEqual(@as(u32, 0xf), ge(&s));
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & 0xf800_0000);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8800));
    try std.testing.expectEqual(@as(u32, 0xf800_000f), s.xpsr & 0xf800_0000 | ge(&s));
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8c00));
    try std.testing.expectEqual(@as(u32, 0xf800_000f), s.xpsr & 0xf800_0000 | ge(&s));
    var narrow = memory(.armv7m);
    s.xpsr = 0;
    try std.testing.expectEqual(.next, exec(&s, &narrow, 0xf380_8c00));
    try std.testing.expectEqual(@as(u32, 0), ge(&s));
    try std.testing.expectEqual(@as(u32, 0xf800_0000), s.xpsr & 0xf800_0000);
}

test "the unprivileged loads and stores reach the same memory as the ordinary forms, because without an MPU an unprivileged access is permitted wherever a privileged one is, A7.7.55" {
    var s: State = .{};
    var m = memory(.armv7em);
    _ = m.poke(u32, 0x14, 0x8899_aabb);
    s.r[0] = 0x10;
    for ([_][2]u32{
        .{ 0xf850_5e04, 0x8899_aabb },
        .{ 0xf810_5e04, 0x0000_00bb },
        .{ 0xf830_5e04, 0x0000_aabb },
        .{ 0xf910_5e04, 0xffff_ffbb },
        .{ 0xf930_5e04, 0xffff_aabb },
    }) |pair| {
        s.r[5] = 0;
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(pair[1], s.r[5]);
    }
    s.r[5] = 0x1234_5678;
    for ([_][2]u32{
        .{ 0xf840_5e04, 0x1234_5678 },
        .{ 0xf800_5e04, 0x0000_0078 },
        .{ 0xf820_5e04, 0x0000_5678 },
    }) |pair| {
        _ = m.poke(u32, 0x14, 0);
        try std.testing.expectEqual(.next, exec(&s, &m, pair[0]));
        try std.testing.expectEqual(@as(?u32, pair[1]), m.peek(u32, 0x14));
    }
    _ = m.poke(u32, 0x14, 0x1234_5678);
    s.r[9] = 0x10;
    s.r[12] = 0x10;
    s.lr = 0x10;
    for ([_]u32{ 0xf859_5e04, 0xf85c_5e04, 0xf85e_5e04 }) |code| {
        s.r[5] = 0;
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(@as(u32, 0x1234_5678), s.r[5]);
    }
}

test "UMAAL adds both halves of the destination pair to the product and belongs to the DSP extension, A7.7.204" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[0] = 5;
    s.r[1] = 6;
    s.r[2] = 3;
    s.r[3] = 4;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbe20163));
    try std.testing.expectEqual(@as(u32, 23), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    s.r[0] = 0xffff_ffff;
    s.r[1] = 0xffff_ffff;
    s.r[2] = 0xffff_ffff;
    s.r[3] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfbe20163));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[1]);
}

test "SSAT16 and USAT16 saturate both halfwords and are undefined without the DSP extension, A7.7.153 A7.7.216" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[2] = 0x0020_ffe0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3220104));
    try std.testing.expectEqual(@as(u32, 0x000f_fff0), s.r[1]);
    try std.testing.expect(s.xpsr & State.flag_q != 0);
    s.xpsr = 0;
    s.r[2] = 0x0003_0004;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3220104));
    try std.testing.expectEqual(@as(u32, 0x0003_0004), s.r[1]);
    try std.testing.expect(s.xpsr & State.flag_q == 0);
    s.r[2] = 0xffff_0021;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3a20105));
    try std.testing.expectEqual(@as(u32, 0x0000_001f), s.r[1]);
    var plain = memory(.armv7m);
    try std.testing.expectEqual(.undefined, exec(&s, &plain, 0xf3220104));
    try std.testing.expectEqual(.undefined, exec(&s, &plain, 0xf3a20105));
    try std.testing.expectEqual(.next, exec(&s, &plain, 0xf32100c4));
}

test "every value of the wide hint space executes as a NOP, and only the Main Extension has it, C2.4.130 C2.4.493 C2.4.490 C2.4.491 C2.4.179 C2.4.44 C2.4.57" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 8 };
    var m = memory(.armv8_1m_main);
    for (0..256) |h| {
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_8000 | @as(u32, @intCast(h))));
        try std.testing.expectEqual(State{ .xpsr = State.flag_t, .pc = 8 }, s);
    }
    var base = memory(.armv6m);
    try std.testing.expectEqual(.undefined, exec(&s, &base, 0xf3af_8000));
}

test "a byte or halfword load naming the PC is PLD, PLDW, PLI or a reserved hint, and none of them reads, so an address the host does not hold cannot fault them, C2.3.7.1 C2.3.7.13 C2.3.7.14 C2.4.139 C2.4.140 C2.4.141 C2.4.142 C2.4.143" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 8, .r = @splat(0x1000) };
    var m = memory(.armv7em);
    const expected = s;
    for ([_]u32{
        0xf890_f004, 0xf810_fc04, 0xf810_f021, 0xf81f_f008,
        0xf990_f004, 0xf910_fc04, 0xf910_f021, 0xf91f_f008,
        0xf8b0_f004, 0xf830_fc04, 0xf830_f021, 0xf83f_f008,
        0xf9b0_f004, 0xf930_fc04, 0xf930_f021, 0xf93f_f008,
    }) |code| {
        try std.testing.expectEqual(.next, exec(&s, &m, code));
        try std.testing.expectEqual(expected, s);
    }
    try std.testing.expectEqual(.data_fault, exec(&s, &m, 0xf890_0004));
}

test "MSR and MRS reach the eight pointer authentication keys, privileged only, and a core without the extension leaves them alone, B6.1.1 D1.2.189 D1.2.190" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv8_1m_main);
    for (0..8) |i| {
        s.r[0] = 0x1000 + @as(u32, @intCast(i));
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8020 | @as(u32, @intCast(i))));
        try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8120 | @as(u32, @intCast(i))));
        try std.testing.expectEqual(s.r[0], s.r[1]);
    }
    try std.testing.expectEqual([8]u32{ 0x1000, 0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007 }, s.pac_key);
    s.control = State.control_npriv;
    s.r[0] = 0xdead;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8020));
    try std.testing.expectEqual(@as(u32, 0x1000), s.pac_key[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8120));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
    s.control = 0;
    m.pacbti_extension = false;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8020));
    try std.testing.expectEqual(@as(u32, 0x1000), s.pac_key[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8120));
    try std.testing.expectEqual(@as(u32, 0), s.r[1]);
}

test "the four CONTROL gates of the extension are writable only with it and only privileged, and an unprivileged read sees the two unprivileged ones, B6.1.1 B6.1.2 D1.2.13" {
    const gates = State.control_bti_en | State.control_ubti_en | State.control_pac_en | State.control_upac_en;
    var s: State = .{ .xpsr = State.flag_t, .r = @splat(gates) };
    var m = memory(.armv8_1m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(gates, s.control);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8114));
    try std.testing.expectEqual(gates, s.r[1]);
    s.control |= State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3ef_8114));
    try std.testing.expectEqual(State.control_npriv | State.control_ubti_en | State.control_upac_en, s.r[1]);
    s.control = 0;
    m.pacbti_extension = false;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(@as(u32, 0), s.control);
}

test "the key of an authentication is the one of the running privilege level, B6.1.1" {
    var s: State = .{ .pac_key = .{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    try std.testing.expectEqual([4]u32{ 1, 2, 3, 4 }, s.pacKey().*);
    s.control = State.control_npriv;
    try std.testing.expectEqual([4]u32{ 5, 6, 7, 8 }, s.pacKey().*);
    s.xpsr = 3;
    try std.testing.expectEqual([4]u32{ 1, 2, 3, 4 }, s.pacKey().*);
}

const keyed: [8]u32 = .{ 0x0123_4567, 0x89ab_cdef, 0xfedc_ba98, 0x7654_3210, 1, 2, 3, 4 };

test "PAC signs the link register against the stack pointer into R12, and AUT accepts that code and nothing else, C2.4.135 C2.4.17" {
    var s: State = .{ .xpsr = State.flag_t, .lr = 0x0800_1235, .msp = 0x2000_0100, .control = State.control_pac_en, .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_801d));
    try std.testing.expect(s.r[12] != 0);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_802d));
    for ([_]*u32{ &s.lr, &s.msp, &s.r[12], &s.pac_key[0] }) |field| {
        field.* ^= 4;
        try std.testing.expectEqual(.authentication_failure, exec(&s, &m, 0xf3af_802d));
        field.* ^= 4;
    }
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_802d));
}

test "a code signed at one privilege level does not authenticate at the other, because the key differs, B6.1.1" {
    var s: State = .{ .xpsr = State.flag_t, .lr = 0x0800_1235, .msp = 0x2000_0100, .control = State.control_pac_en | State.control_upac_en, .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_801d));
    s.control |= State.control_npriv;
    try std.testing.expectEqual(.authentication_failure, exec(&s, &m, 0xf3af_802d));
}

test "signing writes nothing and authenticating raises nothing where the gate is clear or the core has no extension, B6.1.1" {
    var s: State = .{ .xpsr = State.flag_t, .lr = 0x0800_1235, .msp = 0x2000_0100, .r = @splat(0), .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_801d));
    try std.testing.expectEqual(@as(u32, 0), s.r[12]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_802d));
    s.control = State.control_pac_en;
    m.pacbti_extension = false;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_801d));
    try std.testing.expectEqual(@as(u32, 0), s.r[12]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf3af_802d));
}

test "PACG signs a general pointer, AUTG checks it, and BXAUT branches to the address it authenticated, C2.4.137 C2.4.18 C2.4.30" {
    var s: State = .{ .xpsr = State.flag_t, .pc = 0x100, .control = State.control_pac_en, .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    s.r[1] = 0x0800_1235;
    s.r[2] = 0x2000_0100;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb61_f002));
    try std.testing.expect(s.r[0] != 0);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb51_0f02));
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xfb51_0f12));
    try std.testing.expectEqual(@as(u32, 0x0800_1234), s.pc);
    s.r[2] ^= 8;
    try std.testing.expectEqual(.authentication_failure, exec(&s, &m, 0xfb51_0f02));
    try std.testing.expectEqual(.authentication_failure, exec(&s, &m, 0xfb51_0f12));
}

test "the same encodings stay SMMLA and SMMLS on a core without the extension, C2.3.9" {
    var s: State = .{ .xpsr = State.flag_t, .control = State.control_pac_en, .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    s.r[1] = 0x4000_0000;
    s.r[2] = 0x4000_0000;
    s.r[3] = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb51_3002));
    try std.testing.expectEqual(@as(u32, 0x1000_0007), s.r[0]);
    m.pacbti_extension = false;
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb61_f002));
    try std.testing.expectEqual(@as(u32, 0xf000_0000), s.r[0]);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb51_0f02));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), s.pc);
}

test "an accumulate register of PC keeps SMMUL, which the manual gives priority over AUTG and BXAUT, C2.4.18 C2.4.30" {
    var s: State = .{ .xpsr = State.flag_t, .control = State.control_pac_en, .pac_key = keyed };
    var m = memory(.armv8_1m_main);
    s.r[1] = 0x4000_0000;
    s.r[2] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb51_f302));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), s.r[3]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xfb51_ff02));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), s.pc);
}

test "MSR CONTROL writes SFPA on a Secure core, and unprivileged Secure code may set it, C2.4.126" {
    var s: State = .{ .xpsr = State.flag_t, .secure = true };
    var m = memory(.armv8m_main);
    s.r[0] = State.control_fpca | State.control_sfpa;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(State.control_fpca | State.control_sfpa, s.control);
    s.r[0] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(@as(u32, 0), s.control);
    s.secure = false;
    s.r[0] = State.control_sfpa;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(@as(u32, 0), s.control);
    s.secure = true;
    s.control = State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(State.control_npriv | State.control_sfpa, s.control);
}

test "MSR CONTROL sets FPCA on an ARMv7E-M core with a floating-point unit and no Security Extension, B1.4.4" {
    var s: State = .{ .xpsr = State.flag_t };
    var m = memory(.armv7em);
    s.r[0] = State.control_fpca | State.control_sfpa;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(State.control_fpca, s.control);
}

test "a core with no floating-point or vector unit leaves CONTROL.FPCA and SFPA reserved, C2.4.126" {
    var s: State = .{ .xpsr = State.flag_t, .secure = true };
    var m = memory(.armv8m_main);
    m.fp_extension = false;
    s.r[0] = State.control_fpca | State.control_sfpa | State.control_npriv;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xf380_8814));
    try std.testing.expectEqual(State.control_npriv, s.control);
}

test "a loop end without tail predication is a fault while a tail-predicated loop is running, C2.4.103" {
    var s: State = .{ .pc = 0x10, .lr = 4, .control = State.control_fpca, .fpscr = 2 << 16 };
    var m = memory(.armv8_1m_main);
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xf00f_c803));
    try std.testing.expect(m.invalid);
    m.invalid = false;
    try std.testing.expectEqual(.undefined, exec(&s, &m, 0xf02f_c803));
    try std.testing.expect(m.invalid);
    m.invalid = false;
    s.control = 0;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf00f_c803));
    s.control = State.control_fpca;
    s.fpscr = fp.ltpsize;
    try std.testing.expectEqual(.branched, exec(&s, &m, 0xf00f_c803));
    try std.testing.expect(!m.invalid);
}

test "the long shifts move a 64-bit value held in an even and an odd register, and take their amount from the immediate or the bottom byte of Rm, C2.4.13 C2.4.14 C2.4.115" {
    var s: State = .{};
    var m = memory(.armv8_1m_main);
    s.r[4] = 0x89ab_cdef;
    s.r[5] = 0x0000_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea54_152f));
    try std.testing.expectEqual(@as(u32, 0x189a_bcde), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0), s.r[5]);
    s.r[4] = 0x89ab_cdef;
    s.r[5] = 0x0000_0001;
    s.r[6] = 0xffff_ff00 | 4;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea54_652d));
    try std.testing.expectEqual(@as(u32, 0x189a_bcde), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0), s.r[5]);
    s.r[8] = 0x8000_0000;
    s.r[9] = 0xffff_ffff;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea58_09cf));
    try std.testing.expectEqual(@as(u32, 0), s.r[8]);
    try std.testing.expectEqual(@as(u32, 0xffff_fffc), s.r[9]);
}

test "a negative shift amount in Rm reverses the direction of a long shift, C2.4.14 C2.4.116" {
    var s: State = .{};
    var m = memory(.armv8_1m_main);
    s.r[4] = 0x0000_0001;
    s.r[5] = 0x0000_0000;
    s.r[6] = 0xffff_fffc;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea54_652d));
    try std.testing.expectEqual(@as(u32, 0x10), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0), s.r[5]);
}

test "the saturating long shifts clamp to the width the encoding names and raise the Q flag, C2.4.203 C2.4.204 C2.4.277" {
    var s: State = .{};
    var m = memory(.armv8_1m_main);
    s.r[4] = 0;
    s.r[5] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea55_053f));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[5]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
    s.xpsr = 0;
    s.r[4] = 0xffff_ffff;
    s.r[5] = 0x0000_7fff;
    s.r[6] = 0;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea55_652d));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0x0000_7fff), s.r[5]);
    try std.testing.expectEqual(@as(u32, 0), s.xpsr & State.flag_q);
    s.r[5] = 0x0000_8000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea55_65ad));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), s.r[4]);
    try std.testing.expectEqual(@as(u32, 0x0000_7fff), s.r[5]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
}

test "the single-register shifts round and saturate one register, which the RdaHi field of 111 names, C2.4.200 C2.4.207 C2.4.276" {
    var s: State = .{};
    var m = memory(.armv8_1m_main);
    s.r[4] = 0x0000_0003;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea54_0f6f));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), s.r[4]);
    s.r[4] = 0x4000_0000;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea54_0fff));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), s.r[4]);
    try std.testing.expectEqual(State.flag_q, s.xpsr & State.flag_q);
}

test "ORR keeps the shifted-register encodings that ORRS gives up to the long shifts, C2.3.3.1" {
    var s: State = .{};
    var m = memory(.armv7em);
    s.r[0] = 0x0000_0001;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea40_010e));
    try std.testing.expectEqual(@as(u32, 1), s.r[1]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea50_010e));
    try std.testing.expectEqual(@as(u32, 1), s.r[1]);
}

test "a conditional select reads its second source as zero when the field names r15, and reaches r12 through the split, C2.4.45" {
    var s: State = .{};
    var m = memory(.armv8_1m_main);
    s.r[0] = 7;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea50_800f));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    s.r[12] = 3;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xea5f_800c));
    try std.testing.expectEqual(@as(u32, 3), s.r[0]);
}

test "the acquire and release forms of the exclusive accesses take the monitor and answer the same status word as LDREX and STREX, C2.4.66 C2.4.223" {
    var s: State = .{};
    var m = memory(.armv8m_main);
    m.bytes[8] = 0x44;
    m.bytes[9] = 0x33;
    m.bytes[10] = 0x22;
    m.bytes[11] = 0x11;
    s.r[1] = 8;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_0fef));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), s.r[0]);
    try std.testing.expectEqual(@as(?u32, 8), s.exclusive);
    s.r[2] = 0x1122_3345;
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_2fe0));
    try std.testing.expectEqual(@as(u32, 0), s.r[0]);
    try std.testing.expectEqual(@as(u32, 0x1122_3345), m.peek(u32, 8).?);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_2fe0));
    try std.testing.expectEqual(@as(u32, 1), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_0fcf));
    try std.testing.expectEqual(@as(u32, 0x45), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8d1_0fdf));
    try std.testing.expectEqual(@as(u32, 0x3345), s.r[0]);
    try std.testing.expectEqual(.next, exec(&s, &m, 0xe8c1_2fd0));
    try std.testing.expectEqual(@as(u32, 0x1122_3345), m.peek(u32, 8).?);
}
