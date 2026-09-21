/* The same five-instruction loop in compressed encodings, so the two RISC-V columns isolate what
   the C extension's sixteen-bit parcels cost a decoder relative to the thirty-two-bit forms. */
    .section .vectors, "a"
    .globl _start
_start:
    lui  sp, %hi(_stack)
    addi sp, sp, %lo(_stack)
    .option rvc
loop:
    c.li   a0, 1
    c.add  a1, a0
    c.swsp a1, 4(sp)
    c.lwsp a2, 4(sp)
    c.bnez a0, loop
