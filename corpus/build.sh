#!/bin/sh
# Builds every corpus image for both architectures into out/<arch>/<name>.elf with zig: the
# programs in src/, CoreMark, and the Embench suite. CoreMark and Embench are fetched at pinned
# commits into third_party/ rather than vendored. The programs' rounds, ITERATIONS and the Embench
# scale factors are fixed so every image retires the instruction count the manifest pins.
set -eu
cd "$(dirname "$0")"
zig=${ZIG:-zig}
out=out
mkdir -p "$out/arm" "$out/armv6m" "$out/riscv"

arm_flags="--target=thumb-freestanding-eabi -mcpu=cortex_m3"
armv6m_flags="--target=thumb-freestanding-eabi -mcpu=cortex_m0plus"
riscv_flags="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c"
riscv_f_flags="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c+f"
common="-Os -g0 -ffreestanding -nostdlib -fno-sanitize=undefined -fno-builtin -Wall"
zig_common="-O ReleaseSmall -fno-builtin -fsingle-threaded -fstrip -fno-unwind-tables"

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
# script and port.zig. Each Zig source is compiled to an object under out/obj/<arch>/ first.
build() {
    arch=$1; name=$2; shift 2
    runtime=
    case $arch in
        arm)    flags="$arm_flags";    target="-target thumb-freestanding-eabi -mcpu cortex_m3";            port=port/arm;   out_arch=arm ;;
        armv6m) flags="$armv6m_flags"; target="-target thumb-freestanding-eabi -mcpu cortex_m0plus";        port=port/arm;   out_arch=armv6m; runtime=-rtlib=compiler-rt ;;
        riscv)  flags="$riscv_flags";  target="-target riscv32-freestanding-none -mcpu generic_rv32+m+c";   port=port/riscv; out_arch=riscv ;;
        riscvf) flags="$riscv_f_flags"; target="-target riscv32-freestanding-none -mcpu generic_rv32+m+c+f"; port=port/riscv; out_arch=riscv ;;
    esac
    mkdir -p "$out/obj/$arch"
    set -- port/port.zig "$@"
    for source; do
        shift
        case $source in
            *.zig)
                object="$out/obj/$arch/$(basename "$source" .zig).o"
                $zig build-obj $target $zig_common -femit-bin="$object" "$source"
                set -- "$@" "$object" ;;
            *) set -- "$@" "$source" ;;
        esac
    done
    $zig cc $flags $common $runtime -T "$port/link.ld" -o "$out/$out_arch/$name.elf" "$port/start.S" "$@"
}

for arch in arm armv6m riscv; do
    build "$arch" crc32   src/crc32.zig
    build "$arch" sort    src/sort.zig
    build "$arch" memops  src/memops.zig
    build "$arch" branchy src/branchy.zig
done
build arm   smc src/smc_arm.zig
build armv6m smc src/smc_arm.zig
build riscv smc src/smc_riscv.zig
build riscvf floats src/floats.zig

cm="-I$coremark -I$coremark/barebones -Iport -DITERATIONS=570 -DMAIN_HAS_NOARGC=1 \
    -DCLOCKS_PER_SEC=1000 -DHAS_FLOAT=0 -DHAS_PRINTF=0 -DFLAGS_STR=\"-Os\" -DMEM_LOCATION=\"STACK\" -DPERFORMANCE_RUN=1"
cm_src="$coremark/core_main.c $coremark/core_list_join.c $coremark/core_matrix.c \
        $coremark/core_state.c $coremark/core_util.c $coremark/barebones/core_portme.c \
        $coremark/barebones/ee_printf.c"
for arch in arm armv6m riscv; do build "$arch" coremark $cm $cm_src; done

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
    for arch in arm armv6m riscv; do
        build "$arch" "eb_$bench" $eb -DGLOBAL_SCALE_FACTOR=$gsf -I"$d" port/embench.zig port/libc.zig \
            "$embench/support/beebsc.c" "$d"*.c
    done
done

ls -l "$out"/arm "$out"/armv6m "$out"/riscv
