//! Tests of the pointer authentication code algorithm: that the code depends on the
//! pointer, the modifier and every key word, still varies under a zero key, and spreads
//! a one-bit change across the result.
const std = @import("std");
const pac = @import("pac.zig");

const key: [4]u32 = .{ 0x0123_4567, 0x89ab_cdef, 0xfedc_ba98, 0x7654_3210 };

test "the code an implementation-defined algorithm answers is a function of the pointer, the modifier and both halves of the key, B6.1.1" {
    const base = pac.compute(0x0800_1235, 0x2000_0100, &key);
    try std.testing.expectEqual(base, pac.compute(0x0800_1235, 0x2000_0100, &key));
    try std.testing.expect(base != pac.compute(0x0800_1237, 0x2000_0100, &key));
    try std.testing.expect(base != pac.compute(0x0800_1235, 0x2000_0104, &key));
    for (0..4) |i| {
        var other = key;
        other[i] ^= 1;
        try std.testing.expect(base != pac.compute(0x0800_1235, 0x2000_0100, &other));
    }
}

test "a key of zero still answers a code that depends on the pointer, B6.1.1" {
    const zero: [4]u32 = @splat(0);
    try std.testing.expect(pac.compute(1, 0, &zero) != pac.compute(2, 0, &zero));
    try std.testing.expect(pac.compute(1, 0, &zero) != pac.compute(1, 1, &zero));
}

test "the algorithm spreads a one-bit change across the code, B6.1.1" {
    var worst: u32 = 32;
    for (0..32) |i| {
        const flipped = @popCount(pac.compute(0x0800_1234, 0x2000_0100, &key) ^ pac.compute(0x0800_1234 ^ @as(u32, 1) << @intCast(i), 0x2000_0100, &key));
        worst = @min(worst, flipped);
    }
    try std.testing.expect(worst >= 8);
}
