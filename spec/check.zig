//! The gate before every other measurement: the shared row set an alternative is handed must be well
//! formed and unambiguous, or a decoder answering with one row is answering by accident. Loads every
//! spec/*.zon file, concatenates them into one Arm and one RISC-V row set, and tests the row count,
//! that no two rows of an architecture can match the same code or share a name, and that every
//! pattern character is a fixed bit or an operand letter.
const std = @import("std");
/// The row schema the spec files are typed against.
pub const schema = @import("schema.zig");

const t32_narrow: []const schema.Row = @import("arm/t32_narrow.zon");
const t32_wide: []const schema.Row = @import("arm/t32_wide.zon");
const rv32i: []const schema.Row = @import("riscv/rv32i.zon");
const rv32m: []const schema.Row = @import("riscv/rv32m.zon");
const rv32c: []const schema.Row = @import("riscv/rv32c.zon");
const v8m_narrow: []const schema.Row = @import("arm/v8m_narrow.zon");
const v8m_wide: []const schema.Row = @import("arm/v8m_wide.zon");
const v8_1m_wide: []const schema.Row = @import("arm/v8_1m_wide.zon");
const fp_wide: []const schema.Row = @import("arm/fp.zon");
const dsp_wide: []const schema.Row = @import("arm/dsp.zon");
const fp_double: []const schema.Row = @import("arm/fp_double.zon");
const fp_half: []const schema.Row = @import("arm/fp_half.zon");
const fp_rest: []const schema.Row = @import("arm/fp_rest.zon");
const mve_lanewise: []const schema.Row = @import("arm/mve_lanewise.zon");
const mve_shift: []const schema.Row = @import("arm/mve_shift.zon");
const mve_memory: []const schema.Row = @import("arm/mve_memory.zon");
const mve_half: []const schema.Row = @import("arm/mve_half.zon");
const mve_reduce: []const schema.Row = @import("arm/mve_reduce.zon");
const mve_multiply: []const schema.Row = @import("arm/mve_multiply.zon");
const mve_real: []const schema.Row = @import("arm/mve_real.zon");
const mve_control: []const schema.Row = @import("arm/mve_control.zon");
const rv32a: []const schema.Row = @import("riscv/rv32a.zon");
const zicsr: []const schema.Row = @import("riscv/zicsr.zon");
const rv32f: []const schema.Row = @import("riscv/rv32f.zon");

/// Every Arm row of the conformance core, in file order.
pub const arm = t32_narrow ++ t32_wide ++ v8m_narrow ++ v8m_wide ++ v8_1m_wide ++ fp_wide ++ dsp_wide ++ fp_double ++ fp_half ++ fp_rest ++ mve_lanewise ++ mve_shift ++ mve_memory ++ mve_half ++ mve_reduce ++ mve_multiply ++ mve_real ++ mve_control;
/// Every RISC-V row of the conformance core, in file order.
pub const riscv = rv32i ++ rv32m ++ rv32c ++ rv32a ++ zicsr ++ rv32f;

test "the conformance core holds 1534 rows" {
    try std.testing.expectEqual(@as(usize, 1410), arm.len);
    try std.testing.expectEqual(@as(usize, 124), riscv.len);
}

test "no two rows of one architecture can match the same code" {
    try std.testing.expectEqual(@as(?schema.Problem, null), schema.validate(arm));
    try std.testing.expectEqual(@as(?schema.Problem, null), schema.validate(riscv));
    try std.testing.expectEqual(@as(u32, 0), schema.ambiguities(arm));
    try std.testing.expectEqual(@as(u32, 0), schema.ambiguities(riscv));
}

test "no two rows of one architecture share a name" {
    inline for (.{ arm, riscv }) |set| {
        for (set, 0..) |a, i| {
            for (set[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "a pattern character is a fixed bit or an operand letter, and a mistyped digit is neither" {
    const typo: []const schema.Row = &.{.{ .name = "X_0", .bits = "001002ddiiiiiiii", .text = "movs r{d}, #{i}", .class = "data_processing", .group = "core" }};
    try std.testing.expectEqual(@as(?schema.Problem, .{ .bad_character = .{ .row = 0, .at = 5 } }), schema.validate(typo));
}
