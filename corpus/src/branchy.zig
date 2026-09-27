//! An interpreter loop over a 512-byte pseudo-random program: the dispatch is data-dependent and
//! mispredicts, the shape that separates decode designs most sharply. rounds scales the run; the
//! result is printed as eight letters for the console CRC.

const rounds = 44000;

extern fn console_put(c: u8) void;

var program: [512]u8 = @splat(0);

export fn main() c_int {
    var seed: u32 = 999;
    for (&program) |*op| {
        seed = seed *% 1103515245 +% 12345;
        op.* = @as(u8, @truncate(seed >> 24)) % 7;
    }
    var acc: u32 = 0;
    var r: u32 = 1;
    for (0..rounds) |_| {
        for (&program) |op| {
            switch (op) {
                0 => r +%= 3,
                1 => r ^= 0x5a5a,
                2 => r <<= 1,
                3 => r >>= 2,
                4 => r *%= 5,
                5 => r -%= 7,
                else => acc +%= r,
            }
        }
    }
    acc +%= r;
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
