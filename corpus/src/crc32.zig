//! A bytewise CRC-32 over a 1 KiB buffer repeated rounds times: tight shifts, XORs and loop
//! control, with almost no memory traffic beyond the byte loads.

const rounds = 3000;

extern fn console_put(c: u8) void;

var buf: [1024]u8 = @splat(0);

fn crc32(p: []const u8) u32 {
    var c: u32 = 0xffffffff;
    for (p) |byte| {
        c ^= byte;
        for (0..8) |_| c = (c >> 1) ^ (0xedb88320 & (0 -% (c & 1)));
    }
    return ~c;
}

export fn main() c_int {
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    var acc: u32 = 0;
    for (0..rounds) |_| acc +%= crc32(&buf);
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
