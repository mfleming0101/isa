/* The wide-encoding loop: a 32-bit bl to itself, so the wide decode path carries the whole cost. */
    .syntax unified
    .thumb
    .section .vectors, "a"
    .word _stack
    .word _start + 1
    .text
    .thumb_func
    .global _start
_start:
1:  bl 1b
