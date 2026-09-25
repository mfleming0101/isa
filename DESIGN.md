# How the library is built

This document is for a reader who wants to change the library or judge its claims. The
[README](README.md) says what it is; [INTERFACE.md](INTERFACE.md) says how to embed it.

The pipeline is short. Instruction tables in `spec/` are loaded by the generator in `src/gen`,
which proves two properties and emits a decode tree per architecture into the build cache. Each
leaf of a tree calls a handler in `src/sem`, which mutates a `State` and talks to the host
through the contract in `src/contract.zig`. Everything under `bench/`, `corpus/` and `oracle/`
measures the result and is not part of the library.

## The row table

`spec/arm/*.zon` and `spec/riscv/*.zon` hold one row per encoding, 1406 Arm and 124 RISC-V:

```zig
.{ .name = "ADD_imm_T1", .group = "v6m", .class = "data_processing", .bits = "0001110iiinnnddd", .text = "adds r{d}, r{n}, #{i}" },
```

| Field | Meaning |
|---|---|
| `name` | The row's identifier and the name of its handler in `src/sem`: on Arm the mnemonic and the manual's encoding label, `MNEMONIC[_form]_Tn`, with a lower-case tag where the spec splits one encoding; on RISC-V `MNEMONIC_<number>` |
| `bits` | The bit diagram, 16 or 32 characters: `0` and `1` are fixed, a letter names an operand field |
| `group` | The decode group that gates the row, one bit of the group set |
| `class` | The cycle class, one entry of the host's cost table |
| `text` | The assembly text, with `{letter}` operands; the disassembler is generated from it |
| `when` | Field values the row forbids because another row claims them |
| `aliases` | Alternative text when a field holds a value, such as `tst.w` for `and.w` with Rd = 15 |

The files are split by extension, so a row's group is visible from its file except for the
floating-point files, whose rows are `main`: an FPU's presence and version are host answers, so
the groups carry no floating-point bit. `spec/check.zig` runs under `zig build test` and holds
the table to four facts: the row count, no two rows of an architecture can match the same code,
no two rows of an architecture share a name, and every pattern character is a fixed bit or a
letter. The table is the only copy: nothing else in the repository lists the encodings.

## The generator

Every build runs `src/gen/main.zig` with an output directory, the preset names and a
shape; the emitted files are reached as modules, never from the source tree. For each target it:

1. **Loads** every row of the target in file order (`spec.zig`). Each becomes a mask and value
   for the fixed bits, one `Field` per letter with its bit positions, and one `Constraint` per
   `when` entry. The file order is the order the generated tables index the rows by.
2. **Proves disjointness** (`prove.disjoint`). For every pair of rows of one width, either
   some fixed bit differs, or one row's constraint forbids the value the other fixes. The first
   pair that fails is reported and the build stops.
3. **Builds a tree** per width (`tree.zig`). Starting from all rows, it picks the longest run
   of bits every remaining candidate fixes, branches on it, and recurses. When no bit is common
   it branches on one bit some candidate fixes. A leaf settles once one row remains with all
   its fixed bits tested. A row with constraints the path has not decided keeps them as guards,
   with the single other row a rejected code falls to.
4. **Proves totality** (`prove.total`). It walks every region the tree carves out, runs a naive
   mask-and-match scan over the same region, and requires the two to agree: the same one row,
   or no row, in both the guarded and the fallback half of a guarded leaf. A hole is reported
   with its known bits and the build stops.
5. **Emits** `<target>_decode.zig` with the tree as nested switches (`emit_decode.zig`),
   `<target>_disasm.zig` with the text renderer (`emit_disasm.zig`) and `<target>_meta.zig` with
   the counts and the name table (`emit_meta.zig`).

The two proofs are what make the table a source of truth. They cost milliseconds at generation
time and nothing at run time.

**Presets.** A preset is a named group set the generator can build a tree for. The default shape
is `union`: one tree per architecture holding every row of every preset, with a row whose group is
outside the smallest preset gated at its leaf by a test of the group set. The `split` shape emits
one tree per preset instead. Arm presets are `v6m`, `v7m`, `v8mbase` and `v81mmain`; RISC-V presets
are `rv32i`, `rv32imc`, `rv32imac` and `rv32imafc`.

**Shape of a leaf.** An execute leaf extracts each operand field from the code with shifts and
masks, calls the handler `sem.<name>(s, host, fields...)` always inlined, and wraps the returned
outcome with the row's class into a `Done`. An index leaf returns the row's number. Both are
plain integer code with no table lookups, so the decoder's working set is the instruction
stream.

## The semantic layers

