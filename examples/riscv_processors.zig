const std = @import("std");
const isa = @import("isa");
const riscv = isa.riscv.decode;
const csr = isa.riscv.csr;

const esp32c3 = riscv.only(&.{ .rv32i, .m, .c, .zicsr }); // ESP32-C3: RV32IMC
const esp32c6 = esp32c3 | riscv.only(&.{.a}); // ESP32-C6: RV32IMAC
const esp32p4 = esp32c6 | riscv.only(&.{.f}); // ESP32-P4: RV32IMAFC

const esp32c3_csr: csr.Implementation = .{
    .isa = 0x4010_1104, // misa: MXL 32 with U, M, I and C, C3 TRM Register 1.6
    .vendor_id = 0x0000_0612, // mvendorid, C3 TRM Register 1.1
    .architecture_id = 0x8000_0001, // marchid, C3 TRM Register 1.2
    .implementation_id = 0x0000_0001, // mimpid, C3 TRM Register 1.3
    .mstatus_writable = 0x0020_1888, // mstatus: MIE, MPIE, MPP and TW, C3 TRM Register 1.5
    .cause_mask = 0x8000_001f, // mcause: the interrupt flag and a five-bit code, C3 TRM Register 1.10
    .tvec_base_mask = 0xffff_ff00, // mtvec BASE, aligned to 256 bytes, C3 TRM Register 1.7
    .tvec_modes = .vectored, // mtvec MODE, read-only 1, C3 TRM Register 1.7
    .misaligned = .refused, // the data host takes each width at its own alignment, C3 TRM 3.3.1
    .sc_failure = 1, // the SC.W fail code, C6 TRM 1.15.2.2
    .interrupt_csrs = false, // no mie or mip, C3 TRM 1.4.1
    .float = false, // no unit, C3 TRM Register 1.6
};

const esp32c6_csr: csr.Implementation = blk: {
    var m = esp32c3_csr;
    m.isa = 0x4010_1105; // misa: the C3's letters with A, C6 TRM Register 1.6
    m.architecture_id = 0x8000_0002; // marchid, C6 TRM Register 1.2
    m.implementation_id = 0x0000_0002; // mimpid, C6 TRM Register 1.3
    m.interrupt_csrs = true; // mie and mip, C6 TRM Registers 1.8 and 1.14
    break :blk m;
};

const esp32p4_csr: csr.Implementation = blk: {
    var m = esp32c6_csr;
    m.isa = 0x4010_1125; // misa: the C6's letters with F, P4 datasheet 4.1.1
    m.architecture_id = 0x8000_0003; // marchid, P4 datasheet 4.1.1
    m.implementation_id = 0x0000_0003; // mimpid, P4 datasheet 4.1.1
    m.mstatus_writable = 0x0020_7888; // mstatus: the C3's fields with FS, since the unit is there
    m.float = true; // fflags, frm and fcsr, P4 datasheet 4.1.1
    break :blk m;
};

fn decodes(code: u32, groups: riscv.Groups) bool {
    const decode = isa.generated.riscv_decode;
    const index = if (riscv.escapes(code)) decode.indexWide(code, groups) else decode.indexNarrow(code, groups);
    return index != decode.undefined_index;
}

test "each group set admits what its chip executes" {
    const mul: u32 = 0x02c5_8533; // mul a0, a1, a2
    const c_addi: u32 = 0x0505; // c.addi a0, 1
    const csrr: u32 = 0xf140_2573; // csrr a0, mhartid
    const amoadd: u32 = 0x00b6_252f; // amoadd.w a0, a1, (a2)
    const fadd: u32 = 0x00c5_8553; // fadd.s fa0, fa1, fa2

    try std.testing.expect(decodes(mul, esp32c3) and decodes(c_addi, esp32c3) and decodes(csrr, esp32c3));
    try std.testing.expect(!decodes(amoadd, esp32c3) and decodes(amoadd, esp32c6));
    try std.testing.expect(!decodes(fadd, esp32c6) and decodes(fadd, esp32p4));
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
