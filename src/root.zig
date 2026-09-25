//! Public root of the ISA library. Re-exports the host contract, the Arm T32 and RISC-V RV32
//! instruction sets, the semantic layers, and the generated decode, disassembly and metadata
//! modules, so a consumer imports one module and reaches every
//! architecture through it.

comptime {
    if (@bitSizeOf(usize) != 64) @compileError("isa is a host library for 64-bit machines");
}

/// Host requirement lists and the comptime check a host is held to.
pub const contract = @import("contract.zig");
/// Arm T32 instruction set: state, decode groups and step.
pub const arm = @import("arm/root.zig");
/// RISC-V RV32 instruction set: state, decode groups and step.
pub const riscv = @import("riscv/root.zig");
/// Semantic layers that execute each architecture against a host.
pub const sem = struct {
    /// Arm semantic layer, executed against a host.
    pub const arm = @import("sem/arm/root.zig");
    /// RISC-V semantic layer, executed against a host.
    pub const riscv = @import("sem/riscv/root.zig");
};
/// Decode trees, disassemblers and row metadata the generator emits per architecture.
pub const generated = struct {
    /// Generated Arm T32 index and execute functions.
    pub const arm_decode = @import("arm_decode");
    /// Generated Arm T32 disassembler.
    pub const arm_disasm = @import("arm_disasm");
    /// Generated Arm T32 row counts and names.
    pub const arm_meta = @import("arm_meta");
    /// Generated RISC-V RV32 index and execute functions.
    pub const riscv_decode = @import("riscv_decode");
    /// Generated RISC-V RV32 disassembler.
    pub const riscv_disasm = @import("riscv_disasm");
    /// Generated RISC-V RV32 row counts and names.
    pub const riscv_meta = @import("riscv_meta");
};
