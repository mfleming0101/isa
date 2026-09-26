const std = @import("std");
const isa = @import("isa");
const arm = isa.arm.decode;

const m0 = arm.only(&.{.v6m});
const m3 = arm.only(&.{ .v6m, .v7m, .main });
const m4 = arm.only(&.{ .v6m, .v7m, .main, .dsp });
const m23 = arm.only(&.{ .v6m, .v7m, .v8m });
const m33 = arm.only(&.{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main });
const m55 = m33 | arm.only(&.{ .v8_1m, .mve });

fn decodes(code: u32, groups: arm.Groups) bool {
    const decode = isa.generated.arm_decode;
    return decode.indexWide(code, groups) != decode.undefined_index;
}

test "each group set admits what its processor executes" {
    const udiv_r0_r1_r2: u32 = 0xfbb1_f0f2;
    const qadd_r0_r2_r1: u32 = 0xfa81_f082;
    const vadd_f32_s0_s0_s0: u32 = 0xee30_0a00;
    const vadd_f64_d0_d0_d0: u32 = 0xee30_0b00;
    const sg: u32 = 0xe97f_e97f;
    const vadd_i32_q0_q0_q0: u32 = 0xef20_0840;

    try std.testing.expect(!decodes(udiv_r0_r1_r2, m0) and decodes(udiv_r0_r1_r2, m3) and decodes(udiv_r0_r1_r2, m23));
    try std.testing.expect(!decodes(qadd_r0_r2_r1, m3) and decodes(qadd_r0_r2_r1, m4));
    try std.testing.expect(!decodes(vadd_f32_s0_s0_s0, m0) and !decodes(vadd_f32_s0_s0_s0, m23) and decodes(vadd_f32_s0_s0_s0, m4));
    try std.testing.expect(!decodes(vadd_f64_d0_d0_d0, m23) and decodes(vadd_f64_d0_d0_d0, m4) and decodes(vadd_f64_d0_d0_d0, m55));
    try std.testing.expect(!decodes(sg, m4) and decodes(sg, m23));
    try std.testing.expect(!decodes(vadd_i32_q0_q0_q0, m33) and decodes(vadd_i32_q0_q0_q0, m55));
}
