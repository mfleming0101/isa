//! The one image that needs the F extension. Each round exercises the RV32F rows through inline
//! assembly the compiler cannot lower differently: arithmetic, fused multiply-adds, sign
//! injection, comparisons, conversions, classification, rounding-mode and flag CSRs, and the loads
//! and stores in both compressed and uncompressed encodings, the compressed ones pinned to registers
//! the CL and CS formats can name and the uncompressed ones to registers outside them. The rounding
//! mode changes every round so the flags and results depend on it.

const rounds = 510000;

extern fn console_put(c: u8) void;

var slot: [2]f32 = @splat(0);

fn enableFpu() void {
    asm volatile ("csrs mstatus, %[v]"
        :
        : [v] "r" (@as(u32, 0x2000)),
    );
}

fn rootOf(x: f32) f32 {
    return asm ("fsqrt.s %[r], %[x]"
        : [r] "=f" (-> f32),
        : [x] "f" (x),
    );
}

fn smaller(a: f32, b: f32) f32 {
    return asm ("fmin.s %[r], %[a], %[b]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
    );
}

fn larger(a: f32, b: f32) f32 {
    return asm ("fmax.s %[r], %[a], %[b]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
    );
}

fn fused(a: f32, b: f32, c: f32) f32 {
    return asm ("fmadd.s %[r], %[a], %[b], %[c]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
          [c] "f" (c),
    );
}

fn signedLike(a: f32, b: f32) f32 {
    return asm ("fsgnj.s %[r], %[a], %[b]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
    );
}

fn difference(a: f32, b: f32) f32 {
    return asm ("fsub.s %[r], %[a], %[b]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
    );
}

fn signedApart(a: f32, b: f32) f32 {
    return asm ("fsgnjx.s %[r], %[a], %[b]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
    );
}

fn fusedLow(a: f32, b: f32, c: f32) f32 {
    return asm ("fmsub.s %[r], %[a], %[b], %[c]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
          [c] "f" (c),
    );
}

fn fusedNegated(a: f32, b: f32, c: f32) f32 {
    return asm ("fnmadd.s %[r], %[a], %[b], %[c]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
          [c] "f" (c),
    );
}

fn fusedNegatedLow(a: f32, b: f32, c: f32) f32 {
    return asm ("fnmsub.s %[r], %[a], %[b], %[c]"
        : [r] "=f" (-> f32),
        : [a] "f" (a),
          [b] "f" (b),
          [c] "f" (c),
    );
}

fn fromWord(x: i32) f32 {
    return asm ("fcvt.s.w %[r], %[x]"
        : [r] "=f" (-> f32),
        : [x] "r" (x),
    );
}

fn throughMemory(x: f32, at: *[2]f32) f32 {
    return asm volatile (
        \\addi sp, sp, -8
        \\fsw %[given], 0(%[at])
        \\c.fsw %[given], 4(%[at])
        \\c.flw %[taken], 4(%[at])
        \\c.fswsp %[taken], 0(sp)
        \\c.flwsp %[taken], 0(sp)
        \\addi sp, sp, 8
        : [taken] "={fa2}" (-> f32),
        : [given] "{fa1}" (x),
          [at] "{a0}" (at),
        : .{ .memory = true });
}

fn wideMemory(x: f32, at: *[2]f32) f32 {
    return asm volatile (
        \\fsw %[given], 0(%[at])
        \\flw %[taken], 0(%[at])
        : [taken] "={ft9}" (-> f32),
        : [given] "{ft8}" (x),
          [at] "{a7}" (at),
        : .{ .memory = true });
}

fn kindOf(x: f32) u32 {
    return asm ("fclass.s %[r], %[x]"
        : [r] "=r" (-> u32),
        : [x] "f" (x),
    );
}

fn flagsOf() u32 {
    return asm volatile ("csrr %[r], fflags"
        : [r] "=r" (-> u32),
    );
}

fn mode(m: u32) void {
    asm volatile ("csrw frm, %[m]"
        :
        : [m] "r" (m),
    );
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

fn value(u: u32) f32 {
    return @bitCast(u);
}

export fn main() c_int {
    enableFpu();
    var acc: u32 = 0;
    var table: [16]f32 = undefined;
    for (&table, 0..) |*t, i| t.* = value(0x3f800000 + @as(u32, @intCast(i)) * 0x00100000);
    var round: i32 = 0;
    while (round < rounds) : (round += 1) {
        const r: u32 = @bitCast(round);
        mode(r & 3);
        var sum: f32 = 0.0;
        var product: f32 = 1.0;
        var i: i32 = 0;
        while (i < 16) : (i += 1) {
            const x = table[@intCast(i)];
            sum = sum + x;
            product = product * (x - 0.5);
            sum = sum + x / @as(f32, @floatFromInt(i + 1));
            sum = fused(x, product, sum);
            if (x < product) sum = sum - 1.0;
            if (x == product) sum = sum + 2.0;
            if (x <= product) acc +%= 3;
        }
        var root = rootOf(if (sum < 0.0) -sum else sum);
        root = smaller(root, sum);
        root = larger(root, product);
        root = signedLike(root, product);
        root = difference(root, signedApart(root, sum));
        root = fusedLow(root, product, sum);
        root = fusedNegated(root, product, sum);
        root = fusedNegatedLow(root, product, sum);
        root = root + fromWord(round);
        root = throughMemory(root, &slot);
        root = wideMemory(root, &slot);
        acc +%= bits(sum) ^ bits(product) ^ bits(root);
        acc +%= kindOf(root) +% kindOf(sum);
        acc +%= @bitCast(@as(i32, @intFromFloat(root)));
        acc ^= @as(u32, @intFromFloat(if (sum < 0.0) 0.0 else sum));
        acc +%= flagsOf();
        table[r & 15] = value((bits(table[r & 15]) & 0x7fffffff) | ((acc & 1) << 31));
    }
    for (0..8) |k| console_put('a' + @as(u8, @truncate((acc >> @intCast(k * 4)) & 15)));
    return 0;
}
