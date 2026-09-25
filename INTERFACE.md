# Embedding the library

This document is for a reader who wants to put the library inside their own simulator. The
[README](README.md) says what it is; [DESIGN.md](DESIGN.md) says how it is built. Every code
fragment below has a runnable counterpart under [`examples/`](examples/).

Everything is reached through one module:

```zig
const isa = @import("isa");
```

| Export | What |
|---|---|
| `isa.arm`, `isa.riscv` | `State`, `Stop`, the `decode` groups and the `step` loop of each architecture; `Architecture` for Arm, `csr` for RISC-V |
| `isa.generated.arm_decode`, `riscv_decode` | The generated decode tree: `indexNarrow`, `indexWide`, `executeNarrow`, `executeWide` |
| `isa.generated.arm_disasm`, `riscv_disasm` | The generated disassembler: `write(w, code, pc, groups)` |
| `isa.generated.arm_meta`, `riscv_meta` | Row counts and the row name table, indexed like the decoder |
| `isa.contract` | The host requirement lists and `assertHost` |
| `isa.sem.arm`, `isa.sem.riscv` | The handlers the tree dispatches to, and the `Done` type they return |

Each generated module carries every row of its architecture. Which rows a core accepts is
chosen per call with a group set, described below, not with a separate module.

## What you bring

### State

`State` is a plain struct, one per architecture, whose every field defaults to its reset value.

- `isa.arm.State`: r0 to r12, MSP, PSP, LR, PC, xPSR, CONTROL, PRIMASK, BASEPRI and
  FAULTMASK, the security state, the exclusive monitor, the floating-point registers and
  FPSCR, the PAC key registers, VPR, MSPLIM and PSPLIM. xPSR defaults to the T bit of the
  EPSR, which a core must run with: a state whose T bit is clear halts with `not_t32_state`.
- `isa.riscv.State`: x0 to x31, PC, f0 to f31, the CSR file, the privilege mode and the LR/SC
  reservation. The CSR file carries a `csr.Implementation` of the choices the Privileged spec
  leaves open (misa, the id registers, the writable mstatus bits, mtvec modes, mcause width,
  misaligned access policy, the SC.W failure code). The default, `csr.sail`, mirrors the Sail
  configuration the lockstep oracle runs; the ESP32 implementations live in
  [`riscv_processors.zig`](examples/riscv_processors.zig).

### A host

