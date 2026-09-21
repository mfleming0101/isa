const std = @import("std");
const isa = @import("isa");

test "a code maps to a row index and the row's spec name" {
    const decode = isa.generated.arm_decode;
    const meta = isa.generated.arm_meta;
    const udiv: u32 = 0xfbb1_f0f2; // udiv r0, r1, r2

    const armv7m = isa.arm.decode.selectionOf(.armv7m).groups;
    const i = decode.indexWide(udiv, armv7m);
    try std.testing.expect(i != decode.undefined_index);
    try std.testing.expectEqualStrings("UDIV_T1", meta.names[i]);

    try std.testing.expectEqual(decode.undefined_index, decode.indexWide(0xffff_ffff, armv7m));
}
