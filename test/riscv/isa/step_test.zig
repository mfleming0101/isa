//! Tests of the step loop over a stub memory with a per-class cost table: program counter advance,
//! cycle charging, fetch and decode faults, EBREAK stops, ECALL traps, load and store fault codes,
//! and the size of `Result`.
const std = @import("std");
const State = @import("../../../src/riscv/isa/state.zig").State;
const instruction = @import("../../../src/riscv/isa/instruction.zig");
const Class = instruction.Class;
const decode = @import("../../../src/riscv/isa/decode.zig");
const csr = @import("../../../src/riscv/isa/csr.zig");
const step = @import("../../../src/riscv/isa/step.zig");

const costs: step.Model.Costs = blk: {
    var out: step.Model.Costs = @splat(.{ .cycles = 1, .taken = 0 });
    out[@intFromEnum(Class.load)] = .{ .cycles = 2, .taken = 0 };
    out[@intFromEnum(Class.branch)] = .{ .cycles = 1, .taken = 3 };
    break :blk out;
};

const Mem = struct {
    /// Every group, so each row decodes.
    pub const allowed = decode.every;
    const Self = @This();

    bytes: [32]u8 = @splat(0),

    fn slice(self: *Self, address: u32, comptime n: usize) ?*[n]u8 {
        if (@as(u64, address) + n > self.bytes.len) return null;
        return self.bytes[address..][0..n];
    }

    fn place(self: *Self, address: u32, words: []const u32) void {
        for (words, 0..) |word, i| _ = self.poke(u32, address + @as(u32, @intCast(i)) * 4, word);
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

const Rom = struct {
    const Self = @This();

    comptime {
        @import("../../../src/contract.zig").assertHost(Self, &@import("../../../src/contract.zig").riscv_requirements);
    }

    image: *const [8]u8,
    wrote: ?u32 = null,

    /// The bytes of the read-only image from an address, which no row may write in place.
    pub fn span(self: *Self, address: u32, comptime a: anytype) []const u8 {
        if (@as(u64, address) + a.bytes > self.image.len) return &.{};
        return self.image[address..];
    }

    /// Takes the write the span could not serve and refuses everything else.
    pub fn access(self: *Self, _: u32, comptime a: anytype, value: u32) error{DataFault}!u32 {
        if (a.kind != .write) return error.DataFault;
        self.wrote = value;
        return 0;
    }

    /// Host requirement: a touched address is ignored here.
    pub fn touch(_: *Self, _: u32) void {}

    /// A PMP register reads as an unwritten entry.
    pub fn readPmp(_: *Self, _: csr.Protection) u32 {
        return 0;
    }

    /// A PMP write goes nowhere.
    pub fn writePmp(_: *Self, _: csr.Protection, _: u32) void {}

    /// Host requirement: nothing to re-arm here.
    pub fn rearm(_: *Self) void {}

    /// Host requirement: a privilege change is touched by nobody.
    pub fn returned(_: *Self) void {}

    /// Host requirement: a WFI has nothing to wait for.
    pub fn sleep(_: *Self) void {}
};

test "a host whose span answers a read-only image is fetched from in place and written through access" {
    const image = [_]u8{ 0x23, 0x20, 0xb5, 0x00, 0, 0, 0, 0 };
    var s: State = .{};
    s.x[11] = 0x1234;
    var rom: Rom = .{ .image = &image };
    const r = step.step(Rom, null, &s, &rom, .{ .decoding = decode.every, .costs = costs });
    try std.testing.expectEqual(@as(?step.Stop, null), r.halt());
    try std.testing.expectEqual(@as(u32, 4), s.pc);
    try std.testing.expectEqual(@as(?u32, 0x1234), rom.wrote);
}

fn run(s: *State, m: *Mem) step.Result {
    return step.step(Mem, null, s, m, .{ .decoding = decode.every, .costs = costs });
}

test "a retired instruction leaves the program counter on the next word and charges the class of its row, section 1.5" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{0x0025_0593});
    const r = run(&s, &m);
    try std.testing.expectEqual(@as(?u32, 0x0025_0593), r.fetchedCode());
    try std.testing.expectEqual(@as(?step.Stop, null), r.halt());
    try std.testing.expectEqual(Class.data_processing, r.class);
    try std.testing.expectEqual(@as(u8, 1), r.cycles);
    try std.testing.expect(!r.branched);
    try std.testing.expectEqual(@as(u32, 4), s.pc);
}

