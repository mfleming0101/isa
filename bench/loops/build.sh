#!/bin/sh
# Assembles the five diagnostic loop images the loop_ns_* columns are timed on. Assembled rather
# than compiled because those columns only mean anything if the instruction sequence is exact.
set -eu
cd "$(dirname "$0")"
zig=${ZIG:-zig}
build() {
    case $1 in
        arm)   t="--target=thumb-freestanding-eabi -mcpu=cortex_m3" ;;
        riscv) t="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c" ;;
    esac
    $zig cc $t -nostdlib -ffreestanding -g0 -T link.ld -Wl,--entry=_start -Wl,-z,max-page-size=4 -o "$2.elf" "$2.S"
}
build arm   arm_bdot
build arm   arm_mixed
build arm   arm_bl
build riscv rv_mixed
build riscv rv_c
