/* The five-instruction loop kept instruction for instruction from the original harness so its
   column stays comparable: an immediate move, an add, a store, a load, and the branch back. */
    .syntax unified
    .thumb
    .section .vectors, "a"
    .word _stack
    .word _start + 1
    .text
    .thumb_func
    .global _start
_start:
1:  movs r0, #1
    adds r1, r0, #2
    str  r1, [sp, #4]
    ldr  r2, [sp, #4]
    b.n  1b
