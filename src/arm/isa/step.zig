//! The instruction step loop of the Arm core. Fetches a halfword, widens to 32 bits
//! when the prefix says so, applies IT and BTI conditioning, executes through the
//! generated decode tree, prices the instruction and reports the result or why the core
//! stopped. Also exposes the single-instruction entry a row test drives.
const std = @import("std");
const State = @import("state.zig").State;
const instruction = @import("instruction.zig");
const decode = @import("decode.zig");
const access = @import("access.zig");
const t32_wide = @import("t32_wide.zig");
const tree = @import("arm_decode");
const meta = @import("arm_meta");
const charge = @import("../../cost.zig").charge;

comptime {
    const wanted = [_]decode.Group{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main, .v8_1m, .mve };
    for (wanted, 0..) |g, i| {
        if (@intFromEnum(g) != i) @compileError("the generated tree's group order is not decode.Group's");
    }
}

/// Reason the core halted instead of retiring an instruction.
pub const Stop = enum(u5) { breakpoint, undefined_instruction, unimplemented, not_t32_state, fetch_fault, data_fault, unaligned_access, divide_by_zero, no_coprocessor, authentication_failure, not_branch_target, exception_return, unrecoverable_exception, secure_fault, fetch_violation, data_violation, tail_predication };

/// Signals a retired instruction raises to the system side.
pub const Signal = enum { supervisor_call, exception_return, function_return };

/// What a halted core waits for: WFE waits for an event, WFI for an interrupt, B1.5.18 and B1.5.19.
pub const Wait = enum { event, interrupt };

/// What one step produced: the code, meta entry, cycles, branch and any halt.
pub const Result = packed struct(u64) {
    code: u32 = 0,
    fetched: bool = false,
    executed: bool = false,
    cycles: u8 = 0,
    branched: bool = false,
    stop: Stop = .breakpoint,
    halted: bool = false,
    /// The code's meta entry, an alias's where its field matches; valid where executed.
    row: u11 = 0,
    /// Passed over by a failing IT condition, so priced and classed as data processing.
    skipped: bool = false,
    _: u3 = 0,

    /// Result of an executed instruction with its meta entry, cycles and branch.
    pub fn retired(code: u32, row: u11, cycles: u8, branched: bool) Result {
        return .{ .code = code, .fetched = true, .executed = true, .cycles = cycles, .branched = branched, .row = row };
    }

    /// The class of an executed instruction.
    pub fn class(self: Result) instruction.Class {
        return if (self.skipped) .data_processing else meta.entries[self.row].class;
    }

    /// Result of a halt, with the fetched code if any.
    pub fn stopped(code: ?u32, stop: Stop) Result {
        return .{ .code = code orelse 0, .fetched = code != null, .stop = stop, .halted = true };
    }

    /// The instruction code if one was fetched.
    pub fn fetchedCode(self: Result) ?u32 {
        return if (self.fetched) self.code else null;
    }

    /// The stop reason if the core halted.
    pub fn halt(self: Result) ?Stop {
        return if (self.halted) self.stop else null;
    }
};

/// The decode selection, per-class costs and timing rules one core runs with.
pub const Model = struct {
    decoding: decode.Selection,
    costs: Costs,
    rules: Rules = .{},

    /// Timing measured on a board that a per-class cost cannot hold.
    pub const Rules = struct {
        /// UDIV and SDIV cost by their operands under this divider, instruction.divideCycles.
        divide: ?instruction.Divide = null,
        /// A taken B or B<c> to a 32-bit instruction straddling a word costs one more; kernels b_w2, beq_w2, b_nw2.
        straddle: bool = false,
    };

    /// Cost table indexed by instruction class.
    pub const Costs = [instruction.costs_len]instruction.Cost;

    /// Cost of an instruction class.
    pub fn costOf(self: Model, class: instruction.Class) instruction.Cost {
        return self.costs[@intFromEnum(class)];
    }
};

/// Executes one instruction at PC. A comptime group set replaces the Model's and prunes the tree;
/// null uses the Model's.
pub fn step(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model) Result {
    if (s.xpsr & model.decoding.xpsr_mask != State.flag_t) {
        @branchHint(.unlikely);
        if (s.xpsr & State.flag_t == 0) return Result.stopped(null, .not_t32_state);
        return @call(.never_inline, conditioned, .{ Host, groups, s, host, model });
    }
    return @call(.always_inline, body, .{ Host, groups, s, host, model, false });
}

fn conditioned(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model) Result {
    if (s.xpsr & State.flag_b != 0) {
        var held: access.Span(Host) = &.{};
        const hw1 = access.fetch(Host, host, s.pc, &held) catch |err| return Result.stopped(null, refused(err));
        if (!t32_wide.lands(Host, host, &held, s.pc, hw1)) return Result.stopped(hw1, .not_branch_target);
    }
    const in_it = s.xpsr & State.it_mask != 0;
    const result = body(Host, groups, s, host, model, in_it);
    if (in_it and !result.halted) s.itAdvance();
    return result;
}

fn absent(comptime Host: type, host: *Host, code: u32) bool {
    if (!host.architecture().main()) return false;
    if (code & 0xec00_0000 != 0xec00_0000) return false;
    return code >> 8 & 0xe != 0xa or !host.coprocessorEnabled();
}

fn escapes(hw1: u16) bool {
    return hw1 >> 11 >= 0x1d;
}

