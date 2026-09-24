//! Test root for the library. Its comptime block references every test file under test/, which
//! mirrors src/, and the generator's proofs, so that one zig build test step compiles and runs them
//! all. It also re-exports the semantic layers, because the generated modules reach them through
//! the module that roots them, which is this file in a test build.

/// Semantic layers of this build, as the generated modules import them.
pub const sem = @import("src/root.zig").sem;

comptime {
    _ = @import("src/gen/prove.zig");
    _ = @import("test/arm/isa/fp_test.zig");
    _ = @import("test/arm/isa/mve_test.zig");
    _ = @import("test/arm/isa/pac_test.zig");
    _ = @import("test/arm/isa/state_test.zig");
    _ = @import("test/arm/isa/step_test.zig");
    _ = @import("test/arm/isa/t32_narrow_test.zig");
    _ = @import("test/arm/isa/t32_wide_test.zig");
    _ = @import("test/riscv/isa/rv32a_test.zig");
    _ = @import("test/riscv/isa/rv32c_test.zig");
    _ = @import("test/riscv/isa/rv32f_test.zig");
    _ = @import("test/riscv/isa/rv32i_test.zig");
    _ = @import("test/riscv/isa/rv32m_test.zig");
    _ = @import("test/riscv/isa/state_test.zig");
    _ = @import("test/riscv/isa/step_test.zig");
    _ = @import("test/riscv/isa/zicsr_test.zig");
    _ = @import("test/sem/arm/root_test.zig");
    _ = @import("test/sem/riscv/root_test.zig");
}
