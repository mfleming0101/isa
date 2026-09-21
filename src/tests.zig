//! Test root for the library. Its comptime block references every test file under src/arm,
//! src/riscv, src/gen and src/sem so that one zig build test step compiles and runs them all.
//! It also re-exports the semantic layers, because the generated modules reach them through
//! the module that roots them, which is this file in a test build.

/// Semantic layers of this build, as the generated modules import them.
pub const sem = @import("root.zig").sem;

comptime {
    _ = @import("arm/isa/fp_test.zig");
    _ = @import("arm/isa/mve_test.zig");
    _ = @import("arm/isa/pac_test.zig");
    _ = @import("arm/isa/state_test.zig");
    _ = @import("arm/isa/step_test.zig");
    _ = @import("arm/isa/t32_narrow_test.zig");
    _ = @import("arm/isa/t32_wide_test.zig");
    _ = @import("gen/prove.zig");
    _ = @import("riscv/isa/rv32a_test.zig");
    _ = @import("riscv/isa/rv32c_test.zig");
    _ = @import("riscv/isa/rv32f_test.zig");
    _ = @import("riscv/isa/rv32i_test.zig");
    _ = @import("riscv/isa/rv32m_test.zig");
    _ = @import("riscv/isa/state_test.zig");
    _ = @import("riscv/isa/step_test.zig");
    _ = @import("riscv/isa/zicsr_test.zig");
    _ = @import("sem/arm/root_test.zig");
    _ = @import("sem/riscv/root_test.zig");
}
