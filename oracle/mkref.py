#!/usr/bin/env python3
"""Pins llvm-objdump's rendering of every corpus instruction into oracle/disasm_<arch>.txt, so the
bench can run its disassembly differential without llvm installed and the reference cannot drift
under a comparison. One line per instruction: code, pc, kind, text. The code is what `consumer
disasm` reads, so Thumb-32 is hw1<<16|hw2. Only llvm's output shape is removed here; the kind
marks lines the bench must not require to match. Semantic normalisation belongs to
bench/harness/oracle.zig."""

import argparse, re, subprocess, sys, pathlib

OBJDUMP = "llvm-objdump-19"
FLAGS = {
    "riscv": ["--triple=riscv32", "--mattr=+m,+c", "-M", "no-aliases", "--no-print-imm-hex"],
    "arm": ["--triple=thumbv7m-none-eabi", "--no-print-imm-hex"],
}
LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f ]*?)\s*\t(.*)$")

def instructions(arch, elf):
    """Yields (code, pc, text) for every instruction llvm-objdump finds in the ELF, with symbols and
    comments stripped."""
    out = subprocess.run([OBJDUMP, "-d"] + FLAGS[arch] + [str(elf)], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        halves = m.group(2).split()
        if not halves:
            continue
        text = re.split(r"\s*@\s", m.group(3))[0]
        text = text.replace("<unknown>", "undefined")
        if text in ("c.unimp", "unimp"):
            text = "undefined"
        text = re.sub(r"\s*<[^>]*>", "", text)
        text = re.sub(r"\s+", " ", text.replace("\t", " ")).strip()
        code = halves[0] + halves[1] if arch == "arm" and len(halves) == 2 else "".join(halves)
        yield code, int(m.group(1), 16), text

IT = re.compile(r"^it[te]{0,3}(\s|$)")

OUT_OF_SCOPE = ("csr", "stc", "ldc", "mcr", "mrc", "mcrr", "mrrc", "cdp")

def unauthoritative(arch, code, mnemonic):
    """Names the reason llvm's text cannot be required: reserved RV32C codes, UNPREDICTABLE BX/BLX,
    C.LUI and fence conventions."""
    value = int(code, 16)
    if arch == "riscv" and len(code) == 4 and value & 0xE003 == 0x0002 and value & 0x1000:
        return "skip-rv64leak"
    if arch == "arm" and len(code) == 4 and value & 0xFF00 == 0x4700 and value & 0x0007:
        return "skip-unpredictable"
    if mnemonic == "c.lui":
        return "skip-immediate-convention"
    if mnemonic == "fence":
        return "skip-fence-operands"
    return None

def kinds(arch, rows):
    """Tags each line ok, skip-itblock, skip-outofscope or an unauthoritative reason, so the bench
    knows which to compare."""
    covered = 0
    for code, pc, text in rows:
        mnemonic = text.split()[0] if text else ""
        if covered:
            covered -= 1
            yield code, pc, "skip-itblock", text
            continue
        if IT.match(text):
            covered = len(mnemonic) - 1
        if mnemonic.startswith(OUT_OF_SCOPE):
            yield code, pc, "skip-outofscope", text
            continue
        yield code, pc, unauthoritative(arch, code, mnemonic) or "ok", text

def version():
    return subprocess.run([OBJDUMP, "--version"], capture_output=True, text=True).stdout.splitlines()[0].strip()

def mismatch(path, header):
    if not path.exists():
        return False
    have = path.read_text().splitlines()[0]
    if have == header:
        return False
    print(f"{path.name}: pinned with '{have[2:]}', installed is '{header[2:]}'", file=sys.stderr)
    return True

def main():
    """Writes both disasm files over every corpus image, refusing a changed objdump unless --retool is given."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="only compare the installed objdump version to the pinned files")
    ap.add_argument("--retool", action="store_true", help="regenerate even though the objdump version changed")
    args = ap.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    header = f"# {OBJDUMP} {version()}"
    drift = any([mismatch(root / f"oracle/disasm_{arch}.txt", header) for arch in ("arm", "riscv")])
    if args.check:
        return 1 if drift else 0
    if drift and not args.retool:
        print("refusing to regenerate against a different objdump; pass --retool to accept the new version", file=sys.stderr)
        return 1
    for arch in ("arm", "riscv"):
        lines = [header]
        for elf in sorted((root / "corpus/out" / arch).glob("*.elf")):
            lines.append(f"# {elf.relative_to(root)}")
            for code, pc, kind, text in kinds(arch, instructions(arch, elf)):
                lines.append(f"{code} {pc:x} {kind} {text}")
        path = root / f"oracle/disasm_{arch}.txt"
        path.write_text("\n".join(lines) + "\n")
        print(f"{path.relative_to(root)}: {sum(1 for l in lines if not l.startswith('#'))} instructions")

if __name__ == "__main__":
    sys.exit(main())
