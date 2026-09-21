/* Byte copies and string lengths over 512-byte buffers repeated ROUNDS times: the load, store and
   compare rows in the tightest loops the compiler makes of them. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 900
#endif
static void *copy(void *d, const void *s, unsigned n) {
    unsigned char *a = d; const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}
static unsigned length(const char *s) { const char *p = s; while (*p) p++; return (unsigned)(p - s); }
int main(void) {
    static char src[512], dst[512];
    for (unsigned i = 0; i < sizeof src - 1; i++) src[i] = (char)('A' + (i % 26));
    src[sizeof src - 1] = 0;
    unsigned acc = 0;
    for (int round = 0; round < ROUNDS; round++) { copy(dst, src, sizeof src); acc += length(dst) + (unsigned char)dst[round % 500]; }
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
