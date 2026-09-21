#!/bin/sh
# Builds every corpus image for both architectures into out/<arch>/<name>.elf with zig cc: the
# programs in src/, CoreMark, and the Embench suite. CoreMark and Embench are fetched at pinned
# commits into third_party/ rather than vendored. ROUNDS, ITERATIONS and the Embench scale factors
# are fixed so every image retires the instruction count the manifest pins.
set -eu
cd "$(dirname "$0")"
zig=${ZIG:-zig}
out=out
mkdir -p "$out/arm" "$out/riscv"

arm_flags="--target=thumb-freestanding-eabi -mcpu=cortex_m3"
riscv_flags="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c"
riscv_f_flags="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c+f"
common="-Os -g0 -ffreestanding -nostdlib -fno-sanitize=undefined -fno-builtin -Wall"

# Fills CoreMark's three #error stubs: bench_clock as the clock, no board init, printf into the console.
patch_coremark() {
    perl -0pi -e 's{#error \\\n\s*"You must implement a method to measure time[^\n]*\n}{    return bench_clock();\n}s;
                   s{#error \\\n\s*"Call board initialization routines[^\n]*\n}{}s;
                   s{(#include "coremark\.h")}{$1\n#include "port.h"}' "$coremark/barebones/core_portme.c"
    perl -0pi -e 's{#error "You must implement the method uart_send_char[^\n]*\n}{    console_put(c);\n    return;\n}s;
                   s{(#include <coremark\.h>)}{$1\n#include "port.h"}' "$coremark/barebones/ee_printf.c"
    perl -0pi -e 's{(#define CORE_PORTME_H)}{$1\n#include <stddef.h>}' "$coremark/barebones/core_portme.h"
}

coremark=third_party/coremark
if [ ! -d "$coremark" ]; then
    mkdir -p third_party
    curl -sL -o third_party/coremark.tar.gz https://codeload.github.com/eembc/coremark/tar.gz/1f483d5b8316753a742cbf5590caf5bd0a4e4777
    tar -C third_party -xzf third_party/coremark.tar.gz
    mv third_party/coremark-1f483d5b8316753a742cbf5590caf5bd0a4e4777 "$coremark"
    patch_coremark
fi

# Links one image: arch, name, then compiler flags and sources, over the port's start code, linker
# script and port.c.
build() {
    arch=$1; name=$2; shift 2
    case $arch in
        arm)    flags="$arm_flags";    port=port/arm;   out_arch=arm ;;
        riscv)  flags="$riscv_flags";  port=port/riscv; out_arch=riscv ;;
        riscvf) flags="$riscv_f_flags"; port=port/riscv; out_arch=riscv ;;
    esac
    $zig cc $flags $common -T "$port/link.ld" -o "$out/$out_arch/$name.elf" \
        "$port/start.S" port/port.c "$@"
}

for arch in arm riscv; do
    build "$arch" crc32   -DROUNDS=3000  src/crc32.c
    build "$arch" sort    -DROUNDS=1300  src/sort.c
    build "$arch" memops  -DROUNDS=43000 src/memops.c
    build "$arch" branchy -DROUNDS=44000 src/branchy.c
done
build arm   smc -DROUNDS=15000000 src/smc_arm.c
build riscv smc -DROUNDS=15000000 src/smc_riscv.c
build riscvf floats -DROUNDS=510000 src/floats.c

cm="-I$coremark -I$coremark/barebones -Iport -DITERATIONS=570 -DMAIN_HAS_NOARGC=1 \
    -DCLOCKS_PER_SEC=1000 -DHAS_FLOAT=0 -DHAS_PRINTF=0 -DFLAGS_STR=\"-Os\" -DMEM_LOCATION=\"STACK\" -DPERFORMANCE_RUN=1"
cm_src="$coremark/core_main.c $coremark/core_list_join.c $coremark/core_matrix.c \
        $coremark/core_state.c $coremark/core_util.c $coremark/barebones/core_portme.c \
        $coremark/barebones/ee_printf.c"
for arch in arm riscv; do build "$arch" coremark $cm $cm_src; done

embench=third_party/embench-iot
if [ ! -d "$embench" ]; then
    curl -sL -o third_party/embench.tar.gz https://codeload.github.com/embench/embench-iot/tar.gz/09c2ed8c3b7008c95d08b038de4a3f6dc103ed70
    tar -C third_party -xzf third_party/embench.tar.gz
    mv third_party/embench-iot-09c2ed8c3b7008c95d08b038de4a3f6dc103ed70 "$embench"
fi

eb="-I$embench/support -Iport -Iport/libc -DWARMUP_HEAT=1 -DCPU_MHZ=1"
for d in "$embench"/src/*/; do
    bench=$(basename "$d")
    [ "$bench" = wikisort ] && continue
    case $bench in
        nettle-aes)  gsf=75 ;;
        matmult-int) gsf=76 ;;
        *)           gsf=1 ;;
    esac
    for arch in arm riscv; do
        build "$arch" "eb_$bench" $eb -DGLOBAL_SCALE_FACTOR=$gsf -I"$d" port/embench.c port/libc.c \
            "$embench/support/beebsc.c" "$d"*.c
    done
done

ls -l "$out"/arm "$out"/riscv
