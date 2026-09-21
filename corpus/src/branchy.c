/* An interpreter loop over a 512-byte pseudo-random program: the dispatch is data-dependent and
   mispredicts, the shape that separates decode designs most sharply. ROUNDS scales the run; the
   result is printed as eight letters for the console CRC. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 700
#endif

int main(void) {
    static unsigned char program[512];
    unsigned seed = 999;
    for (unsigned i = 0; i < sizeof program; i++) { seed = seed * 1103515245u + 12345u; program[i] = (unsigned char)(seed >> 24) % 7; }
    unsigned acc = 0, r = 1;
    for (int round = 0; round < ROUNDS; round++) {
        for (unsigned i = 0; i < sizeof program; i++) {
            switch (program[i]) {
                case 0: r += 3; break;
                case 1: r ^= 0x5a5a; break;
                case 2: r <<= 1; break;
                case 3: r >>= 2; break;
                case 4: r *= 5; break;
                case 5: r -= 7; break;
                default: acc += r; break;
            }
        }
    }
    acc += r;
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
