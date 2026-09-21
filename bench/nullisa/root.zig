//! The empty machine: satisfies the facade with no instruction set, so every step stops on an
//! undefined instruction. consumer.zig builds it into `consumer-null`, whose linked size
//! bench/run.zig subtracts from each real consumer to get `link_delta_bytes`, the harness's own
//! contribution to a binary.

const std = @import("std");
const isa = @import("isa");
const harness = @import("harness");

/// Facade machine with no rows, used to size the harness alone.
pub const Machine = struct {
    /// Reports Armv7-M so the Arm corpus images load.
    pub const arch: harness.facade.Arch = .armv7m;
    /// No rows are executed.
    pub const rows_implemented: usize = 0;
    /// No rows are declared.
    pub const rows_total: usize = 0;
    /// No host types are imported.
    pub const imported_types: usize = 0;
    /// Register the console checksum is read from: r0.
    pub const result_register: u5 = 0;

    memory: isa.host.Memory,
    state: harness.snapshot.Snapshot = .{},

    /// Builds a machine with pc at entry and r13 holding the stack pointer.
    pub fn init(image: harness.facade.Image) Machine {
        return .{
            .memory = .{ .bytes = image.memory, .base = image.base },
            .state = .{ .pc = image.entry, .regs = blk: {
                var regs: [32]u32 = @splat(0);
                regs[13] = image.sp;
                regs[15] = image.entry;
                break :blk regs;
            } },
        };
    }

    /// Stops immediately on an undefined instruction, retiring nothing.
    pub fn run(self: *Machine, budget: u64) harness.facade.Ran {
        _ = budget;
        self.state.stop = .undefined_instruction;
        return .{ .retired = 0, .stop = self.state.stop };
    }

    /// One step, which is the same refusal as run.
    pub fn stepOnce(self: *Machine) harness.facade.Ran {
        return self.run(1);
    }

    /// Returns the held snapshot.
    pub fn snapshot(self: *const Machine) harness.snapshot.Snapshot {
        return self.state;
    }

    /// Replaces the held snapshot.
    pub fn load(self: *Machine, state: harness.snapshot.Snapshot) void {
        self.state = state;
    }

    /// Renders every code as `undefined`.
    pub fn disassemble(writer: *std.Io.Writer, code: u32, pc: u32) !void {
        _ = code;
        _ = pc;
        try writer.writeAll("undefined");
    }

    /// Nothing to precompute.
    pub fn prepare() void {}

    /// Every code decodes to row zero.
    pub fn decodeOnly(code: u32) u32 {
        _ = code;
        return 0;
    }
};

comptime {
    harness.facade.assertMachine(Machine);
}
