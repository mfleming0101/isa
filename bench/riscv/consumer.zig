//! Entry point of `consumer-riscv`: the harness's `consumer` CLI over the RISC-V machine, which
//! bench/run.zig drives to run, trace, disassemble, decode, sweep and selfcheck the RISC-V side of
//! a metrics row.

const harness = @import("harness");
const Machine = @import("machine.zig").Machine;

/// The consumer CLI's entry point over the RISC-V machine.
pub const main = harness.consumer.Consumer(Machine).main;