A struct type with the functions in [the host contract](#the-host-contract). The library never
allocates and keeps no global mutable state.

`host/arm.zig` and `host/riscv.zig` are complete hosts over the flat memory that answer every
question with the defaults of a plain core out of reset. They are the `host` module, separate
from the library because nothing in it needs them. Copy one and change the answers, or wrap
one and override a single answer as [`host_contract.zig`](examples/host_contract.zig) does.

### A group set

Every row belongs to a group. Every decode, execute and disassembly call takes a group set, a
bit set with one bit per group, and a row whose group is outside the set is UNDEFINED on Arm
and an illegal instruction on RISC-V. The one exception is the base group every preset shares,
`v6m` on Arm and `rv32i` on RISC-V: the generator emits its rows without a gate, so they execute
even when the set omits the base group. `isa.arm.decode.only` and `isa.riscv.decode.only` build a
set from a list of groups at compile time; `isa.arm.decode.every` and `isa.riscv.decode.every`
hold every group; `isa.arm.decode.selectionOf` gives the selection of a named architecture, its
group set with the xPSR mask. Whether an FPU is fitted, and which version, is not in the set: the
floating-point rows belong to `main`, and `coprocessorEnabled`, `fpv5`, `doublePrecision` and
`halfPrecision` are host answers, as they are on hardware, where an instruction to a disabled
or absent coprocessor raises a NOCP UsageFault.
[`arm_processors.zig`](examples/arm_processors.zig) and
[`riscv_processors.zig`](examples/riscv_processors.zig) give the set of every supported
processor.

| Bit | Group | Rows | Processors |
|---|---|---|---|
| 0 | `v6m` | The Armv6-M T32 set every M-profile core has | all |
| 1 | `v7m` | Divide, exclusives, movw/movt, cbz, b.w: the Armv7-M additions Armv8-M Baseline also carries | M3 onward |
| 2 | `main` | The Main Extension: the 32-bit Thumb-2 set, with the floating-point rows | M3, M4, M7, M33, M55, M85 |
| 3 | `dsp` | DSP Extension | M4, M7, M33 option, M55, M85 |
| 4 | `v8m` | Security Extension and load-acquire/store-release | M23 onward |
| 5 | `v8m_main` | Lazy floating-point context save | M33 onward with FPU |
| 6 | `v8_1m` | Low Overhead Branch extension and the Armv8.1-M system rows | M55, M85 |
| 7 | `mve` | M-Profile Vector Extension | M55, M85 option |

| Bit | Group | Rows | Chips |
|---|---|---|---|
| 0 | `rv32i` | Base integer | all |
| 1 | `m` | Multiply and divide | ESP32-C3, C6, P4 |
| 2 | `a` | Atomics | ESP32-C6, P4 |
| 3 | `c` | Compressed | ESP32-C3, C6, P4 |
| 4 | `zicsr` | CSR access | ESP32-C3, C6, P4 |
| 5 | `f` | Single-precision floating point | ESP32-P4 |

## The host contract

The lists live in [`src/contract.zig`](src/contract.zig). Each entry names a `pub fn` the host
must declare, its signature with `*anyopaque` standing for the host type, whether it is
optional, and the reason a row asks for it.

### Checking a host

```zig
comptime isa.contract.assertHost(Host, &isa.contract.arm_requirements);
```

- A missing function is a compile error that quotes the reason.
- A wrong signature is a compile error that quotes both signatures.

### The span contract

The whole memory interface is three functions, shared by both architectures.

| Function | Signature | Answer |
|---|---|---|
| `span` | `fn (*Host, address: u32, a) []u8` or `[]const u8` | The bytes from `address` to the end of the block the host answers for, or an empty slice for a device, a hole or a refusal |
| `access` | `fn (*Host, address: u32, a, value: u32) !u32` | The access `span` answered short: a device read or write, or the refusal itself as an error |
| `touch` | `fn (*Host, address: u32) void` | The address a lookup was made at, once per lookup, for the fault address registers and traces |

`a` is a comptime access descriptor with `.kind` (`.read`, `.write`, `.fetch`) and `.bytes`, the
size of the access. A load multiple or a two-halfword fetch is one `span` call, so a flat RAM
answers with one slice and pays nothing per word. A host over a read-only image answers
`[]const u8`, which reads and fetches take in place and every write goes through `access`
instead. Faults come back as errors from `access` and reach the caller in the outcome, never
through a flag left on the host.

### Arm questions

Twenty-three more, in two kinds.

- **Configuration**, telling a row what the core in front of it is: `architecture`,
  `security`, `pacbti`, `priorityBits`, `trapsUnaligned`, `trapsDivideByZero`, `mve`,
  `coprocessorEnabled`, `doublePrecision`, `halfPrecision`, `fpv5`, `automaticFpState`,
  `defaultFpscr`, `lazyFpEnabled`, `lazyFpCallee`, `lazyFpFrame`, `treatAsSecure`,
  `nonSecureFpscr`.
- **Notifications**, telling the host something happened that an instruction cannot finish on
  its own: `signal` (a supervisor call, exception return or function return retired, as an
  `isa.arm.step.Signal`), `rearm` (a write reached PRIMASK, BASEPRI or FAULTMASK), `sleep` (WFI
  or WFE asked to halt, as an `isa.arm.step.Wait`), `event` (SEV set the event register),
  `setLazyFp` (a deferred floating-point save was settled).

### RISC-V questions

Five more: `readPmp` and `writePmp` for the PMP registers, which belong to the platform
rather than the hart, and the notifications `rearm` (a write reached mstatus or mie),
`returned` (MRET changed the privilege mode) and `sleep` (WFI). `rearm` asks the same question
on both architectures.

## Executing one instruction

There are two entry points. The generated tree is the lower one and what the bench measures.
The step loop is built on it and adds what a core does around an instruction.

### The generated tree

`executeNarrow` takes a 16-bit code and `executeWide` a 32-bit one; the parameter is named
`code`. The tree dispatches to the row's handler with the operand fields extracted and
returns a `Done`. See [`execute_arm.zig`](examples/execute_arm.zig) and
[`execute_riscv.zig`](examples/execute_riscv.zig).

```zig
pub const Done = packed struct(u16) {
    outcome: Outcome,   // what the row reported
    class: Class,       // the cycle class of the row, for costing
};
```

A code no row of the group set matches answers the default: `undefined` on Arm and `illegal` on
RISC-V.

The caller advances PC on `.next`, leaves it on `.branched`, and stops or takes an exception
on the rest.

| Architecture | Outcomes |
|---|---|
| Arm | `next`, `branched`, `breakpoint`, `data_fault`, `unaligned`, `violation`, `secure`, `divide_by_zero`, `no_coprocessor`, `authentication_failure`, `undefined`, `unimplemented`, `supervisor_call`, `exception_return`, `function_return` |
| RISC-V | `next`, `branched`, `breakpoint`, `environment_call`, `data_fault`, `unaligned`, `unimplemented`, `illegal` |

The tree does not fetch, does not widen a halfword, and does not apply IT block predication
or BTI landing-pad checks. `bench/arm/machine.zig` shows the minimum loop around it: fetch a
halfword, widen when the top five bits say so, execute, advance PC by two or four on `.next`.

### The step loop

`isa.arm.step.step` and `isa.riscv.step.step` do all of that and charge a cycle cost per
class. See [`step_loop.zig`](examples/step_loop.zig).

- The loop takes a `step.Model`: the decoding choice and a cost table with one `Cost` per
  class. On Arm the decoding choice is a `Selection` from `decode.selectionOf(architecture)`,
  carrying the group set and the xPSR bits the loop tests; on RISC-V it is the group set
  itself.
- The second parameter is a comptime group set or `null`. A set given there replaces the
  Model's for decoding and lets the compiler drop every row outside it, which is what a
  build for one fixed core wants; `null` decodes with the Model's set at run time.
- It returns a 64-bit `Result`: the code, its class, the cycles charged, whether
  it branched, and `halt()`, which is null when the instruction retired and otherwise a
  `Stop`. On Arm a fault is a `Stop` such as `data_fault`; on RISC-V it is a `trap` the loop
  has already taken, and `Stop` is only `breakpoint`, `unimplemented` or
  `unrecoverable_trap`.

## Decoding and disassembling without executing

- `indexNarrow(code, groups)` and `indexWide(code, groups)` map a code to its row index under
  the group set, or `undefined_index`; `meta.names[i]` is the row's spec name. See
  [`row_name.zig`](examples/row_name.zig).
- `disasm.write(w, code, pc, groups)` writes the assembler syntax of a code at a PC, with
  the same spelling as llvm-objdump for every word the oracle covers. See
  [`disassemble.zig`](examples/disassemble.zig).

## Classes and costs

Each row carries one cycle class. A `Cost` is `{cycles, taken}`: the loop charges `cycles` and
adds `taken` to a taken branch, saturating at 255. The library has no opinion about what a
class costs on your core; the table is yours.

| Architecture | Classes |
|---|---|
| Arm | `data_processing`, `load`, `store`, `load_multiple`, `store_multiple`, `push`, `pop`, `pop_pc`, `branch`, `branch_link`, `system`, `sleep`, `special_register`, `barrier`, `divide` |
| RISC-V | `data_processing`, `load`, `store`, `branch`, `jump`, `system`, `multiply`, `divide`, `atomic`, `load_reserved` |
