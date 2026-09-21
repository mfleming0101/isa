//! The architectural state of one RV32 hart: thirty-two integer registers and the program counter
//! (section 2.1), thirty-two single-precision registers (section 20.1), the CSR file, the current
//! privilege, and the reservation an LR.W holds. x0 is hardwired to zero by `set`, so `get` needs
//! no test. The cold fields sit after the integer registers so the run loop's hot data stays near
//! the pointer. Every handler and the step loop operate on this struct.
const csr = @import("csr.zig");

/// One hart's registers, program counter, CSR file, privilege and LR.W reservation.
pub const State = struct {
    x: [32]u32 = @splat(0),
    pc: u32 = 0,

    f: [32]u32 = @splat(0),
    csr: csr.File = .{},
    privilege: csr.Privilege = .machine,

    reservation: ?u32 = null,

    /// Reads integer register i; x0 always reads zero.
    pub fn get(self: *const State, i: u5) u32 {
        return self.x[i];
    }

    /// Writes integer register i, dropping a write to x0, section 2.1.
    pub fn set(self: *State, i: u5, value: u32) void {
        if (i != 0) self.x[i] = value;
    }
};
