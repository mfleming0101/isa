# oracle

Pinned reference outputs the bench compares against, so `zig build metrics` can run its
differentials without llvm, QEMU or Sail installed.

`disasm_*.txt` and `trace_*.txt` are written by `mkref.py` and `mktrace.py`. Both refuse to
regenerate when the installed tool differs from the version recorded in the file's header; the
matching versions are the ones [Dockerfile](../Dockerfile) installs.

`sweep_*.txt` has no generator script. It is the library's own decode of the whole encoding space,
one FNV hash per 65536 codes, so re-pinning it accepts whatever the decoder now does rather than
checking it against anything. Regenerate only when a decode change is intended, from the repository
root:

    zig build bench
    ./zig-out/bin/consumer-arm   sweep 0 65536 | grep -v '^holes=' > oracle/sweep_arm.txt
    ./zig-out/bin/consumer-riscv sweep 0 65536 | grep -v '^holes=' > oracle/sweep_riscv.txt
