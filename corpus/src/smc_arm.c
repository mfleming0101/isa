/* Writes its own instructions and runs them, the one thing a design that caches decoded
   instructions has to get right. Each round patches the body to `movs r0, #imm; bx lr` and calls
   it through a Thumb function pointer. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 3000
#endif

static unsigned short body[2];
int main(void) {
    unsigned acc = 0;
    for (unsigned round = 0; round < ROUNDS; round++) {
        unsigned char imm = (unsigned char)(round & 0xff);
        body[0] = (unsigned short)(0x2000u | imm);
        body[1] = 0x4770u;
        unsigned (*run)(void) = (unsigned (*)(void))((unsigned)(void *)body | 1u);
        acc += run();
    }
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
