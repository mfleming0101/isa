//! Root of the `sizeprobe-riscv` object: attaches the harness size probe to the RISC-V machine, so
//! the object's section sizes, read by bench/run.zig from zig-out, measure the ISA's own code and
//! data.

const harness = @import("harness");
const Machine = @import("machine.zig").Machine;

comptime {
    harness.sizeprobe.attach(Machine);
}
