//! RV32A handlers: LR.W, SC.W and the nine word-sized AMOs, unprivileged section 13. LR.W reads
//! first, so it reserves only an address the read allowed; SC.W reads and releases the reservation
//! before anything else, checks alignment before storing, and answers the model's fail code. Both
//! refuse a misaligned address, as section 13.2 requires, where an AMO follows the model instead.
//! An AMO reads, combines and writes back as one instruction, writing rd last. The aq and rl bits
//! are ignored, section 13.1. Bound by `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const access = root.access;

/// The nine operations an AMO combines the word it read with, section 13.4.
pub const Operation = enum { swap, add, xor, @"and", @"or", min, max, minu, maxu };

fn combine(comptime kind: Operation, old: u32, source: u32) u32 {
    const a: i32 = @bitCast(old);
    const b: i32 = @bitCast(source);
    return switch (kind) {
        .swap => source,
        .add => old +% source,
        .xor => old ^ source,
        .@"and" => old & source,
        .@"or" => old | source,
        .min => @bitCast(@min(a, b)),
        .max => @bitCast(@max(a, b)),
        .minu => @min(old, source),
        .maxu => @max(old, source),
    };
}

/// LR.W (RV32A): reads the word at rs1, which must be aligned, and reserves that address, section
/// 13.2.
pub fn lr(s: *State, host: anytype, q: u32, n: u32, d: u32) Outcome {
    _ = q;
    const at = s.x[n];
    const value = access.read(@TypeOf(host.*), host, .refused, at, 32, false) catch |err| return Outcome.faulted(err);
    s.reservation = at;
    root.write(s, d, value);
    return .next;
}

/// SC.W (RV32A): stores rs2 at rs1 only against a reservation there; rd gets zero or the fail code.
pub fn sc(s: *State, host: anytype, q: u32, m: u32, n: u32, d: u32) Outcome {
    _ = q;
    const at = s.x[n];
    const held = if (s.reservation) |lock| lock == at else false;
    s.reservation = null;
    access.check(@TypeOf(host.*), host, .refused, at, 32) catch |err| return Outcome.faulted(err);
    if (!held) {
        root.write(s, d, s.csr.implementation.sc_failure);
        return .next;
    }
    access.write(@TypeOf(host.*), host, .refused, at, 32, s.x[m]) catch |err| return Outcome.faulted(err);
    root.write(s, d, 0);
    return .next;
}

/// The AMO*.W rows (RV32A): read the word at rs1, combine with rs2, write back, rd gets the old
/// word.
pub fn Amo(comptime kind: Operation) type {
    return struct {
        /// Reads, combines and writes back the word at rs1, then writes the old word to rd last.
        pub fn call(s: *State, host: anytype, q: u32, m: u32, n: u32, d: u32) Outcome {
            _ = q;
            const Host = @TypeOf(host.*);
            const at = s.x[n];
            const old = access.read(Host, host, s.csr.implementation.misaligned, at, 32, false) catch |err| return Outcome.faulted(err);
            access.write(Host, host, s.csr.implementation.misaligned, at, 32, combine(kind, old, s.x[m])) catch |err| return Outcome.faulted(err);
            root.write(s, d, old);
            return .next;
        }
    };
}
