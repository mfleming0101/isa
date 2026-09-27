//! Insertion sort of 256 pseudo-random words repeated rounds times: compare-and-branch inner loops
//! with a moving store, the classic branchy memory pattern.

const rounds = 1300;

extern fn console_put(c: u8) void;

var a: [256]i32 = @splat(0);

fn isort(x: []i32) void {
    var i: usize = 1;
    while (i < x.len) : (i += 1) {
        const v = x[i];
        var j = i;
        while (j > 0 and x[j - 1] > v) : (j -= 1) x[j] = x[j - 1];
        x[j] = v;
    }
}

export fn main() c_int {
    var seed: u32 = 12345;
    var acc: u32 = 0;
    for (0..rounds) |_| {
        for (&a) |*v| {
            seed = seed *% 1103515245 +% 12345;
            v.* = @intCast(seed >> 16);
        }
        isort(&a);
        acc +%= @as(u32, @bitCast(a[0])) ^ @as(u32, @bitCast(a[255]));
    }
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
