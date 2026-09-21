//! Entry point of `consumer-arm`: the harness's `consumer` CLI over the Armv7-M machine, which
//! bench/run.zig drives to run, trace, disassemble, decode, sweep and selfcheck the Arm side of a
//! metrics row.

const harness = @import("harness");
const Machine = @import("machine.zig").Machine;

/// The consumer CLI's entry point over the Armv7-M machine.
pub const main = harness.consumer.Consumer(Machine).main;
