/* The one-instruction loop: a branch to itself. Dispatch and nothing else. */
    .syntax unified
    .thumb
    .section .vectors, "a"
    .word _stack
    .word _start + 1
    .text
    .thumb_func
    .global _start
_start:
1:  b.n 1b
