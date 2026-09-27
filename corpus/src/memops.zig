//! Byte copies and string lengths over 512-byte buffers repeated rounds times: the load, store and
//! compare rows in the tightest loops the compiler makes of them.

const rounds = 43000;

extern fn console_put(c: u8) void;

var src: [512]u8 = @splat(0);
var dst: [512]u8 = @splat(0);

fn copy(d: [*]u8, s: [*]const u8, n: usize) void {
    for (0..n) |i| d[i] = s[i];
}

fn length(s: [*]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

export fn main() c_int {
    for (src[0 .. src.len - 1], 0..) |*c, i| c.* = 'A' + @as(u8, @intCast(i % 26));
    src[src.len - 1] = 0;
    var acc: u32 = 0;
    for (0..rounds) |round| {
        copy(&dst, &src, src.len);
        acc +%= length(&dst) +% dst[round % 500];
    }
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
