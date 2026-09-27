//! Writes its own instructions and runs them, the one thing a design that caches decoded
//! instructions has to get right. Each round patches the body to `movs r0, #imm; bx lr` and calls
//! it through a Thumb function pointer.

const rounds = 15000000;

extern fn console_put(c: u8) void;

var body: [2]u16 = @splat(0);

export fn main() c_int {
    var acc: u32 = 0;
    for (0..rounds) |round| {
        const imm: u16 = @as(u8, @truncate(round));
        body[0] = 0x2000 | imm;
        body[1] = 0x4770;
        const run: *const fn () callconv(.c) u32 = @ptrFromInt(@intFromPtr(&body) | 1);
        acc +%= run();
    }
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
