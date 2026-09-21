/* What every corpus image shares: a fake clock, a console that is a buffer rather than a device,
   and a CRC of that buffer the start code hands to the harness. No memory-mapped I/O, so the flat
   memory every alternative is measured on needs no device model. */
#include "port.h"

char console[CONSOLE_SIZE];
unsigned console_len = 0;

static unsigned ticks = 0;

/* Advances twenty seconds a call, so a benchmark demanding a ten-second run sees one without host
   timing. */
unsigned bench_clock(void) {
    ticks += 20000;
    return ticks;
}

/* Appends one character to the console buffer, dropping it once the buffer is full. */
void console_put(char c) {
    if (console_len < CONSOLE_SIZE) console[console_len++] = c;
}

/* CRC-32 of the console buffer; the checksum the manifest pins for the image. */
unsigned console_crc(void) {
    unsigned c = 0xffffffffu;
    for (unsigned i = 0; i < console_len; i++) {
        c ^= (unsigned char)console[i];
        for (int b = 0; b < 8; b++) c = (c >> 1) ^ (0xedb88320u & -(c & 1u));
    }
    return ~c;
}