test "a load costs the cycle its data phase takes and a taken branch costs the refill of the pipeline" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{ 0x0000_2503, 0x00a5_0463 });
    try std.testing.expectEqual(@as(u8, 2), run(&s, &m).cycles);
    const branch = run(&s, &m);
    try std.testing.expect(branch.branched);
    try std.testing.expectEqual(@as(u8, 4), branch.cycles);
    try std.testing.expectEqual(@as(u32, 12), s.pc);
}

test "a fetch no memory answers raises an instruction access fault and reports no code, Privileged 3.1.15" {
    var s: State = .{ .pc = 0x1000 };
    var m: Mem = .{};
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Trap.instruction_access_fault, r.trap);
    try std.testing.expectEqual(@as(?u32, null), r.fetchedCode());
    try std.testing.expectEqual(@as(u32, 0x1000), s.pc);
}

test "a code no row matches raises an illegal instruction and reports the code it fetched, Privileged 3.1.15" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{0x04c5_8533});
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Trap.illegal_instruction, r.trap);
    try std.testing.expectEqual(@as(?u32, 0x04c5_8533), r.fetchedCode());
}

test "EBREAK stops the core on the instruction itself, so the address it stopped at is the EBREAK, section 2.8" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{0x0010_0073});
    const r = run(&s, &m);
    try std.testing.expectEqual(@as(?step.Stop, .breakpoint), r.halt());
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "ECALL raises an environment call, which the processor takes as a trap rather than a stop, section 2.8" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{0x0000_0073});
    const r = run(&s, &m);
    try std.testing.expectEqual(step.Trap.environment_call, r.trap);
    try std.testing.expectEqual(@as(?step.Stop, null), r.halt());
    try std.testing.expectEqual(@as(u32, 0), s.pc);
}

test "a misaligned load on a hart that refuses one and a load no memory answers both raise the load access fault, Privileged 3.1.15" {
    var s: State = .{};
    s.csr.implementation.misaligned = .refused;
    var m: Mem = .{};
    m.place(0, &.{ 0x0020_2503, 0x0405_2503 });
    s.x[10] = 0;
    try std.testing.expectEqual(step.Trap.load_access_fault, run(&s, &m).trap);
    s.pc = 4;
    try std.testing.expectEqual(step.Trap.load_access_fault, run(&s, &m).trap);
}

test "a store no memory answers raises the store access fault where a load raises the load one, section 3.1.15" {
    var s: State = .{};
    var m: Mem = .{};
    m.place(0, &.{ 0x00a5_2023, 0x0005_2503 });
    s.x[10] = 0x1000;
    try std.testing.expectEqual(step.Trap.store_access_fault, run(&s, &m).trap);
    s.pc = 4;
    try std.testing.expectEqual(step.Trap.load_access_fault, run(&s, &m).trap);
}

test "the whole result of a step is one 64-bit word" {
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(step.Result));
    const retired = step.Result.retired(0x1234, .jump, 7, true);
    try std.testing.expectEqual(@as(?u32, 0x1234), retired.fetchedCode());
    try std.testing.expectEqual(@as(?step.Stop, null), retired.halt());
    try std.testing.expectEqual(@as(?step.Stop, .unimplemented), step.Result.stopped(1, .unimplemented).halt());
    try std.testing.expectEqual(@as(?u32, null), step.Result.trapped(null, .instruction_access_fault).fetchedCode());
    try std.testing.expectEqual(@as(?step.Stop, null), step.Result.trapped(1, .illegal_instruction).halt());
}
