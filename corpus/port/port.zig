//! What every corpus image shares: a fake clock, a console that is a buffer rather than a device,
//! and a CRC of that buffer the start code hands to the harness. No memory-mapped I/O, so the flat
//! memory every alternative is measured on needs no device model. The clock advances twenty seconds
//! a call, so a benchmark demanding a ten-second run sees one without host timing; the console
//! drops characters once full; the CRC-32 is the checksum the manifest pins.

const console_size = 4096;

export var console: [console_size]u8 = @splat(0);
export var console_len: c_uint = 0;

var ticks: c_uint = 0;

export fn bench_clock() c_uint {
    ticks +%= 20000;
    return ticks;
}

export fn console_put(c: u8) void {
    if (console_len < console_size) {
        console[console_len] = c;
        console_len += 1;
    }
}

export fn console_crc() c_uint {
    var c: u32 = 0xffffffff;
    for (console[0..console_len]) |byte| {
        c ^= byte;
        for (0..8) |_| c = (c >> 1) ^ (0xedb88320 & (0 -% (c & 1)));
    }
    return ~c;
}