fn body(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model, in_it: bool) Result {
    @setEvalBranchQuota(4000);
    const address = s.pc;
    var held: access.Span(Host) = &.{};
    const hw1 = access.fetch(Host, host, address, &held) catch |err| return Result.stopped(null, refused(err));
    if (escapes(hw1)) return @call(.always_inline, wide, .{ Host, groups, s, host, model, address, hw1, &held, in_it });
    if (in_it and !s.itPasses()) return skip(model.costOf(.data_processing), s, address, 2, hw1, meta.entryOf(tree.indexNarrow(hw1, groups orelse model.decoding.groups), hw1));
    const done = @call(.always_inline, tree.executeNarrow, .{ Host, s, host, hw1, groups orelse model.decoding.groups });
    switch (done.class) {
        inline else => |c| return @call(.always_inline, retire, .{ Host, s, host, model.costOf(c), address, 2, hw1, c, done.row, done.outcome, model.rules.straddle }),
    }
}

fn wide(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model, address: u32, hw1: u16, held: *access.Span(Host), in_it: bool) Result {
    const hw2 = access.halfword(Host, host, held, address +% 2) catch |err| return Result.stopped(null, refused(err));
    const code = @as(u32, hw1) << 16 | hw2;
    if (in_it and !s.itPasses()) return skip(model.costOf(.data_processing), s, address, 4, code, meta.entryOf(tree.indexWide(code, groups orelse model.decoding.groups), code));
    const dividing = model.rules.divide != null and hw1 & 0xffd0 == 0xfb90;
    const dividend = if (dividing) s.get(@truncate(hw1)) else 0;
    const divisor = if (dividing) s.get(@truncate(hw2)) else 0;
    const done = @call(.always_inline, tree.executeWide, .{ Host, s, host, code, groups orelse model.decoding.groups });
    if (done.outcome == .undefined and absent(Host, host, code)) {
        @branchHint(.unlikely);
        return Result.stopped(code, .no_coprocessor);
    }
    switch (done.class) {
        inline else => |c| {
            const cost = if (c == .divide and dividing) instruction.Cost{ .cycles = instruction.divideCycles(dividend, divisor, hw1 & 0x20 == 0, model.rules.divide.?), .taken = 0, .per_register = 0 } else model.costOf(c);
            return @call(.always_inline, retire, .{ Host, s, host, cost, address, 4, code, c, done.row, done.outcome, model.rules.straddle });
        },
    }
}

fn skip(cost: instruction.Cost, s: *State, address: u32, length: u32, code: u32, row: u11) Result {
    if (length == 2 and code & 0xff00 == 0xbe00) return Result.stopped(code, .breakpoint);
    s.pc = address +% length;
    return .{ .code = code, .fetched = true, .executed = true, .cycles = cost.cycles, .row = row, .skipped = true };
}

/// Executes one instruction from a code in hand under a group set; a code above 0xffff is a 32-bit
/// encoding.
pub fn call(comptime Host: type, s: *State, host: *Host, code: u32, groups: decode.Groups) instruction.Outcome {
    const done = if (code > 0xffff) tree.executeWide(Host, s, host, code, groups) else tree.executeNarrow(Host, s, host, code, groups);
    return done.outcome;
}

fn refused(err: instruction.Failure) Stop {
    return switch (err) {
        error.Violation => .fetch_violation,
        error.Secure => .secure_fault,
        else => .fetch_fault,
    };
}

fn straddles(comptime Host: type, host: *Host, code: u32, target: u32) bool {
    if (target & 2 == 0 or !direct(code)) return false;
    var held: access.Span(Host) = &.{};
    return escapes(access.fetch(Host, host, target, &held) catch return false);
}

fn direct(code: u32) bool {
    if (code > 0xffff) return code & 0xf800_c000 == 0xf000_8000;
    return code >> 12 == 0xd or code >> 11 == 0x1c;
}

fn retire(comptime Host: type, s: *State, host: *Host, cost: instruction.Cost, address: u32, length: u32, code: u32, class: instruction.Class, row: u11, outcome: instruction.Outcome, straddle: bool) Result {
    const cycles = charge(cost.cycles, instruction.words(class, code) *| cost.per_register);
    switch (outcome) {
        .next => {
            s.pc = address +% length;
            return Result.retired(code, row, cycles, false);
        },
        .branched => return Result.retired(code, row, charge(charge(cycles, cost.taken), @intFromBool(straddle and straddles(Host, host, code, s.pc))), true),
        .supervisor_call => {
            s.pc = address +% length;
            host.signal(.supervisor_call);
            return Result.retired(code, row, cycles, false);
        },
        .exception_return => {
            host.signal(.exception_return);
            return Result.retired(code, row, charge(cycles, cost.taken), true);
        },
        .function_return => {
            host.signal(.function_return);
            return Result.retired(code, row, charge(cycles, cost.taken), true);
        },
        .breakpoint, .unimplemented, .data_fault, .unaligned, .violation, .secure, .divide_by_zero, .no_coprocessor, .authentication_failure, .undefined => {
            @branchHint(.cold);
            return Result.stopped(code, switch (outcome) {
                .breakpoint => .breakpoint,
                .unimplemented => .unimplemented,
                .data_fault => .data_fault,
                .unaligned => .unaligned_access,
                .violation => .data_violation,
                .secure => .secure_fault,
                .divide_by_zero => .divide_by_zero,
                .no_coprocessor => .no_coprocessor,
                .authentication_failure => .authentication_failure,
                else => .undefined_instruction,
            });
        },
    }
}
