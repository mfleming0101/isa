//! Public entry of the RISC-V RV32 half of the library. Re-exports the hart state, the stop
//! reasons, the CSR file, the decode groups, the shared class and outcome types and the step loop
//! from `isa/`, so a processor or a host imports one module.
/// The register, CSR and privilege state of one RV32 hart.
pub const State = @import("isa/state.zig").State;
/// Why the step loop halted a core.
pub const Stop = @import("isa/step.zig").Stop;
/// Control and status registers, privilege modes and trap entry.
pub const csr = @import("isa/csr.zig");
/// Decode groups and the escape test of a 32-bit instruction.
pub const decode = @import("isa/decode.zig");
/// Cycle class, cost and outcome types every row shares.
pub const instruction = @import("isa/instruction.zig");
/// The fetch-decode-execute loop and its per-instruction result.
pub const step = @import("isa/step.zig");