`src/sem/arm` and `src/sem/riscv` hold the handlers, grouped by kind: `alu`, `mem`, `branch`,
`system`, `dsp`, `fp`, `mve` for Arm and `alu`, `mem`, `branch`, `mul`, `atomic`, `fp`,
`system` for RISC-V. `root.zig` of each maps every spec name to its handler; many rows share
one handler, so `ADD_imm_T1` is `alu.adds` and a family of loads is one comptime function
specialised by width and sign.

A handler receives the state, the host and its operands, and returns an `Outcome`. It reaches
memory only through `src/arm/isa/access.zig` or the RISC-V equivalent, which implement the
span contract: `touch` the address, `span` the span, read or write in place when the span is
long enough, otherwise `access`. Alignment rules and fault outcomes live there once.

The step loops in `src/arm/isa/step.zig` and `src/riscv/isa/step.zig` wrap the tree with what
a core does around an instruction: fetch, halfword widening, IT and BTI conditioning on Arm,
per-class cycle costs, and the `Result` a run loop consumes. The reference hosts in `host/`
answer the whole contract with reset defaults over a flat memory, which is whatever slice the
caller hands it; `host.size` is the 16 MiB the bench allocates. The semantic tests and the
bench run on them.

## What the tests hold

`zig build test` runs 505 tests with no dependency beyond Zig: the spec checks, the generator's
proofs on small tables, per-row vectors for both architectures, state and CSR behaviour, and the
step loops. They take about a minute.

## What the container holds

Everything that compares the library against something outside Zig runs in the image built
from `Dockerfile`. The image is pinned by digest, its apt archive by snapshot date, its
packages by exact version, Zig by SHA-256 and Sail by release. Both oracle scripts refuse to
regenerate a reference when the installed tool's version differs from the one written in the
reference's first line.

| Layer | Oracle | Reference | Gate |
|---|---|---|---|
| Decode sweep | The library itself | `oracle/sweep_*.txt`, one FNV hash per 65536 codes of the high halfword | Bucket hashes equal |
| Disassembly | llvm-objdump 19.1.7 | `oracle/disasm_*.txt`, every decodable code of the corpus, 31359 Arm and 30940 RISC-V lines | Text equal after normalising spelling |
| Lockstep | Sail 0.14 (RV32), QEMU 10.0.13 mps2-an385 (Arm) | `oracle/trace_*.txt`, one hash per 65536 retired instructions of each corpus image | Hashes equal for the whole run |
| Corpus | The programs themselves | `corpus/manifest.zon`: 49 images, each with its retired count and the CRC-32 of its console output at the breakpoint | Count and checksum equal |

The lockstep oracle is Sail under `oracle/sail_rv32.json`, and the default RISC-V CSR
implementation `csr.sail` in `src/riscv/isa/csr.zig` mirrors that configuration, so the library
and the oracle make the same implementation-defined choices.

The corpus is six C programs (`crc32`, `sort`, `memops`, `branchy`, `floats` and a
self-modifying code test), CoreMark and thirteen Embench benchmarks, built for both
architectures by `corpus/build.sh` against pinned upstream commits. The programs the two architectures share agree on the
checksum, which ties two instruction sets and two semantic implementations to one answer.

`zig build metrics` runs every layer and appends one row to `bench/summary.tsv`. The row is
written even when a gate fails, with `status` set to `fail`, so a regression stays visible in
the history. The timing columns come from the `consumer` CLI each architecture ships
(`bench/harness/consumer.zig`), driven by `bench/run.zig`:

| Column | What it measures |
|---|---|
| `fw_ns_per_instr` | Geometric mean over the corpus of wall nanoseconds per retired instruction, best of five runs |
| `decode_only_ns` | Nanoseconds per decode of the codes in the disassembly oracle, without execution |
| `loop_ns_*` | Five hand-written assembly loops in `bench/loops`, isolating branches, mixed ALU, calls and compressed code |
| `obj_text`, `obj_rodata` | Section sizes of an object exporting only `isa_step` and `isa_disasm`, the ISA's footprint alone |
| `cold_build_s` | Wall time of `zig build` from a clean cache |
| `gen_s` | Wall time of one generator run into a scratch directory |
| `host_decls_required` | Entries of the host contract, counted from the requirement lists |
| `rows_implemented`, `rows_total` | From the generated meta; equal, since the tree carries every row |

The row measured at each release is recorded in
[bench/release-metrics.tsv](bench/release-metrics.tsv), written by `zig build metrics -- --release`.
The container prints the row for the machine it runs on, and only rows from the same machine and
Zig compare.

## Sizes

| | Lines |
|---|---|
| Spec rows | 1534 |
| Hand-written Zig under `src/` | 23108 |
| Generated Zig | 103161 |

The generated files are large because every leaf is a fully inlined call with its operand
extraction spelled out. That is the trade the design makes: the table is the source, the tree
is disposable, and every build rebuilds it in seconds.
