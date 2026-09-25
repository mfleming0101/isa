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

/// What one step produced: the code, class, cycles, branch and any halt.
pub const Result = packed struct(u64) {
    code: u32 = 0,
    fetched: bool = false,
    class: instruction.Class = .data_processing,
    executed: bool = false,
    cycles: u8 = 0,
    branched: bool = false,
    stop: Stop = .breakpoint,
    halted: bool = false,
    _: u11 = 0,

    /// Result of an executed instruction with its class, cycles and branch.
    pub fn retired(code: u32, class: instruction.Class, cycles: u8, branched: bool) Result {
        return .{ .code = code, .fetched = true, .class = class, .executed = true, .cycles = cycles, .branched = branched };
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

/// The decode selection and per-class costs one core runs with.
pub const Model = struct {
    decoding: decode.Selection,
    costs: Costs,

    /// Cost table indexed by instruction class.
    pub const Costs = [instruction.costs_len]instruction.Cost;

    /// Cost of an instruction class.
    pub fn costOf(self: Model, class: instruction.Class) instruction.Cost {
        return self.costs[@intFromEnum(class)];
    }
};

/// Executes one instruction at PC on the host and reports the result. A comptime group set
/// replaces the Model's and prunes the tree to it; null decodes with the Model's set.
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
    if (s.xpsr & State.it_mask == 0) return body(Host, groups, s, host, model, false);
    const result = body(Host, groups, s, host, model, true);
    if (!result.halted) s.itAdvance();
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

fn body(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model, comptime in_it: bool) Result {
    @setEvalBranchQuota(4000);
    const address = s.pc;
    var held: access.Span(Host) = &.{};
    const hw1 = access.fetch(Host, host, address, &held) catch |err| return Result.stopped(null, refused(err));
    if (escapes(hw1)) return @call(.always_inline, wide, .{ Host, groups, s, host, model, address, hw1, &held, in_it });
    if (in_it and !s.itPasses()) return skip(model.costOf(.data_processing), s, address, 2, hw1);
    const done = @call(.always_inline, tree.executeNarrow, .{ Host, s, host, hw1, groups orelse model.decoding.groups });
    switch (done.class) {
        inline else => |c| return @call(.always_inline, retire, .{ Host, s, host, model.costOf(c), address, 2, hw1, c, done.outcome }),
    }
}

fn wide(comptime Host: type, comptime groups: ?decode.Groups, s: *State, host: *Host, model: Model, address: u32, hw1: u16, held: *access.Span(Host), comptime in_it: bool) Result {
    const hw2 = access.halfword(Host, host, held, address +% 2) catch |err| return Result.stopped(null, refused(err));
    const code = @as(u32, hw1) << 16 | hw2;
    if (in_it and !s.itPasses()) return skip(model.costOf(.data_processing), s, address, 4, code);
    const done = @call(.always_inline, tree.executeWide, .{ Host, s, host, code, groups orelse model.decoding.groups });
    if (done.outcome == .undefined and absent(Host, host, code)) return Result.stopped(code, .no_coprocessor);
    switch (done.class) {
        inline else => |c| return @call(.always_inline, retire, .{ Host, s, host, model.costOf(c), address, 4, code, c, done.outcome }),
    }
}

fn skip(cost: instruction.Cost, s: *State, address: u32, length: u32, code: u32) Result {
    if (length == 2 and code & 0xff00 == 0xbe00) return Result.stopped(code, .breakpoint);
    s.pc = address +% length;
    return Result.retired(code, .data_processing, cost.cycles, false);
}

/// Executes one instruction from a code in hand under a group set, as a row test does; a code
/// above a halfword is a 32-bit encoding, since every wide T32 code opens with hw1 at or above
/// 0xe800.
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

fn retire(comptime Host: type, s: *State, host: *Host, cost: instruction.Cost, address: u32, length: u32, code: u32, class: instruction.Class, outcome: instruction.Outcome) Result {
    const cycles = charge(cost.cycles, instruction.words(class, code));
    switch (outcome) {
        .next => {
            s.pc = address +% length;
            return Result.retired(code, class, cycles, false);
        },
        .branched => return Result.retired(code, class, charge(cycles, cost.taken), true),
        .supervisor_call => {
            s.pc = address +% length;
            host.signal(.supervisor_call);
            return Result.retired(code, class, cycles, false);
        },
        .exception_return => {
            host.signal(.exception_return);
            return Result.retired(code, class, charge(cycles, cost.taken), true);
        },
        .function_return => {
            host.signal(.function_return);
            return Result.retired(code, class, charge(cycles, cost.taken), true);
        },
        .breakpoint => return Result.stopped(code, .breakpoint),
        .unimplemented => return Result.stopped(code, .unimplemented),
        .data_fault => return Result.stopped(code, .data_fault),
        .unaligned => return Result.stopped(code, .unaligned_access),
        .violation => return Result.stopped(code, .data_violation),
        .secure => return Result.stopped(code, .secure_fault),
        .divide_by_zero => return Result.stopped(code, .divide_by_zero),
        .no_coprocessor => return Result.stopped(code, .no_coprocessor),
        .authentication_failure => return Result.stopped(code, .authentication_failure),
        .undefined => return Result.stopped(code, .undefined_instruction),
    }
}
