//! The one architectural state the harness understands. Every machine maps its own state onto
//! `Snapshot` at the facade boundary, so a trace from one alternative can be diffed against
//! another or against an oracle. `Stop` is the deliberately small stop taxonomy that crosses the
//! boundary, and `Vector` is one selfcheck record: a code with the state before and after it.

/// Register file, program counter, flags, retired count and stop reason, as an extern record.
pub const Snapshot = extern struct {
    regs: [32]u32 = @splat(0),
    pc: u32 = 0,
    flags: u32 = 0,
    retired: u64 = 0,
    stop: Stop = .running,
};

/// Eight stop reasons, deliberately fewer than any implementation holds internally.
pub const Stop = enum(u32) {
    running,
    exited,
    undefined_instruction,
    fetch_fault,
    data_fault,
    unaligned,
    breakpoint,
    budget,
};

/// One selfcheck record: an instruction code with the snapshot before and after it.
pub const Vector = extern struct {
    code: u32 = 0,
    before: Snapshot = .{},
    after: Snapshot = .{},
};
