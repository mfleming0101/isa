//! Public surface of the Arm T32 library. Re-exports the architecture enum, the core
//! state, the step stop reasons and the decode-group, floating-point, instruction, step
//! and wide-encoding modules for callers outside src/arm.
/// M-profile architectures the library models.
pub const Architecture = @import("isa/architecture.zig").Architecture;
/// Register and status state of one Arm core.
pub const State = @import("isa/state.zig").State;
/// Reason a step halted instead of retiring an instruction.
pub const Stop = @import("isa/step.zig").Stop;
/// Decode groups and the selection a step loop runs with.
pub const decode = @import("isa/decode.zig");
/// Floating-point extension arithmetic and register file.
pub const fp = @import("isa/fp.zig");
/// Instruction classes, costs, outcomes and access failures.
pub const instruction = @import("isa/instruction.zig");
/// Fetch, decode and execute loop for one instruction.
pub const step = @import("isa/step.zig");
/// Long shifts and the branch target landing test of the 32-bit T32 set.
pub const t32_wide = @import("isa/t32_wide.zig");
