//! Reference memory and hosts answering every contract requirement with reset defaults. The
//! semantic tests, the examples and the bench run on them; the library itself does not.

/// Flat backing store over the caller's slice, with the exclusive monitor's tag.
pub const Memory = @import("memory.zig").Memory;
/// Byte length the bench gives the flat memory, 16 MiB.
pub const size = @import("memory.zig").size;
/// Reference Armv7-M host over the flat memory.
pub const arm = @import("arm.zig");
/// Reference RISC-V host over the flat memory.
pub const riscv = @import("riscv.zig");
