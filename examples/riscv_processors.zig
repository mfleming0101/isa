const std = @import("std");
const isa = @import("isa");
const riscv = isa.riscv.decode;
const csr = isa.riscv.csr;

const esp32c3 = riscv.only(&.{ .rv32i, .m, .c, .zicsr });
const esp32c6 = esp32c3 | riscv.only(&.{.a});
const esp32p4 = esp32c6 | riscv.only(&.{.f});

const esp32c3_csr: csr.Implementation = .{
    .isa = 0x4010_1104,
    .vendor_id = 0x0000_0612,
    .architecture_id = 0x8000_0001,
    .implementation_id = 0x0000_0001,
    .mstatus_writable = 0x0020_1888,
    .cause_mask = 0x8000_001f,
    .tvec_base_mask = 0xffff_ff00,
    .tvec_modes = .vectored,
    .misaligned = .refused,
    .sc_failure = 1,
    .interrupt_csrs = false,
    .float = false,
};

const esp32c6_csr: csr.Implementation = blk: {
    var m = esp32c3_csr;
    m.isa = 0x4010_1105;
    m.architecture_id = 0x8000_0002;
    m.implementation_id = 0x0000_0002;
    m.interrupt_csrs = true;
    break :blk m;
};

const esp32p4_csr: csr.Implementation = blk: {
    var m = esp32c6_csr;
    m.isa = 0x4010_1125;
    m.architecture_id = 0x8000_0003;
    m.implementation_id = 0x0000_0003;
    m.mstatus_writable = 0x0020_7888;
    m.float = true;
    break :blk m;
};

fn decodes(code: u32, groups: riscv.Groups) bool {
    const decode = isa.generated.riscv_decode;
    const index = if (riscv.escapes(code)) decode.indexWide(code, groups) else decode.indexNarrow(code, groups);
    return index != decode.undefined_index;
}

test "each group set admits what its chip executes" {
    const mul_a0_a1_a2: u32 = 0x02c5_8533;
    const c_addi_a0_1: u32 = 0x0505;
    const csrr_a0_mhartid: u32 = 0xf140_2573;
    const amoadd_w_a0_a1_a2: u32 = 0x00b6_252f;
    const fadd_s_fa0_fa1_fa2: u32 = 0x00c5_8553;

    try std.testing.expect(decodes(mul_a0_a1_a2, esp32c3) and decodes(c_addi_a0_1, esp32c3) and decodes(csrr_a0_mhartid, esp32c3));
    try std.testing.expect(!decodes(amoadd_w_a0_a1_a2, esp32c3) and decodes(amoadd_w_a0_a1_a2, esp32c6));
    try std.testing.expect(!decodes(fadd_s_fa0_fa1_fa2, esp32c6) and decodes(fadd_s_fa0_fa1_fa2, esp32p4));
}

test "each CSR implementation answers with the part's own information registers" {
    var s: isa.riscv.State = .{ .csr = .{ .implementation = esp32c3_csr } };
    try std.testing.expectEqual(@as(u32, 0x0000_0612), s.csr.read(.mvendorid));
    try std.testing.expectEqual(@as(u32, 0x4010_1104), s.csr.read(.misa));

    s.csr.implementation = esp32c6_csr;
    try std.testing.expectEqual(@as(u32, 0x8000_0002), s.csr.read(.marchid));
    try std.testing.expectEqual(@as(u32, 0x4010_1105), s.csr.read(.misa));

    s.csr.implementation = esp32p4_csr;
    try std.testing.expectEqual(@as(u32, 0x4010_1125), s.csr.read(.misa));
}

test "mtvec is vectored on every part, and its base aligns to 256 bytes" {
    var s: isa.riscv.State = .{ .csr = .{ .implementation = esp32c3_csr } };
    s.csr.write(.mtvec, 0x4200_00fe);
    try std.testing.expectEqual(@as(u32, 0x4200_0001), s.csr.mtvec);
}
