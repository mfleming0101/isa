//! Reference Armv7-M host over the flat memory. It answers every entry of
//! contract.arm_requirements: the three span declarations delegate to Memory, and the rest give the
//! answers a plain core out of reset gives, with no security extension, PAC/BTI, MVE,
//! floating-point unit, exception model or traps. The semantic tests and the bench measure
//! alternatives on it.

const Memory = @import("memory.zig").Memory;
const Architecture = @import("../arm/isa/architecture.zig").Architecture;
const step = @import("../arm/isa/step.zig");

/// Reference host answering arm_requirements with the defaults of a plain core out of reset.
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

    /// The core is Armv7-M.
    pub fn architecture(_: *Host) Architecture {
        return .armv7m;
    }

    /// No security extension is fitted.
    pub fn security(_: *Host) bool {
        return false;
    }

    /// No pointer authentication or branch target identification is fitted.
    pub fn pacbti(_: *Host) bool {
        return false;
    }

    /// The controller implements four priority bits.
    pub fn priorityBits(_: *Host) u4 {
        return 4;
    }

    /// CCR.UNALIGN_TRP is clear; unaligned accesses are answered.
    pub fn trapsUnaligned(_: *Host) bool {
        return false;
    }

    /// CCR.DIV_0_TRP is clear; divide by zero answers zero.
    pub fn trapsDivideByZero(_: *Host) bool {
        return false;
    }

    /// A retired call, exception return or function return; nothing follows it.
    pub fn signal(_: *Host, _: step.Signal) void {}

    /// A mask register write; nothing re-arms.
    pub fn rearm(_: *Host) void {}

    /// A WFE or WFI halt request; nothing waits.
    pub fn sleep(_: *Host, _: step.Wait) void {}

    /// SEV set the event register; nobody consumes it.
    pub fn event(_: *Host) void {}

    /// No vector extension is fitted.
    pub fn mve(_: *Host) bool {
        return false;
    }

    /// No floating-point unit is fitted; CONTROL.FPCA and SFPA stay reserved.
    pub fn floatingPoint(_: *Host) bool {
        return false;
    }

    /// CPACR.CP10 is clear; no floating-point unit is reachable.
    pub fn coprocessorEnabled(_: *Host) bool {
        return false;
    }

    /// No double-precision unit is fitted.
    pub fn doublePrecision(_: *Host) bool {
        return false;
    }

    /// The unit is not FPv5.
    pub fn fpv5(_: *Host) bool {
        return false;
    }

    /// No half-precision unit is fitted.
    pub fn halfPrecision(_: *Host) bool {
        return false;
    }

    /// FPCCR.ASPEN is clear; no context is opened automatically.
    pub fn automaticFpState(_: *Host) bool {
        return false;
    }

    /// FPDSCR reads as zero.
    pub fn defaultFpscr(_: *Host) u32 {
        return 0;
    }

    /// No deferred floating-point save is owed.
    pub fn lazyFpFrame(_: *Host) ?u32 {
        return null;
    }

    /// No callee-saved half is owed.
    pub fn lazyFpCallee(_: *Host) bool {
        return false;
    }

    /// FPCCR.LSPEN is clear; saves are never deferred.
    pub fn lazyFpEnabled(_: *Host) bool {
        return false;
    }

    /// A deferred save was settled; nothing is recorded.
    pub fn setLazyFp(_: *Host, _: ?u32) void {}

    /// FPCCR.TS is clear; no Non-secure floating-point context is carried.
    pub fn treatAsSecure(_: *Host) bool {
        return false;
    }

    /// The Non-secure FPSCR reads as zero.
    pub fn nonSecureFpscr(_: *Host) u32 {
        return 0;
    }
};
