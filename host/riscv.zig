//! Reference RISC-V host over the flat memory. It answers every entry of
//! contract.riscv_requirements: the three span declarations delegate to Memory, PMP registers read
//! as unwritten entries, and the rearm, returned and sleep events are heard by nobody, since there
//! is no protection unit, interrupt controller or clock gate. The semantic tests and the bench run
//! on it.

const Memory = @import("memory.zig").Memory;
const csr = @import("isa").riscv.csr;

/// Reference host answering riscv_requirements with no protection unit, interrupt controller or
/// clock gate.
pub const Host = struct {
    memory: Memory,

    /// Delegates the span lookup to the flat memory.
    pub fn span(self: *Host, address: u32, comptime a: anytype) []u8 {
        return self.memory.span(address, a);
    }

    /// Delegates the refused access to the flat memory.
    pub fn access(self: *Host, address: u32, comptime a: anytype, value: u32) Memory.Failure!u32 {
        return self.memory.access(address, a, value);
    }

    /// Delegates the lookup address to the flat memory.
    pub fn touch(self: *Host, address: u32) void {
        self.memory.touch(address);
    }

    /// Every pmpcfg and pmpaddr register reads as zero.
    pub fn readPmp(_: *Host, _: csr.Protection) u32 {
        return 0;
    }

    /// A PMP write; no protection unit records it.
    pub fn writePmp(_: *Host, _: csr.Protection, _: u32) void {}

    /// A write reached mstatus or mie; no interrupt can become due.
    pub fn rearm(_: *Host) void {}

    /// MRET changed privilege; nothing depends on it.
    pub fn returned(_: *Host) void {}

    /// WFI asked to halt; no clock gate is turned off.
    pub fn sleep(_: *Host) void {}
};
