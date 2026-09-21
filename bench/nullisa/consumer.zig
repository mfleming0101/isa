//! Entry point of `consumer-null`: the harness's `consumer` CLI over the empty machine, built by
//! `zig build bench` so bench/run.zig can subtract its linked size from the real consumers.

const harness = @import("harness");
const Machine = @import("root.zig").Machine;

/// The consumer CLI's entry point over the empty machine.
pub const main = harness.consumer.Consumer(Machine).main;
