//! The RISC-V twin of smc_arm.zig: each round patches the body to `addi a0, zero, imm; ret` and
//! calls it. RISC-V orders this with fence.i, which is Zifencei and outside the RV32I/M/C core, so
//! a plain fence stands in and a design that caches decoded instructions must notice the store
//! itself.

const rounds = 15000000;

extern fn console_put(c: u8) void;

var code: [2]u32 = @splat(0);

export fn main() c_int {
    var acc: u32 = 0;
    for (0..rounds) |round| {
        const imm: u32 = @as(u32, @truncate(round)) & 0x7ff;
        code[0] = (imm << 20) | (10 << 7) | 0x13;
        code[1] = 0x00008067;
        asm volatile ("fence" ::: .{ .memory = true });
        const run: *const fn () callconv(.c) u32 = @ptrCast(&code);
        acc +%= run();
    }
    for (0..8) |i| console_put('a' + @as(u8, @truncate((acc >> @intCast(i * 4)) & 15)));
    return 0;
}
