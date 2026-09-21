/* The RISC-V twin of smc_arm.c: each round patches the body to `addi a0, zero, imm; ret` and
   calls it. RISC-V orders this with fence.i, which is Zifencei and outside the RV32I/M/C core, so
   a plain fence stands in and a design that caches decoded instructions must notice the store
   itself. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 3000
#endif

static unsigned code[2];
int main(void) {
    unsigned acc = 0;
    for (unsigned round = 0; round < ROUNDS; round++) {
        unsigned imm = round & 0x7ff;
        code[0] = (imm << 20) | (10u << 7) | 0x13u;
        code[1] = 0x00008067u;
        __asm__ volatile("fence" ::: "memory");
        unsigned (*run)(void) = (unsigned (*)(void))(void *)code;
        acc += run();
    }
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
