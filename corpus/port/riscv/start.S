/* Reset code for the RISC-V images: _start sets the stack, zeroes .bss, calls main, then calls
   console_crc so the CRC sits in a0 at bench_exit's ebreak. The harness stops the run there and
   reads a0 as the checksum. */
    .section .vectors, "ax"
    .global _start
_start:
    la sp, _stack
    la t0, _bss_start
    la t1, _bss_end
1:  beq t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call main
    call console_crc
    .global bench_exit
bench_exit:
    ebreak
    j bench_exit
