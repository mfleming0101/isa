//! The fetch-decode-execute loop for one RV32 instruction over a generic host, and the packed
//! `Result` it answers with. It fetches the first parcel, tests the escape bits, runs the generated
//! decode tree for the narrow or wide code, then charges the row's class. A code no leaf claims is
//! an illegal instruction. `Stop` names why the core halted and `Trap` the synchronous exception
//! the processor turns into an mcause. `call` runs a code already in hand, which is what a row's
//! own test drives.
const std = @import("std");
const builtin = @import("builtin");
const State = @import("state.zig").State;
const instruction = @import("instruction.zig");
const decode = @import("decode.zig");
const access = @import("access.zig");
const tree = @import("riscv_decode");
const charge = @import("../../cost.zig").charge;

comptime {
    const wanted = [_]decode.Group{ .rv32i, .m, .a, .c, .zicsr, .f };
    for (wanted, 0..) |g, i| {
        if (@intFromEnum(g) != i) @compileError("the generated tree's group order is not decode.Group's");
    }
}

/// Why the core halted: EBREAK, an unwritten row, or a trap on the mtvec base itself.
pub const Stop = enum(u4) { breakpoint, unimplemented, unrecoverable_trap };

/// The synchronous exceptions a row raises, named for what happened rather than the code.
pub const Trap = enum(u4) { none, instruction_access_fault, illegal_instruction, load_access_fault, store_access_fault, environment_call };

/// Whether the loop's stages are force-inlined, which every target but wasm32 gets.
pub const threaded = builtin.cpu.arch != .wasm32;
/// The call modifier the loop's stages use: always_inline where threaded.
pub const inlining: std.builtin.CallModifier = if (threaded) .always_inline else .auto;

/// One step's outcome in a 64-bit word: code, class, cycles, branch, stop or trap.
pub const Result = packed struct(u64) {
    code: u32 = 0,
    fetched: bool = false,
    class: instruction.Class = .data_processing,
    executed: bool = false,
    cycles: u8 = 0,
    branched: bool = false,
    stop: Stop = .breakpoint,
    halted: bool = false,
    trap: Trap = .none,
    _: u8 = 0,

    /// A result for an instruction that executed, with its cycles and whether it branched.
    pub fn retired(code: u32, class: instruction.Class, cycles: u8, branched: bool) Result {
        return .{ .code = code, .fetched = true, .class = class, .executed = true, .cycles = cycles, .branched = branched };
    }

    /// A result for a core that halted, carrying the code if one was fetched.
    pub fn stopped(code: ?u32, stop: Stop) Result {
        return .{ .code = code orelse 0, .fetched = code != null, .stop = stop, .halted = true };
    }

    /// A result that leaves the loop for a trap, carrying the exception rather than a stop.
    pub fn trapped(code: ?u32, trap: Trap) Result {
        return .{ .code = code orelse 0, .fetched = code != null, .halted = true, .trap = trap };
    }

    /// The code fetched, or null where the fetch itself faulted.
    pub fn fetchedCode(self: Result) ?u32 {
        return if (self.fetched) self.code else null;
    }

    /// The stop reason where the core halted without a trap, else null.
    pub fn halt(self: Result) ?Stop {
        return if (self.halted and self.trap == .none) self.stop else null;
    }
};

/// What a core hands the loop: the groups it decodes and its per-class costs.
pub const Model = struct {
    decoding: decode.Groups,
    costs: Costs,

    /// One cost per cycle class.
    pub const Costs = [instruction.costs_len]instruction.Cost;

    /// The cost of a cycle class.
    pub fn costOf(self: Model, class: instruction.Class) instruction.Cost {
        return self.costs[@intFromEnum(class)];
    }
};

/// Fetches, decodes, executes and charges one instruction at the program counter. A comptime
/// group set replaces the Model's and prunes the tree to it; null decodes with the Model's set.
pub fn step(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model) Result {
    return @call(inlining, body, .{ Host, groups, s, host, model });
}

fn body(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model) Result {
    const address = s.pc;
    var held: access.Span(Host) = &.{};
    const first = access.fetch(Host, host, address, &held) orelse return Result.trapped(null, .instruction_access_fault);
    if (decode.escapes(first)) return @call(inlining, wide, .{ Host, groups, s, host, model, address, first, &held });
    const done = @call(inlining, tree.executeNarrow, .{ Host, s, host, first, groups orelse model.decoding });
    switch (done.class) {
        inline else => |c| return @call(inlining, retire, .{ s, model.costOf(c), address, 2, first, c, done.outcome }),
    }
}

fn wide(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model, address: u32, first: u16, held: *access.Span(Host)) Result {
    const upper = access.parcel(Host, host, held, address +% 2) orelse return Result.trapped(null, .instruction_access_fault);
    const code = @as(u32, upper) << 16 | first;
    const done = @call(inlining, tree.executeWide, .{ Host, s, host, code, groups orelse model.decoding });
    switch (done.class) {
        inline else => |c| return @call(inlining, retire, .{ s, model.costOf(c), address, 4, code, c, done.outcome }),
    }
}

/// Runs a code in hand through the tree under a group set; illegal where no leaf claims it. The
/// escape bits of the first parcel say which width the code is, as they do for the disassembler.
pub fn call(comptime Host: type, s: *State, host: *Host, code: u32, groups: decode.Groups) instruction.Outcome {
    const done = if (decode.escapes(code))
        tree.executeWide(Host, s, host, code, groups)
    else
        tree.executeNarrow(Host, s, host, code, groups);
    return done.outcome;
}

fn retire(s: *State, cost: instruction.Cost, address: u32, length: u32, code: u32, class: instruction.Class, outcome: instruction.Outcome) Result {
    switch (outcome) {
        .next => {
            s.pc = address +% length;
            return Result.retired(code, class, cost.cycles, false);
        },
        .branched => return Result.retired(code, class, charge(cost.cycles, cost.taken), true),
        .breakpoint => return Result.stopped(code, .breakpoint),
        .unimplemented => return Result.stopped(code, .unimplemented),
        .environment_call => return Result.trapped(code, .environment_call),
        .illegal => return Result.trapped(code, .illegal_instruction),
        .data_fault, .unaligned => return Result.trapped(code, if (class == .load or class == .load_reserved) .load_access_fault else .store_access_fault),
    }
}
