/* Layout for the ARM images: 1 MiB of flash at zero holding the vectors, code and initialised
   data, 1 MiB of RAM at 2 MiB holding .bss, with the stack at the top of RAM. Both fit inside the
   harness's flat 16 MiB memory. */
MEMORY {
    flash (rx) : ORIGIN = 0x00000000, LENGTH = 1M
    ram (rw)   : ORIGIN = 0x00200000, LENGTH = 1M
}
_stack = ORIGIN(ram) + LENGTH(ram);
SECTIONS {
    .text   : { KEEP(*(.vectors)) *(.text*) } > flash
    .rodata : { *(.rodata*) } > flash
    .data : { *(.data*) } > flash
    .bss  : { . = ALIGN(4); _bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > ram
}
