//! Contract every measured machine exposes to the harness. Holds the architecture tag, the loaded-
//! image record, the Armv7-M reset state every alternative starts from, the result of a run, and
//! `assertMachine`, the comptime check the `consumer` generator and size probe apply so one program
//! and one output grammar cover every alternative.

const std = @import("std");
const snapshot = @import("snapshot.zig");
const contract = @import("isa").contract;

/// The two architectures the harness can load and measure.
pub const Arch = enum { armv7m, rv32imc };

/// A loaded program: its flat memory, base address, entry point and initial stack pointer.
pub const Image = struct {
    memory: []u8,
    base: u32,
    entry: u32,
    sp: u32,
};

/// Reset state every Armv7-M alternative starts from, so traces agree with each other and QEMU.
pub const armv7m_reset = struct {
    /// LR at reset, per Armv7-M B1.5.5.
    pub const lr: u32 = 0xffff_ffff;
    /// T set, and the Z flag QEMU comes out of reset with.
    pub const xpsr: u32 = 1 << 24 | 1 << 30;
};

/// What a run retired, why it stopped, and the probe's unique-PC and decode counts.
pub const Ran = struct {
    retired: u64,
    stop: snapshot.Stop,
    unique_pcs: u64 = 0,
    decodes: u64 = 0,
};

/// Compile error unless M declares every facade constant, function and, if listed, host requirement.
pub fn assertMachine(comptime M: type) void {
    const wanted = .{
        .{ "arch", Arch },
        .{ "rows_implemented", usize },
        .{ "rows_total", usize },
        .{ "imported_types", usize },
        .{ "result_register", u5 },
    };
    inline for (wanted) |w| {
        if (!@hasDecl(M, w[0])) @compileError(@typeName(M) ++ " is missing pub const " ++ w[0]);
        if (@TypeOf(@field(M, w[0])) != w[1]) @compileError(@typeName(M) ++ "." ++ w[0] ++ " must be " ++ @typeName(w[1]));
    }
    inline for (.{ "prepare", "init", "run", "stepOnce", "snapshot", "load", "disassemble", "decodeOnly" }) |name| {
        if (!@hasDecl(M, name)) @compileError(@typeName(M) ++ " is missing fn " ++ name);
    }
    if (@hasDecl(M, "host_requirements")) contract.assertHost(M.Host, M.host_requirements);
}
