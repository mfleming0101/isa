//! Types shared by every RV32 row: the cycle class a row is charged by, the cost each class
//! carries, the outcome a handler answers with, and the access failure set. A compressed row takes
//! the class of the instruction it expands to; atomics and LR.W are classes of their own because
//! they cost differently and their misaligned address is a Store/AMO one, Privileged 3.1.15.
//! Imported by the semantics handlers and the step loop.

/// Cycle classes rows are charged by; atomic and load_reserved also pick the fault code,
/// Privileged 3.1.15.
pub const Class = enum(u4) { data_processing, load, store, branch, jump, system, multiply, divide, atomic, load_reserved };

/// Cycles a class costs, plus the extra charged when a branch or jump is taken.
pub const Cost = packed struct(u16) { cycles: u8, taken: u8 };

/// Number of cycle classes, which sizes a model's cost table.
pub const costs_len = @typeInfo(Class).@"enum".fields.len;

/// What a row answers: retired, branched, stopped, trapped, faulted, unimplemented or illegal.
pub const Outcome = enum(u8) {
    next,
    branched,
    breakpoint,
    environment_call,
    data_fault,
    unaligned,
    unimplemented,
    illegal,

    /// The outcome for a refused access: a data fault or an unaligned one.
    pub fn faulted(err: Failure) Outcome {
        return switch (err) {
            error.DataFault => .data_fault,
            error.Unaligned => .unaligned,
        };
    }
};

/// Errors an access can raise: no memory answered, or the address was misaligned.
pub const Failure = error{ DataFault, Unaligned };
