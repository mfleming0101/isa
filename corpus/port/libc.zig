//! The slice of libc the Embench sources and CoreMark need, written over port.zig so no image
//! links a real C library: memory and string primitives, ctype, abort, and a printf that renders
//! %d %u %x %c %s and %% with an optional width into the console buffer, and ? for any other
//! conversion. The __aeabi_ entries are what the ARM compiler emits for struct copies and clears.

const builtin = @import("builtin");

extern fn console_put(c: u8) void;
extern fn bench_exit(code: c_uint) void;

export fn memcpy(d: [*]u8, s: [*]const u8, n: usize) [*]u8 {
    for (0..n) |i| d[i] = s[i];
    return d;
}

export fn memmove(d: [*]u8, s: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(d) < @intFromPtr(s)) return memcpy(d, s, n);
    var i = n;
    while (i > 0) {
        i -= 1;
        d[i] = s[i];
    }
    return d;
}

export fn memset(d: [*]u8, c: c_int, n: usize) [*]u8 {
    for (0..n) |i| d[i] = @truncate(@as(c_uint, @bitCast(c)));
    return d;
}

export fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    for (0..n) |i| {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    return 0;
}

export fn strlen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    const wanted: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var p = s;
    while (p[0] != 0) : (p += 1) {
        if (p[0] == wanted) return @constCast(p);
    }
    return if (wanted == 0) @constCast(p) else null;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn abs(v: c_int) c_int {
    return if (v < 0) -%v else v;
}

export fn tolower(c: c_int) c_int {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

export fn toupper(c: c_int) c_int {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

export fn isspace(c: c_int) c_int {
    return @intFromBool(c == ' ' or (c >= '\t' and c <= '\r'));
}

export fn isdigit(c: c_int) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

export fn isalpha(c: c_int) c_int {
    return @intFromBool((c | 32) >= 'a' and (c | 32) <= 'z');
}

export fn isxdigit(c: c_int) c_int {
    return @intFromBool(isdigit(c) != 0 or ((c | 32) >= 'a' and (c | 32) <= 'f'));
}

comptime {
    if (builtin.cpu.arch.isThumb()) {
        @export(&aeabiMemcpy, .{ .name = "__aeabi_memcpy" });
        @export(&aeabiMemcpy, .{ .name = "__aeabi_memcpy4" });
        @export(&aeabiMemcpy, .{ .name = "__aeabi_memcpy8" });
        @export(&aeabiMemmove, .{ .name = "__aeabi_memmove" });
        @export(&aeabiMemmove, .{ .name = "__aeabi_memmove4" });
        @export(&aeabiMemset, .{ .name = "__aeabi_memset" });
        @export(&aeabiMemset, .{ .name = "__aeabi_memset4" });
        @export(&aeabiMemclr, .{ .name = "__aeabi_memclr" });
        @export(&aeabiMemclr, .{ .name = "__aeabi_memclr4" });
        @export(&aeabiMemclr, .{ .name = "__aeabi_memclr8" });
    }
}

fn aeabiMemcpy(d: [*]u8, s: [*]const u8, n: usize) callconv(.c) void {
    _ = memcpy(d, s, n);
}

fn aeabiMemmove(d: [*]u8, s: [*]const u8, n: usize) callconv(.c) void {
    _ = memmove(d, s, n);
}

fn aeabiMemset(d: [*]u8, n: usize, c: c_int) callconv(.c) void {
    _ = memset(d, c, n);
}

fn aeabiMemclr(d: [*]u8, n: usize) callconv(.c) void {
    _ = memset(d, 0, n);
}

export fn abort() noreturn {
    bench_exit(1);
    while (true) {}
}

export fn puts(s: [*:0]const u8) c_int {
    var p = s;
    while (p[0] != 0) : (p += 1) console_put(p[0]);
    console_put('\n');
    return 0;
}

fn putUnsigned(value: c_uint, base: c_uint, width: usize) void {
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (true) {
        digits[n] = "0123456789abcdef"[v % base];
        n += 1;
        v /= base;
        if (v == 0) break;
    }
    while (n < width) : (n += 1) digits[n] = '0';
    while (n > 0) {
        n -= 1;
        console_put(digits[n]);
    }
}

export fn printf(format: [*:0]const u8, ...) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    var f = format;
    while (f[0] != 0) : (f += 1) {
        if (f[0] != '%') {
            console_put(f[0]);
            continue;
        }
        f += 1;
        var width: usize = 0;
        while (f[0] >= '0' and f[0] <= '9') : (f += 1) width = width * 10 + (f[0] - '0');
        while (f[0] == 'l') f += 1;
        switch (f[0]) {
            'd' => {
                const v = @cVaArg(&args, c_int);
                if (v < 0) {
                    console_put('-');
                    putUnsigned(@bitCast(-%v), 10, width);
                } else putUnsigned(@bitCast(v), 10, width);
            },
            'u' => putUnsigned(@cVaArg(&args, c_uint), 10, width),
            'x' => putUnsigned(@cVaArg(&args, c_uint), 16, width),
            'c' => console_put(@truncate(@as(c_uint, @bitCast(@cVaArg(&args, c_int))))),
            's' => {
                var s = @cVaArg(&args, [*:0]const u8);
                while (s[0] != 0) : (s += 1) console_put(s[0]);
            },
            '%' => console_put('%'),
            else => console_put('?'),
        }
    }
    return 0;
}
