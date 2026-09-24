# isa

`isa` is a Zig library that decodes, executes, and disassembles the instruction sets of small
embedded cores:

- Arm T32 from Armv6-M through Armv8.1-M with the Main Extension, including the DSP,
  floating-point, and MVE extensions.
- RISC-V RV32I through RV32IMAFC with Zicsr.

The library is checked against:

- llvm-objdump,
- QEMU,
- the Sail RISC-V model,
- and a corpus of 49 firmware images in a [container](Dockerfile) pinned by digest.

## Key features

1. **Generated decoder.** Every instruction is one row in `spec/*/*.zon` with:

   - a name,
   - an encoding diagram,
   - a group name,
   - and the assembly text.

   The generator proves that no two rows of the same length can match the same instruction
   and that the emitted decision tree answers exactly what a scan over the table answers. A
   row that is missing, ambiguous, or unreachable is a build failure, not a runtime surprise.

2. **Compile-time checked contract.** The library reaches memory through three functions and
   asks its host a [fixed list of questions](src/contract.zig). Each question is a named
   requirement with its signature and the reason a row asks it. A host that misses one fails
   to compile with that reason in the message. There is no hidden global state.

3. **Runtime group-set selection.** A single generated tree per architecture
   carries every row. Each row belongs to a group (`v6m`, `main`, `dsp`, `mve` and so on
   for Arm; `rv32i`, `m`, `a`, `c`, `zicsr`, `f` for RISC-V), and every execute call takes the
   set of groups the core implements. An instruction outside the set is UNDEFINED on Arm and
   illegal on RISC-V, except that the base group every preset shares (`v6m`, `rv32i`) is never
   gated: its rows execute whatever the set says. See
   [`allow_at_runtime.zig`](examples/allow_at_runtime.zig).

## Examples

Each file under [`examples/`](examples/) is a test that `zig build examples` runs.

- [`execute_arm.zig`](examples/execute_arm.zig): `movs r0, #1` on the Armv7-M reference
  host.
- [`execute_riscv.zig`](examples/execute_riscv.zig): the same operation, `addi a0, zero, 1`,
  on the RV32 reference host.
- [`disassemble.zig`](examples/disassemble.zig): the same two instructions as text.
- [`allow_at_runtime.zig`](examples/allow_at_runtime.zig): `udiv` refused by the Cortex-M0
  group set and accepted by the Cortex-M4 one; `mul` refused by RV32I and accepted by RV32IM.
- [`arm_processors.zig`](examples/arm_processors.zig): the group set of every supported
  Cortex-M, from its Technical Reference Manual, checked against one instruction per group.
- [`riscv_processors.zig`](examples/riscv_processors.zig): the group sets of the ESP32-C3, C6
  and P4, checked the same way, and the CSR implementation of each part.
- [`step_loop.zig`](examples/step_loop.zig): the step loop with a cost table, on both
  architectures, running to a breakpoint.
- [`host_contract.zig`](examples/host_contract.zig): a host that wraps the reference one and
  changes one answer, checked against the contract at compile time.
- [`row_name.zig`](examples/row_name.zig): a code to its row index and spec name.

The groups of both architectures, their contents and the processors each belongs to are
tabled in [INTERFACE.md](INTERFACE.md).

## Building

Requires Zig 0.16.0 and nothing else. The library is built for 64-bit host machines and
fails to compile on 32-bit targets, so it is not meant to run on an MCU.

```sh
zig build test        # unit, spec and example tests
zig build examples    # the examples alone
```

The oracle comparisons, the firmware corpus and the timing bench need llvm-objdump, QEMU and
the Sail RISC-V model. The corpus and the timing loops are cross-compiled by `zig cc`, so no
other toolchain is needed. They run in a container image pinned by digest:

```sh
docker build -t isa .
docker run --rm isa    # zig build harness && zig build metrics
```

`zig build metrics` prints one row: every correctness gate, the nanoseconds per instruction
over the corpus, the object size of the library and the build times.

## Documentation

- [INTERFACE.md](INTERFACE.md): how to embed the library. State, the host contract, the
  generated entry points, the step loop, outcomes and disassembly.
- [DESIGN.md](DESIGN.md): how it is built. The row table, the generator and its two proofs,
  group gating, the semantic layers, the verification layers and the bench.

## Layout

| Path | What |
|---|---|
| `spec/` | The instruction tables, one `.zon` file per extension, and the checker |
| `src/gen/` | The generator: proofs, tree, emitters |
| `src/arm/`, `src/riscv/` | State, architecture, CSRs, step loop |
| `src/sem/` | The semantic handlers each row dispatches to |
| `src/host/` | Reference hosts over a flat memory, used by the tests and the bench |
| `src/contract.zig` | The host requirement lists and the compile-time check |
| `test/` | The unit tests, mirroring `src/`, rooted at `tests.zig` |
| `bench/` | The measurement harness, the consumer programs it drives and the timing loops |
| `corpus/` | Firmware image sources and the pinned manifest |
| `oracle/` | Pinned reference outputs and the scripts that regenerate them |
