/* Reset code for the ARM images: the vector table holds the stack top and entry, _start zeroes
   .bss, calls main, then calls console_crc so the CRC sits in r0 at bench_exit's breakpoint. The
   harness stops the run there and reads r0 as the checksum. */
    .syntax unified
    .thumb
    .section .vectors, "a"
    .word _stack
    .word _start

    .text
    .thumb_func
    .global _start
_start:
    ldr r0, =_stack
    mov sp, r0
    ldr r0, =_bss_start
    ldr r1, =_bss_end
    movs r2, #0
1:  cmp r0, r1
    beq 2f
    str r2, [r0]
    adds r0, #4
    b 1b
2:  bl main
    bl console_crc
    .thumb_func
    .global bench_exit
bench_exit:
    bkpt #0
    b bench_exit
