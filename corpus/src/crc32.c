/* A bytewise CRC-32 over a 1 KiB buffer repeated ROUNDS times: tight shifts, XORs and loop
   control, with almost no memory traffic beyond the byte loads. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 400
#endif
static unsigned crc32(const unsigned char *p, unsigned n) {
    unsigned c = 0xffffffffu;
    while (n--) {
        c ^= *p++;
        for (int i = 0; i < 8; i++) c = (c >> 1) ^ (0xedb88320u & -(c & 1u));
    }
    return ~c;
}
int main(void) {
    static unsigned char buf[1024];
    for (unsigned i = 0; i < sizeof buf; i++) buf[i] = (unsigned char)(i * 31 + 7);
    unsigned acc = 0;
    for (int round = 0; round < ROUNDS; round++) acc += crc32(buf, sizeof buf);
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
