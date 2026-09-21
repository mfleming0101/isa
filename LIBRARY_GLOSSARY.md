# Library glossary

This glossary fixes one name per concept for `isa`, the Zig instruction-set library for Armv6-M
through Armv8.1-M T32 and RV32IMACF(Zicsr). It covers the library's own vocabulary first --- rows,
groups, the span contract, outcomes, costs --- and then the Arm and RISC-V terms the library leans
on, with the library's particular use of each. One name per concept: where a word could mean two
things, the entry says which meaning it keeps. Links are relative to the repository root and point
at the declaration where there is a single one.

## Access

The host function the library calls for everything a [span](#span) could not serve in place: a
device read or write, a hole, or the refusal itself, which comes back as an error rather than a
flag left on the host. One of the three [span contract](#span-contract) entries.

`access`, declared as a requirement in
[src/contract.zig#L81](src/contract.zig#L81) and implemented by
[src/host/memory.zig#L27](src/host/memory.zig#L27).

See also: [Span](#span), [Touch](#touch), [Span contract](#span-contract), [Failure](#failure).

## Access descriptor

The comptime record passed to [span](#span) and [access](#access) saying what the memory operation
is: `.kind` is `.read`, `.write` or `.fetch`, and `.bytes` is its size in bytes. It has no declared
type; it is built at each call site as an anonymous struct and consumed as `anytype`, so a host may
ignore it entirely.

The field is `.bytes` rather than `.width` because every `width` parameter in the same files holds
bits, and the two sit on one line: `.{ .kind = .read, .bytes = width / 8 }`.

Built at [src/arm/isa/access.zig#L48](src/arm/isa/access.zig#L48) and
[src/riscv/isa/access.zig#L50](src/riscv/isa/access.zig#L50).

See also: [Span](#span), [Access](#access).

## Alternative

One measured implementation the bench harness drives through the [machine facade](#harness): this
library's Arm machine, its RISC-V machine, or the empty `nullisa` machine. Each writes one
[metrics](#metrics) row under its own name.

`alt` column of [bench/harness/metrics.zig#L9](bench/harness/metrics.zig#L9); the facade is
[bench/harness/facade.zig#L38](bench/harness/facade.zig#L38). The bench prose says "alternative",
never "arm", which belongs to the architecture; the `alt` column keeps its short name.

See also: [Harness](#harness), [Metrics](#metrics), [Variant](#variant).

## Architecture

One M-profile architecture version the library models: `armv6m`, `armv7m`, `armv7em`,
`armv8m_base`, `armv8m_main`, `armv8_1m_main`. An architecture fixes a [group set](#group-set)
through `selectionOf`, and a host reports its own through the `architecture` contract entry. RISC-V
has no equivalent type; a RISC-V core is described by its group set alone.

`Architecture`, [src/arm/isa/architecture.zig#L5](src/arm/isa/architecture.zig#L5).

See also: [Group set](#group-set), [Selection](#selection), [Profile](#profile),
[Preset](#preset).

## Charge

To add cycles to a [cost](#cost), saturating at 255 rather than wrapping the eight-bit `cycles`
field of a [Result](#result). The single shared arithmetic of both step loops.

`charge`, [src/cost.zig#L5](src/cost.zig#L5).

See also: [Cost](#cost), [Class](#class), [Result](#result).

## Class

The cycle class a row belongs to, the only timing property a row carries. It selects one
[cost](#cost) from the host's table and, on RISC-V, also picks the fault code an unaligned access
reports.

`Class`, [src/arm/isa/instruction.zig#L7](src/arm/isa/instruction.zig#L7) and
[src/riscv/isa/instruction.zig#L9](src/riscv/isa/instruction.zig#L9).

See also: [Cost](#cost), [Charge](#charge), [Done](#done).

## Code

The bits of one instruction, 16 or 32 of them, held in a `u32`. It is the parameter name of every
decode, execute and disassembly entry point, and the word this glossary uses in prose for what the
manuals call an instruction word or an encoding.

`code`, the parameter of `indexNarrow`, `indexWide`, `executeNarrow`, `executeWide` and
`disasm.write`.

See also: [Parcel](#parcel), [Narrow and wide](#narrow-and-wide), [Row](#row).

## Constraint

A field value one [row](#row) forbids because another row claims that encoding. Written as a `when`
entry in the spec table, carried into the generator as a `Constraint`, and emitted at a leaf as a
[guard](#guard) with a [fallback](#fallback).

`Constraint`, [src/gen/spec.zig#L28](src/gen/spec.zig#L28); the spec field is `when`.

See also: [Guard](#guard), [Fallback](#fallback), [Row](#row), [Spec](#spec).

## Contract

The list of `pub fn` declarations a host must provide, each with its name, its signature, whether
it is optional, and the reason a row asks for it. `assertHost` checks a host against a list at
compile time and quotes the reason in the error. There are three lists: the [span
contract](#span-contract) shared by both architectures, and one per architecture that extends it.

`Requirement` at [src/contract.zig#L9](src/contract.zig#L9), `assertHost` at
[src/contract.zig#L36](src/contract.zig#L36).

An individual entry is a requirement, in the code and in the prose.

See also: [Host](#host), [Span contract](#span-contract), [Notification](#notification).

## Corpus

The 49 pinned firmware images the library is run against, plus their expected retired counts and
console checksums. Six C programs, CoreMark and thirteen Embench benchmarks, built for both
architectures.

`corpus/manifest.zon`, read through
[bench/harness/corpus.zig#L21](bench/harness/corpus.zig#L21).

See also: [Oracle](#oracle), [Lockstep](#lockstep), [Metrics](#metrics).

## Cost

What one [class](#class) costs a particular core: `cycles` charged always and `taken` added when a
branch is taken. The library has no opinion about the numbers; the table belongs to the host and
lives in the core [model](#model).

`Cost`, [src/arm/isa/instruction.zig#L10](src/arm/isa/instruction.zig#L10) and
[src/riscv/isa/instruction.zig#L12](src/riscv/isa/instruction.zig#L12); the table is
`Model.Costs`.

See also: [Class](#class), [Charge](#charge), [Model](#model).

## Done

What one leaf of the generated [tree](#tree) answers with: the [outcome](#outcome) the row's
handler reported and the row's [class](#class). Sixteen bits, returned by value. Its default is
the answer to a code no [row](#row) of the [group set](#group-set) matches: `undefined` on Arm and
`illegal` on RISC-V, which is why such a code is never silently executed.

`Done`, [src/sem/arm/root.zig#L31](src/sem/arm/root.zig#L31) and
[src/sem/riscv/root.zig#L24](src/sem/riscv/root.zig#L24).

See also: [Outcome](#outcome), [Result](#result), [Group set](#group-set).

## EPSR and the T bit

The execution part of Arm's `xPSR`. The library stores the whole `xPSR` as one word and reads two
EPSR bits out of it: the T bit, which must be set for the core to be in T32 state, and the B bit,
set after an indirect branch when [PACBTI](#pacbti) is active. `State` defaults `xpsr` to the T
bit; a core started with it clear halts immediately with `not_t32_state`.

`State.flag_t` at [src/arm/isa/state.zig#L41](src/arm/isa/state.zig#L41), `State.flag_b` at
[src/arm/isa/state.zig#L43](src/arm/isa/state.zig#L43).

See also: [IT block](#it-block), [Selection](#selection), [State](#state).

## Escape

The test that a RISC-V [parcel](#parcel) opens a 32-bit instruction rather than a compressed one:
its lowest two bits are `11`. The Arm step loop makes the same decision on the top five bits of the
first halfword. Where a whole [code](#code) is in hand rather than a first parcel, `step.call` and
the disassembler ask the same question of it: `code & 3 == 3` on RISC-V, and on Arm `code > 0xffff`,
since every wide T32 code opens with hw1 at or above `0xe800`.

`escapes`, [src/riscv/isa/decode.zig#L33](src/riscv/isa/decode.zig#L33), with the private Arm
equivalent of the same name at [src/arm/isa/step.zig#L111](src/arm/isa/step.zig#L111).

`fp.overflowed` is the unrelated overflow flag for an out-of-range exact result.

See also: [Parcel](#parcel), [Narrow and wide](#narrow-and-wide).

## Exclusive monitor

The single-core reservation LDREX/STREX on Arm and LR.W/SC.W on RISC-V set and test. The library
keeps one optional address: in `State.exclusive` for Arm, and in the reference memory's `monitor`
for the shared flat store.

`State.exclusive` at [src/arm/isa/state.zig#L20](src/arm/isa/state.zig#L20), `Memory.monitor` at
[src/host/memory.zig#L36](src/host/memory.zig#L36).

See also: [Host](#host), [Class](#class).

## Extension

An optional part of an instruction set: Arm's Main, DSP, Security, PACBTI, MVE and floating-point
extensions, and RISC-V's M, A, C, F and Zicsr. In this library every extension but Arm's
floating-point one is carried by one or more [groups](#group), and that one is a set of
[host](#host) answers; there is no separate extension type.

The group enums are [src/arm/isa/decode.zig#L8](src/arm/isa/decode.zig#L8) and
[src/riscv/isa/decode.zig#L6](src/riscv/isa/decode.zig#L6).

The `mstatus.FS` field, which is a context status rather than an extension, is
`csr.ContextStatus` at [src/riscv/isa/csr.zig#L102](src/riscv/isa/csr.zig#L102).

See also: [Group](#group), [Main Extension](#main-extension), [Security
Extension](#security-extension), [Zicsr](#zicsr).

## Failure

The error set an [access](#access) can raise: `DataFault` and `Unaligned` on both architectures,
plus `Violation` and `Secure` on Arm. A failure becomes an [outcome](#outcome) through
`Outcome.faulted`, so a fault always reaches the caller in the answer and never as a flag left on
the host.

`Failure`, [src/arm/isa/instruction.zig#L45](src/arm/isa/instruction.zig#L45) and
[src/riscv/isa/instruction.zig#L38](src/riscv/isa/instruction.zig#L38).

See also: [Outcome](#outcome), [Access](#access), [Trap](#trap).

## Fallback

The one other [row](#row) a code takes when a [guard](#guard) at a leaf rejects it. The generator
proves that a guarded leaf and its fallback together answer exactly what a scan over the same
region answers.

`Leaf.fallback`, [src/gen/tree.zig#L19](src/gen/tree.zig#L19).

See also: [Guard](#guard), [Constraint](#constraint), [Leaf](#leaf), [Tree](#tree).

## FPv5

The Armv8-M floating-point version that adds the directed-rounding and selection instructions
(`VRINT*`, `VSEL`, `VMAXNM`/`VMINNM`) to FPv4. The library carries them in the `main`
[group](#group) with every other floating-point row and asks the host `fpv5()` before executing
one, because whether the unit in front of the core is an FPv5 one is a property of the unit
rather than of the selected architecture.

Requirement at [src/contract.zig#L110](src/contract.zig#L110).

See also: [Group](#group), [Lazy floating-point context save](#lazy-floating-point-context-save).

## Gate

The test of one [group](#group) bit at a leaf of the generated [tree](#tree), which is how one tree
carries every row yet answers only for the rows the caller's [group set](#group-set) allows. Not to
be confused with a [guard](#guard), which tests an operand field.

Emitted by [src/gen/emit_decode.zig](src/gen/emit_decode.zig); the per-row bits are the `gates`
slice in [src/gen/main.zig#L90](src/gen/main.zig#L90).

The bench uses "gate" for a third thing, a correctness column a [metrics](#metrics) row must hold;
that use is confined to `bench/`.

See also: [Guard](#guard), [Group set](#group-set), [Leaf](#leaf).

## Generated

Emitted by `src/gen` into the build cache on every build and reached only as a module, never from
the source tree. Three files per architecture: `*_decode.zig` (the [tree](#tree)),
`*_disasm.zig` (the disassembler) and `*_meta.zig` (row counts and the name table).

`isa.generated`, [src/root.zig#L31](src/root.zig#L31).

See also: [Tree](#tree), [Spec](#spec), [Index](#index), [Row name](#row-name).

## Group

The unit of instruction-set selection: every [row](#row) names exactly one, and a core takes or
leaves a group whole. Arm has eight (`v6m`, `v7m`, `main`, `dsp`, `v8m`, `v8m_main`, `v8_1m`,
`mve`); RISC-V has six (`rv32i`, `m`, `a`, `c`, `zicsr`, `f`).

`Group`, [src/arm/isa/decode.zig#L8](src/arm/isa/decode.zig#L8) and
[src/riscv/isa/decode.zig#L6](src/riscv/isa/decode.zig#L6); the spec field is `group`.

`csr.Protection.group` is an unrelated PMP configuration-register index; that use is local to
`src/riscv/isa/csr.zig`.

See also: [Group set](#group-set), [Extension](#extension), [Gate](#gate), [Row](#row).

## Group set

The bit set of [groups](#group) a core implements, one bit per group, passed to every index,
execute and disassembly call. A row whose group is outside the set answers `undefined` on Arm and
`illegal` on RISC-V. Whether a floating-point unit is fitted, and which version, is outside the
set: those rows are `main` and the unit is a [host](#host) answer, as it is on hardware, where a
disabled or absent coprocessor raises a NOCP UsageFault.

`Groups` with the comptime builder `only`, [src/arm/isa/decode.zig#L20](src/arm/isa/decode.zig#L20)
and [src/riscv/isa/decode.zig#L16](src/riscv/isa/decode.zig#L16), and `every`, the word holding
every group of an architecture, at [src/arm/isa/decode.zig#L32](src/arm/isa/decode.zig#L32) and
[src/riscv/isa/decode.zig#L28](src/riscv/isa/decode.zig#L28). The generated decoder's parameter is
`allowed` and the generated disassembler's is `groups`.

The prose says "group set" everywhere, never "groups word", "allowed word" or "profile word". The
identifiers `Groups`, `allowed` and `groups` keep their names.

See also: [Group](#group), [Selection](#selection), [Preset](#preset), [Gate](#gate).

## Guard

The test of a [constraint](#constraint) at a leaf of the generated [tree](#tree): the forbidden
field value is checked first and a rejected code takes the [fallback](#fallback) row.

`Leaf.guards`, [src/gen/tree.zig#L19](src/gen/tree.zig#L19).

The word means only this. The `xPSR` bit mask the step loop tests before its fast path is
`Selection.xpsr_mask` ([src/arm/isa/decode.zig#L53](src/arm/isa/decode.zig#L53)) and the MVE
availability precondition is the private `mve.available`.

See also: [Constraint](#constraint), [Fallback](#fallback), [Gate](#gate),
[Selection](#selection).

## Harness

Everything under `bench/` that measures the library but is not part of it: the machine facade every
[alternative](#alternative) implements, the `consumer` command-line generator, the ELF loader, the
size probe, the trace snapshot format, the [corpus](#corpus) manifest reader and the
[oracle](#oracle) line parser.

[bench/harness/root.zig](bench/harness/root.zig); the facade check is
[bench/harness/facade.zig#L38](bench/harness/facade.zig#L38).

See also: [Alternative](#alternative), [Metrics](#metrics), [Oracle](#oracle),
[Corpus](#corpus).

## Hart

RISC-V's hardware thread: the unit that holds one register file, one program counter and one
privilege mode. The library models exactly one hart, and uses "hart" wherever the RISC-V specs do,
in particular for the CSRs that belong to the hart as against the [PMP](#pmp) registers that belong
to the platform.

`State`, [src/riscv/isa/state.zig](src/riscv/isa/state.zig); the CSR file is
[src/riscv/isa/csr.zig#L119](src/riscv/isa/csr.zig#L119).

See also: [Host](#host), [PMP](#pmp), [Zicsr](#zicsr).

## Host

The caller's simulator, as the library sees it: one struct type satisfying the
[contract](#contract). It answers memory through the [span contract](#span-contract), answers
configuration questions about the core in front of it, and receives
[notifications](#notification). The library never allocates and holds no global mutable state.

The requirement lists are in [src/contract.zig](src/contract.zig); complete reference hosts are
[src/host/arm.zig#L11](src/host/arm.zig#L11) and
[src/host/riscv.zig#L12](src/host/riscv.zig#L12).

The comptime type parameter is `Host` and the value `host`, in `src/sem`, `src/arm`, `src/riscv`
and the generated code alike. The bench calls its own wrapper a "machine" and imports the
reference host as `stub`; those names stay, since a machine is an [alternative](#alternative)
rather than a host.

See also: [Contract](#contract), [Span contract](#span-contract), [Reference
host](#reference-host), [Notification](#notification).

## Index

The number of a [row](#row) in spec file order, which is how the generated tables are indexed.
`indexNarrow` and `indexWide` map a code to its index under the [group set](#group-set) they are
passed, or to `undefined_index` where no row claims it; `meta.names[i]` is that row's
[name](#row-name).

`undefined_index` and the index functions, generated into `<arch>_decode.zig`; emitted by
[src/gen/main.zig#L221](src/gen/main.zig#L221).

The generator's own sentinel for the same value is `tree.undefined_index`
([src/gen/tree.zig#L10](src/gen/tree.zig#L10)).

See also: [Leaf](#leaf), [Row name](#row-name), [Tree](#tree), [Generated](#generated).

## IT block

Arm's If-Then conditional block: up to four instructions predicated by the ITSTATE bits of `xPSR`.
The step loop applies the predication and advances ITSTATE; the generated [tree](#tree) does not,
so a caller using the tree directly handles IT itself.

`State.it_mask` at [src/arm/isa/state.zig#L63](src/arm/isa/state.zig#L63); applied in
[src/arm/isa/step.zig#L99](src/arm/isa/step.zig#L99).

See also: [EPSR and the T bit](#epsr-and-the-t-bit), [Selection](#selection), [Step
loop](#step-loop).

## Lazy floating-point context save

Armv8-M's deferral of the floating-point register push at exception entry until the first
floating-point instruction of the handler. The library does not own the deferral: it asks the host
`lazyFpEnabled` (FPCCR.LSPEN), `lazyFpFrame` (FPCCR.LSPACT with FPCAR) and `lazyFpCallee`, and
tells it `setLazyFp` once a row has settled the outstanding save.

Requirements at [src/contract.zig#L113](src/contract.zig#L113) through
[src/contract.zig#L116](src/contract.zig#L116); the group that carries the rows is `v8m_main`.

See also: [FPv5](#fpv5), [Security Extension](#security-extension),
[Notification](#notification).

## Leaf

The end of a branch of the generated [tree](#tree): either one [row](#row) with all its fixed bits
tested, or nothing. A leaf may carry [guards](#guard) and a [fallback](#fallback), and a
[gate](#gate) on its row's [group](#group).

`Leaf`, [src/gen/tree.zig#L19](src/gen/tree.zig#L19).

See also: [Tree](#tree), [Index](#index), [Guard](#guard), [Gate](#gate).

## Lockstep

Running the library and an external model over the same [corpus](#corpus) image and comparing a
hash of every window of retired instructions. The models are Sail for RV32 and QEMU `mps2-an385`
for Arm.

`oracle/trace_*.txt`, produced by [oracle/mktrace.py](oracle/mktrace.py) and compared in
[bench/run.zig](bench/run.zig).

See also: [Oracle](#oracle), [Corpus](#corpus), [Model](#model).

## Main Extension

Arm's M-profile extension that adds the 32-bit Thumb-2 instruction set. The library carries it as
the `main` [group](#group), and `Architecture.main()` says whether a given architecture has it;
several behaviours (unaligned single access, the reach of an APSR write) turn on the answer.

`Architecture.main`, [src/arm/isa/architecture.zig#L14](src/arm/isa/architecture.zig#L14).

See also: [Architecture](#architecture), [Group](#group), [Extension](#extension).

## Metrics

One row of `bench/summary.tsv`: provenance, every correctness gate, nanoseconds per instruction
over the [corpus](#corpus), object sizes, build times and interface counts. Written even when a
gate fails, with `status` set to `fail`, so a regression stays in the history.

The schema is [bench/harness/metrics.zig#L9](bench/harness/metrics.zig#L9); the driver is
[bench/run.zig](bench/run.zig).

The schema type is `metrics.Summary`, not `Row`, because `bench/run.zig` imports both it and the
spec's [row](#row).

See also: [Harness](#harness), [Alternative](#alternative), [Variant](#variant), [Row](#row).

## misa

The RISC-V CSR reporting the machine XLEN and the extension letters a [hart](#hart) implements. It
is read-only in this library and its value comes from the [CSR model](#model), so a part's own
letters can be modelled without touching the [group set](#group-set) that decides what actually
decodes.

`Model.isa`, [src/riscv/isa/csr.zig#L45](src/riscv/isa/csr.zig#L45).

See also: [Model](#model), [Group set](#group-set), [Zicsr](#zicsr).

## Model

Two distinct records, both currently called `Model`.

The core model is what a core hands the [step loop](#step-loop): its decoding choice --- a
[selection](#selection) on Arm, a [group set](#group-set) on RISC-V --- and one [cost](#cost) per
[class](#class). `step.Model`, [src/arm/isa/step.zig#L70](src/arm/isa/step.zig#L70) and
[src/riscv/isa/step.zig#L74](src/riscv/isa/step.zig#L74).

The CSR model is the set of choices the RISC-V Privileged spec leaves to an implementation:
[misa](#misa), the information registers, the writable `mstatus` bits, the [mtvec](#mtvec) modes,
the `mcause` width, the misaligned-access policy and the SC.W failure code.
[src/riscv/isa/csr.zig#L43](src/riscv/isa/csr.zig#L43).

The CSR one is named `csr.Implementation`, with the field `File.implementation`, so "model" is
left to the core model and to the external models the [lockstep](#lockstep) oracle runs.

See also: [Step loop](#step-loop), [Cost](#cost), [Selection](#selection), [Reference
host](#reference-host).

## mtvec

The RISC-V trap-vector base-address CSR. Which of its MODE values a [hart](#hart) implements and
which BASE bits are writable are implementation choices, so both come from the [CSR
model](#model); the library writes `mtvec` only through those masks.

`Model.tvec_base_mask` and `Model.tvec_modes`,
[src/riscv/isa/csr.zig#L57](src/riscv/isa/csr.zig#L57).

See also: [Model](#model), [Trap](#trap), [Zicsr](#zicsr).

## MVE

Arm's M-Profile Vector Extension (Helium). The library carries it as the `mve` [group](#group) and
also asks the host `mve()`, because whether MVE is fitted decides whether `FPSCR` has an
`LTPSIZE` and therefore whether a low-overhead loop end over a live tail-predicated block is
UNDEFINED.

Requirement at [src/contract.zig#L106](src/contract.zig#L106); the handlers are
[src/sem/arm/mve.zig](src/sem/arm/mve.zig).

See also: [Group](#group), [Extension](#extension), [FPv5](#fpv5).

## Narrow and wide

The library's two instruction widths: narrow is a 16-bit [code](#code) (Arm's 16-bit T32
encodings, RISC-V's compressed encodings) and wide is a 32-bit one. Every decode, index and
execute entry point comes as a narrow and a wide function, and both architectures use the same
pair of words.

`indexNarrow`, `indexWide`, `executeNarrow`, `executeWide`, generated into `<arch>_decode.zig`.

See also: [Code](#code), [Parcel](#parcel), [Escape](#escape).

## Notification

A host requirement the library calls to say something happened that an instruction cannot finish
by itself. Arm has `signal` (a write reached PRIMASK, BASEPRI or FAULTMASK, or a call, exception
return or function return retired), `sleep` (WFE or WFI), `event` (SEV set the event register) and
`setLazyFp`. RISC-V has `rearm` (a write reached `mstatus` or `mie`), `returned` (MRET changed the
privilege mode) and `sleep` (WFI).

Requirements at [src/contract.zig#L89](src/contract.zig#L89) through
[src/contract.zig#L91](src/contract.zig#L91) and
[src/contract.zig#L102](src/contract.zig#L102) through
[src/contract.zig#L105](src/contract.zig#L105), with `setLazyFp` at
[src/contract.zig#L116](src/contract.zig#L116).

The category is "notifications", the enum passed to `signal` is `step.Signal`
([src/arm/isa/step.zig#L26](src/arm/isa/step.zig#L26)) and the one passed to `sleep` is
`step.Wait` ([src/arm/isa/step.zig#L29](src/arm/isa/step.zig#L29)), so that "event" is a value of
`Wait` and the Arm event register that `event()` sets. A write that re-enables interrupts asks
`rearm` on both architectures, which is why `Signal` carries only the three control-flow
notifications.

See also: [Contract](#contract), [Host](#host), [Lazy floating-point context
save](#lazy-floating-point-context-save).

## Oracle

An outside authority the library is compared against, and the pinned file holding its answers:
llvm-objdump for disassembly, Sail and QEMU for [lockstep](#lockstep) traces, and the library's own
earlier answers for the decode sweep. Every reference file names the tool version that produced it
and is refused for regeneration by a different version.

`oracle/`, parsed by [bench/harness/oracle.zig](bench/harness/oracle.zig).

See also: [Lockstep](#lockstep), [Corpus](#corpus), [Metrics](#metrics).

## Outcome

What a [semantic handler](#semantic-handler) reports about executing one row: `next`, `branched`,
or one of the ways it did not retire (`breakpoint`, `data_fault`, `unaligned`, `undefined`,
`illegal` and so on). An outcome is the row's answer; the [step loop](#step-loop) turns it into a
[Stop](#stop) or a [Trap](#trap).

`Outcome`, [src/arm/isa/instruction.zig#L16](src/arm/isa/instruction.zig#L16) and
[src/riscv/isa/instruction.zig#L18](src/riscv/isa/instruction.zig#L18).

See also: [Done](#done), [Stop](#stop), [Trap](#trap), [Failure](#failure).

## PACBTI

Armv8.1-M's Pointer Authentication and Branch Target Identification extension. The library
implements the key registers, the signing and authentication arithmetic and the landing-pad test,
and asks the host `pacbti()`: without the extension the landing-pad bit is never set and the key
registers read as zero.

[src/arm/isa/pac.zig](src/arm/isa/pac.zig); the requirement is
[src/contract.zig#L98](src/contract.zig#L98).

See also: [EPSR and the T bit](#epsr-and-the-t-bit), [Extension](#extension), [Group](#group).

## Parcel

RISC-V's 16-bit instruction fetch unit. A 32-bit instruction is two parcels, and the library's
fetch path answers one parcel at a time while keeping the rest of the [span](#span) it came from,
so the second parcel usually costs no second lookup.

`access.parcel`, [src/riscv/isa/access.zig#L69](src/riscv/isa/access.zig#L69).

The Arm fetch path's equivalent is `access.halfword`
([src/arm/isa/access.zig#L132](src/arm/isa/access.zig#L132)), after Arm's own word for a 16-bit
item.

See also: [Code](#code), [Escape](#escape), [Span](#span).

## PMP

RISC-V's Physical Memory Protection unit. Its `pmpcfg` and `pmpaddr` registers belong to the
platform rather than to the [hart](#hart), so a CSR access to one is routed to the host through
`readPmp` and `writePmp` instead of to the CSR file.

`csr.Protection` at [src/riscv/isa/csr.zig#L233](src/riscv/isa/csr.zig#L233); the requirements are
[src/contract.zig#L87](src/contract.zig#L87) and
[src/contract.zig#L88](src/contract.zig#L88).

See also: [Hart](#hart), [Zicsr](#zicsr), [Host](#host).

## Preset

A named [group set](#group-set) the generator can build a tree for: `v6m`, `v7m`, `v8mbase`,
`v81mmain` for Arm and `rv32i`, `rv32imc`, `rv32imac`, `rv32imafc` for RISC-V. The build names the
presets it wants; their union is the row set the tree carries.

[src/gen/main.zig#L15](src/gen/main.zig#L15).

It is a preset and not a profile, which is Arm's word for a family of architectures; the build
option that names them is `-Dpresets`.

See also: [Group set](#group-set), [Profile](#profile), [Generated](#generated).

## Profile

Arm's own term for a family of architectures: A-profile, R-profile, M-profile. This library
implements M-profile only, and "profile" should mean nothing else in it.

Used in [src/arm/isa/architecture.zig#L1](src/arm/isa/architecture.zig#L1).

See also: [Preset](#preset), [Architecture](#architecture).

## Reference host

One of the two complete hosts the library ships over the flat memory, answering every
[contract](#contract) entry with the defaults of a plain core out of reset. The semantic tests, the
examples and the bench all run on them; a real host is written by copying one or wrapping one.

[src/host/arm.zig#L11](src/host/arm.zig#L11) and
[src/host/riscv.zig#L12](src/host/riscv.zig#L12), over
[src/host/memory.zig#L11](src/host/memory.zig#L11).

The word "reference" also names the pinned [oracle](#oracle) files. The default RISC-V CSR
[implementation](#model) is `csr.sail`, after the model it mirrors, rather than a third
"reference".

See also: [Host](#host), [Model](#model), [Oracle](#oracle).

## Result

What one turn of the [step loop](#step-loop) produced, packed into 64 bits: the [code](#code), its
[class](#class), the cycles charged, whether it branched, and `halt()`, which is null when the
instruction retired and otherwise a [Stop](#stop). The RISC-V one also carries a [Trap](#trap).

`Result`, [src/arm/isa/step.zig#L34](src/arm/isa/step.zig#L34) and
[src/riscv/isa/step.zig#L35](src/riscv/isa/step.zig#L35).

See also: [Step loop](#step-loop), [Stop](#stop), [Trap](#trap), [Done](#done).

## Row

One instruction encoding, and the library's unit of truth: a line of `spec/*/*.zon` with a
[name](#row-name), a bit diagram, a [group](#group), a [class](#class), the assembly text, and
optionally `when` [constraints](#constraint) and aliases. 1406 Arm rows and 124 RISC-V rows. The
table is the only copy of the encodings in the repository.

The schema is [spec/schema.zig](spec/schema.zig); the generator's parsed form is
[src/gen/spec.zig#L64](src/gen/spec.zig#L64).

See also: [Row name](#row-name), [Spec](#spec), [Group](#group), [Class](#class),
[Index](#index).

## Row name

A row's identifier, which is also the name of its [semantic handler](#semantic-handler) and the
string `meta.names[i]` returns. Arm rows use the manual's encoding label, `MNEMONIC[_form]_Tn`
with a lower-case tag where one encoding is split; RISC-V rows use `MNEMONIC_<number>`.

Emitted by [src/gen/emit_meta.zig#L8](src/gen/emit_meta.zig#L8); the handler tables are
[src/sem/arm/root.zig](src/sem/arm/root.zig) and [src/sem/riscv/root.zig](src/sem/riscv/root.zig).

See also: [Row](#row), [Semantic handler](#semantic-handler), [Index](#index).

## Security Extension

Armv8-M's TrustZone extension: Secure and Non-secure states with banked special registers, `SG`,
`TT` and the load-acquire/store-release pairs. The library carries the rows in the `v8m`
[group](#group) and asks the host `security()`, because without the extension the alternate
state's special registers are not addressable at all.

`State.Banked` at [src/arm/isa/state.zig#L66](src/arm/isa/state.zig#L66); the requirement is
[src/contract.zig#L97](src/contract.zig#L97).

See also: [Extension](#extension), [Group](#group), [Lazy floating-point context
save](#lazy-floating-point-context-save).

## Selection

What one Arm [architecture](#architecture) decodes with: the architecture itself, its [group
set](#group-set), and the `xPSR` bit mask the [step loop](#step-loop) tests before taking its fast
path. RISC-V has no selection; its core [model](#model) holds a group set directly.

`Selection` at [src/arm/isa/decode.zig#L50](src/arm/isa/decode.zig#L50), built by `selectionOf` at
[src/arm/isa/decode.zig#L57](src/arm/isa/decode.zig#L57).

"Selection" means this struct and nothing else; a bare bit set is a [group set](#group-set).

See also: [Group set](#group-set), [Architecture](#architecture), [Model](#model),
[Guard](#guard).

## Semantic handler

The function one [row](#row) dispatches to, in `src/sem/arm` or `src/sem/riscv`. It takes the
[state](#state), the [host](#host) and the row's operand fields, mutates the state, reaches memory
only through the [span contract](#span-contract), and returns an [outcome](#outcome). Many rows
share one handler, and a family of rows is often one comptime function specialised by width and
sign.

[src/sem/arm/root.zig](src/sem/arm/root.zig) and
[src/sem/riscv/root.zig](src/sem/riscv/root.zig) map every row name to its handler.

See also: [Row](#row), [Outcome](#outcome), [Host](#host), [Done](#done).

## Span

The bytes a host answers for from a given address onwards, and the name of the host function that
returns them. An empty slice means a device, a hole or a refusal, all of which send the library to
[access](#access). Because a span runs to the end of the block, a load multiple or a two-parcel
fetch is one lookup and a flat RAM pays nothing per word. A host over a read-only image answers
`[]const u8`, which reads and fetches take in place and every write goes through
[access](#access).

`span`, declared as a requirement in [src/contract.zig#L80](src/contract.zig#L80) and implemented
by [src/host/memory.zig#L20](src/host/memory.zig#L20).

See also: [Access](#access), [Touch](#touch), [Span contract](#span-contract), [Access
descriptor](#access-descriptor).

## Span contract

The whole memory interface: three functions, shared by both architectures and by every host.
[Span](#span) answers the bytes in place, [access](#access) serves everything the span answered
short and carries the refusal, and [touch](#touch) records the address a lookup was made at.
Alignment rules and fault outcomes live once, in each architecture's access helpers.

[src/contract.zig#L79](src/contract.zig#L79); the callers are
[src/arm/isa/access.zig](src/arm/isa/access.zig) and
[src/riscv/isa/access.zig](src/riscv/isa/access.zig).

See also: [Span](#span), [Access](#access), [Touch](#touch), [Contract](#contract),
[Failure](#failure).

## Spec

The instruction tables in `spec/arm/*.zon` and `spec/riscv/*.zon`, one file per
[extension](#extension) so a [row](#row)'s group is visible from its path, plus the checker that
holds the table to four facts under `zig build test`: the row count, no two rows of an architecture
matching one code, no two sharing a name, and every pattern character being a fixed bit or a
letter.

[spec/check.zig](spec/check.zig) and [spec/schema.zig](spec/schema.zig).

See also: [Row](#row), [Tree](#tree), [Generated](#generated).

## State

The architectural state of one core, a plain struct with zero defaults and no methods that reach
the [host](#host). Arm: r0-r12, both stack pointers, LR, PC, `xPSR`, CONTROL, the mask registers,
the security state, the [exclusive monitor](#exclusive-monitor), the floating-point registers and
FPSCR, the PAC keys, VPR and the stack limits. RISC-V: x0-x31, PC, f0-f31, the CSR file, the
privilege mode and the LR/SC reservation.

`State`, [src/arm/isa/state.zig#L7](src/arm/isa/state.zig#L7) and
[src/riscv/isa/state.zig](src/riscv/isa/state.zig).

See also: [Host](#host), [EPSR and the T bit](#epsr-and-the-t-bit), [Hart](#hart).

## Step loop

The higher of the two entry points: it fetches, widens a 16-bit [code](#code) to 32 bits where the
prefix says so, applies IT and BTI conditioning on Arm, runs the generated [tree](#tree), charges
the row's [class](#class) and answers a [Result](#result). The tree below it does none of that.

`step`, [src/arm/isa/step.zig#L85](src/arm/isa/step.zig#L85) and
[src/riscv/isa/step.zig#L89](src/riscv/isa/step.zig#L89). Its second parameter is a comptime
[group set](#group-set) or `null`: a set given there replaces the [Model](#model)'s and prunes the
tree to it, which is what a build for one fixed core wants.

`step.call`, the single-code entry a row test drives, takes the [code](#code) as a `u32` and the
[group set](#group-set) as its last parameter, and picks the width by the [escape](#escape) test.

See also: [Result](#result), [Tree](#tree), [Model](#model), [Charge](#charge).

## Stop

Why the core halted instead of retiring an instruction: `breakpoint`, `undefined_instruction`, a
fetch or data fault, and so on. Arm has seventeen; RISC-V has three, because everything else is a
[Trap](#trap) the loop has already taken. The bench has a third, deliberately small `Stop` that
crosses the machine facade.

[src/arm/isa/step.zig#L23](src/arm/isa/step.zig#L23),
[src/riscv/isa/step.zig#L24](src/riscv/isa/step.zig#L24) and
[bench/harness/snapshot.zig#L16](bench/harness/snapshot.zig#L16).

See also: [Result](#result), [Trap](#trap), [Outcome](#outcome).

## Touch

The host function told the address a lookup was made at, once per lookup rather than once per
word. It is what feeds the fault address registers --- MMFAR and BFAR on Arm, `mtval` on RISC-V ---
and the trace line. It answers nothing.

`touch`, declared as a requirement in [src/contract.zig#L82](src/contract.zig#L82) and implemented
by [src/host/memory.zig#L33](src/host/memory.zig#L33).

See also: [Span](#span), [Access](#access), [Span contract](#span-contract).

## Trap

A RISC-V synchronous exception a row raised and the [step loop](#step-loop) has already taken,
named for what happened rather than for its `mcause` code. Arm has no equivalent: an Arm fault
comes back as a [Stop](#stop) and the host takes the exception.

`Trap` at [src/riscv/isa/step.zig#L27](src/riscv/isa/step.zig#L27); the codes it maps to are
`csr.Cause` at [src/riscv/isa/csr.zig#L91](src/riscv/isa/csr.zig#L91).

See also: [Stop](#stop), [Outcome](#outcome), [mtvec](#mtvec).

## Tree

The generated decision tree, one per architecture per width, carrying every [row](#row) of that
architecture. The generator picks the longest run of bits every remaining candidate fixes,
branches on it, and recurses to a [leaf](#leaf). It proves the rows disjoint before building and
proves the tree total afterwards, against a naive mask-and-match scan; a hole or an ambiguity is a
build failure.

Built by [src/gen/tree.zig#L40](src/gen/tree.zig#L40), proved by
[src/gen/prove.zig](src/gen/prove.zig), emitted by
[src/gen/emit_decode.zig](src/gen/emit_decode.zig).

The generator's record for one architecture is `Architecture`
([src/gen/main.zig#L36](src/gen/main.zig#L36)); "target" is left to the build triple in the
[metrics](#metrics) schema and to the branch destinations in `src/sem`.

See also: [Leaf](#leaf), [Gate](#gate), [Guard](#guard), [Generated](#generated),
[Index](#index).

## Variant

The `key=value` knobs of one bench run, recorded in its own [metrics](#metrics) column so two rows
of the same [alternative](#alternative) measured under different settings stay distinguishable.
Distinct from an alternative, which is a whole implementation.

`validVariant`, [bench/harness/metrics.zig#L72](bench/harness/metrics.zig#L72).

See also: [Alternative](#alternative), [Metrics](#metrics).

## Zicsr

The RISC-V extension for the CSR instructions, carried as the `zicsr` [group](#group). The library
implements the machine-mode CSRs a single [hart](#hart) answers to, routes the [PMP](#pmp)
registers to the host, and applies the access rules of the unprivileged spec's section 2.1 before
either.

`csr.allowed` at [src/riscv/isa/csr.zig#L272](src/riscv/isa/csr.zig#L272); the handlers are
[src/sem/riscv/system.zig](src/sem/riscv/system.zig).

`csr.allowed` and `csr.Target` reuse two words that mean other things elsewhere ---
[group set](#group-set) membership and a build triple; both are local to CSR access.

See also: [Hart](#hart), [PMP](#pmp), [misa](#misa), [mtvec](#mtvec).
