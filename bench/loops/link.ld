/* Layout for the loop images: one flash region at zero with the vectors first, and a stack symbol
   at 2 MiB that the RISC-V loops load into sp. */
MEMORY { flash (rx) : ORIGIN = 0x00000000, LENGTH = 1M }
_stack = 0x00200000;
SECTIONS { .text : { KEEP(*(.vectors)) *(.text*) } > flash }
