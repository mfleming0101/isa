const std = @import("std");
const isa = @import("isa");

test "the same two codes as text" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try isa.generated.arm_disasm.write(&w, 0x2001, 0, isa.arm.decode.selectionOf(.armv7m).groups);
    try std.testing.expectEqualStrings("movs r0, #1", w.buffered());

    w = .fixed(&buf);
    try isa.generated.riscv_disasm.write(&w, 0x00100513, 0, isa.riscv.decode.every);
    try std.testing.expectEqualStrings("addi a0, zero, 1", w.buffered());
}
