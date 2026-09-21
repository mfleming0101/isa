#!/usr/bin/env python3
"""Pins an oracle's architectural state as one hash per window of retired instructions into
oracle/trace_<arch>.txt, so the bench can run lockstep without Sail or QEMU installed. Sail is the
oracle for RV32, QEMU with -M mps2-an385 for ARMv7-M. A full trace is gigabytes, so each window of
65536 records is hashed and any disagreement localises to one window to replay. The record is
`consumer trace`'s line without its retired count: pc, flags, then the 32 registers, with record i
taking the oracle's registers after step i and its pc from step i+1."""

import argparse, pathlib, re, subprocess, sys

WINDOW = 1 << 16
PRIME = 0x100000001B3
SEED = 0xCBF29CE484222325
MASK = (1 << 64) - 1

def fold(hash, record):
    for byte in record.encode():
        hash = ((hash ^ byte) * PRIME) & MASK
    return ((hash ^ 0xFF) * PRIME) & MASK
STEP = re.compile(r"^\[(\d+)\] \[[A-Z]+\]: 0x([0-9A-Fa-f]{8}) \(0x[0-9A-Fa-f]+\)")
WRITE = re.compile(r"^x(\d+) <- 0x([0-9A-Fa-f]+)")

def records(elf, limit, config):
    """Yields Sail's steps as `consumer trace` lines, reconstructing the register file from its write
    events."""
    child = subprocess.Popen(
        ["sail_riscv_sim", "--rv32", "--config-override", config, "--inst-limit", str(limit + 1),
         "--trace-instr", "--trace-gpr", "--trace-output", "/dev/stdout", str(elf)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1 << 20)
    regs = [0] * 32
    pending = None
    for line in child.stdout:
        step = STEP.match(line)
        if step:
            if pending is not None:
                yield "%08x %08x %s" % (int(step.group(2), 16), 0, " ".join("%08x" % r for r in regs))
            pending = True
            continue
        write = WRITE.match(line)
        if write and pending is not None:
            regs[int(write.group(1))] = int(write.group(2), 16) & 0xFFFFFFFF
    child.stdout.close()
    child.wait()

def arm_records(elf, limit, _config):
    """Yields QEMU's per-instruction register dumps as `consumer trace` lines, dropping the reset
    state."""
    child = subprocess.Popen(
        ["qemu-system-arm", "-M", "mps2-an385", "-cpu", "cortex-m3", "-kernel", str(elf),
         "-nographic", "-monitor", "none", "-serial", "none",
         "-accel", "tcg,one-insn-per-tb=on", "-d", "cpu", "-D", "/dev/stdout"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1 << 20)
    regs = [0] * 16
    tail = " ".join(["00000000"] * 16)
    emitted = 0
    seen = False
    for line in child.stdout:
        if line[0] == "R":
            for at in (0, 13, 26, 39):
                regs[int(line[at + 1:at + 3])] = int(line[at + 4:at + 12], 16)
            continue
        if not line.startswith("XPSR="):
            continue
        if seen:
            yield "%08x %08x %s %s" % (regs[15], int(line[5:13], 16),
                                       " ".join("%08x" % r for r in regs), tail)
            emitted += 1
            if emitted >= limit:
                break
        seen = True
    child.kill()
    child.stdout.close()

ORACLES = {
    "riscv": ("sail_riscv_sim", records),
    "arm": ("qemu-system-arm", arm_records),
}

def version(tool):
    return subprocess.run([tool, "--version"], capture_output=True, text=True).stdout.splitlines()[0].strip()

def pinned(path):
    return path.read_text().splitlines()[0] if path.exists() else None

def mismatch(path, header):
    have = pinned(path)
    if have is None or have == header:
        return False
    print(f"{path.name}: pinned with '{have[2:]}', installed is '{header[2:]}'", file=sys.stderr)
    return True

def main():
    """Hashes each image's trace per window into the oracle trace files, refusing a changed oracle unless --retool is given."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=sorted(ORACLES), action="append", help="default: both")
    ap.add_argument("--records", type=int, default=0, help="print raw records instead of hashes")
    ap.add_argument("--limit", type=int, default=20_000_000, help="cap retired instructions per image")
    ap.add_argument("--check", action="store_true", help="only compare installed oracle versions to the pinned files")
    ap.add_argument("--retool", action="store_true", help="regenerate even though the oracle version changed")
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    config = str(root / "oracle/sail_rv32.json")
    manifest = (root / "corpus/manifest.zon").read_text()

    drift = False
    for arch in args.arch or sorted(ORACLES):
        tool, _ = ORACLES[arch]
        drift |= mismatch(root / f"oracle/trace_{arch}.txt", f"# {tool} {version(tool)}")
    if args.check:
        return 1 if drift else 0
    if drift and not args.retool:
        print("refusing to regenerate against a different oracle; pass --retool to accept the new version", file=sys.stderr)
        return 1

    for arch in args.arch or sorted(ORACLES):
        tool, source = ORACLES[arch]
        entries = re.findall(
            r'\.name = "([\w-]+)", \.arch = "%s", \.path = "([^"]+)", \.retired = (\d+)' % arch, manifest)
        if args.records:
            for record in source(root / "corpus" / entries[0][1], args.records, config):
                print(record)
            continue

        out = [f"# {tool} {version(tool)}"]
        for name, path, retired in entries:
            retired = min(int(retired), args.limit) if args.limit else int(retired)
            digest, windows, count = SEED, [], 0
            for record in source(root / "corpus" / path, retired, config):
                digest = fold(digest, record)
                count += 1
                if count % WINDOW == 0:
                    windows.append("%016x" % digest)
                    digest = SEED
            if count % WINDOW:
                windows.append("%016x" % digest)
            out.append(f"# {name} {count}")
            out += [f"{name} {i} {h}" for i, h in enumerate(windows)]
            print(f"{arch} {name}: {count} records, {len(windows)} windows", file=sys.stderr)
        (root / f"oracle/trace_{arch}.txt").write_text("\n".join(out) + "\n")

if __name__ == "__main__":
    sys.exit(main())
