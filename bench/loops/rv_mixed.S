/* The RISC-V counterpart of the ARM five-instruction loop in uncompressed encodings: addi, add,
   sw, lw and bne. */
    .option norvc
    .section .vectors, "a"
    .globl _start
_start:
    lui  sp, %hi(_stack)
    addi sp, sp, %lo(_stack)
loop:
    addi a0, zero, 1
    add  a1, a0, a0
    sw   a1, 4(sp)
    lw   a2, 4(sp)
    bne  a0, zero, loop
