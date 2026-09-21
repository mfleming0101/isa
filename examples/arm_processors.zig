const std = @import("std");
const isa = @import("isa");
const arm = isa.arm.decode;

const m0 = arm.only(&.{.v6m}); // Cortex-M0, M0+, M1: Armv6-M
const m3 = arm.only(&.{ .v6m, .v7m, .main }); // Cortex-M3: Armv7-M
const m4 = arm.only(&.{ .v6m, .v7m, .main, .dsp }); // Cortex-M4, M7: Armv7E-M, with or without an FPU
const m23 = arm.only(&.{ .v6m, .v7m, .v8m }); // Cortex-M23: Armv8-M Baseline
const m33 = arm.only(&.{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main }); // Cortex-M33 with DSP
const m55 = m33 | arm.only(&.{ .v8_1m, .mve }); // Cortex-M55, M85: Armv8.1-M with MVE

fn decodes(code: u32, groups: arm.Groups) bool {
    const decode = isa.generated.arm_decode;
    return decode.indexWide(code, groups) != decode.undefined_index;
}

test "each group set admits what its processor executes" {
    const udiv: u32 = 0xfbb1_f0f2; // udiv r0, r1, r2
    const qadd: u32 = 0xfa81_f082; // qadd r0, r2, r1
    const vadd_f32: u32 = 0xee30_0a00; // vadd.f32 s0, s0, s0
    const vadd_f64: u32 = 0xee30_0b00; // vadd.f64 d0, d0, d0
    const sg: u32 = 0xe97f_e97f; // sg
    const vadd_i32: u32 = 0xef20_0840; // vadd.i32 q0, q0, q0

    try std.testing.expect(!decodes(udiv, m0) and decodes(udiv, m3) and decodes(udiv, m23));
    try std.testing.expect(!decodes(qadd, m3) and decodes(qadd, m4));
    try std.testing.expect(!decodes(vadd_f32, m0) and !decodes(vadd_f32, m23) and decodes(vadd_f32, m4));
    try std.testing.expect(!decodes(vadd_f64, m23) and decodes(vadd_f64, m4) and decodes(vadd_f64, m55));
    try std.testing.expect(!decodes(sg, m4) and decodes(sg, m23));
    try std.testing.expect(!decodes(vadd_i32, m33) and decodes(vadd_i32, m55));
}
