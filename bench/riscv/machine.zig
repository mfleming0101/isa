//! The RISC-V machine the bench measures: the library's generated decode, disassembly and metadata
//! over the reference host and flat memory, with the default CSR implementation. Fetches parcels, executes
//! compressed or 32-bit encodings under the rv32imafc group set, maps outcomes onto the harness
//! stop taxonomy and converts state to and from snapshots. Wrapped by consumer.zig and
//! sizeprobe.zig.

const std = @import("std");
const isa = @import("isa");
const harness = @import("harness");
const decode = isa.generated.riscv_decode;
const disasm = isa.generated.riscv_disasm;
const meta = isa.generated.riscv_meta;
const sem = isa.sem.riscv;
const access = sem.access;
const allowed = isa.riscv.decode.every;

const Snapshot = harness.snapshot.Snapshot;
const State = sem.State;

/// Facade machine over the ISA's RV32 rows, the reference host and flat memory.
pub const Machine = struct {
    /// This machine answers for RV32IMC and the extensions its group set allows.
    pub const arch: harness.facade.Arch = .rv32imc;
    /// Rows the generated tree carries.
    pub const rows_implemented: usize = meta.rows_implemented;
    /// Rows the spec defines for RV32.
    pub const rows_total: usize = meta.rows_total;
    /// Host types imported by the machine; none.
    pub const imported_types: usize = 0;
    /// Register the console checksum is read from: a0.
    pub const result_register: u5 = 10;
    /// Host declarations the RISC-V rows require, checked by the facade.
    pub const host_requirements = &isa.contract.riscv_requirements;

    /// The reference RISC-V host this machine executes against.
    pub const Host = @import("host").riscv.Host;

    state: State = .{},
    host: Host,

    /// Builds a machine over the image with pc at its entry.
    pub fn init(image: harness.facade.Image) Machine {
        var self: Machine = .{ .host = .{ .memory = .{ .bytes = image.memory, .base = image.base } } };
        self.state.pc = image.entry;
        return self;
    }

    /// Steps until budget instructions retire or the machine stops.
    pub fn run(self: *Machine, budget: u64) harness.facade.Ran {
        var retired: u64 = 0;
        while (retired < budget) {
            const one = self.stepOnce();
            retired += one.retired;
            if (one.stop != .running) return .{ .retired = retired, .stop = one.stop };
        }
        return .{ .retired = retired, .stop = .budget };
    }

    /// Fetches one parcel, or two when the low bits open a 32-bit instruction, and executes it.
    pub fn stepOnce(self: *Machine) harness.facade.Ran {
        const at = self.state.pc;
        var held: access.Span(Host) = &.{};
        const first = access.fetch(Host, &self.host, at, &held) orelse return .{ .retired = 0, .stop = .fetch_fault };
        const wide = first & 3 == 3;
        const done = if (wide) blk: {
            const hi = access.parcel(Host, &self.host, &held, at +% 2) orelse return .{ .retired = 0, .stop = .fetch_fault };
            break :blk decode.executeWide(Host, &self.state, &self.host, @as(u32, hi) << 16 | first, allowed);
        } else decode.executeNarrow(Host, &self.state, &self.host, first, allowed);

        return switch (done.outcome) {
            .next => blk: {
                self.state.pc = at +% @as(u32, if (wide) 4 else 2);
                break :blk .{ .retired = 1, .stop = .running };
            },
            .branched => .{ .retired = 1, .stop = .running },
            .data_fault => .{ .retired = 0, .stop = .data_fault },
            .unaligned => .{ .retired = 0, .stop = .data_fault },
            .breakpoint => .{ .retired = 0, .stop = .breakpoint },
            .environment_call => .{ .retired = 0, .stop = .exited },
            else => .{ .retired = 0, .stop = .undefined_instruction },
        };
    }

    /// Copies the register file and pc into a harness snapshot.
    pub fn snapshot(self: *const Machine) Snapshot {
        return .{ .regs = self.state.x, .pc = self.state.pc };
    }

    /// Resets the state to the snapshot's register file and pc.
    pub fn load(self: *Machine, snap: Snapshot) void {
        self.state = .{ .x = snap.regs, .pc = snap.pc };
    }

    /// Renders one code at pc with the generated disassembler.
    pub fn disassemble(writer: *std.Io.Writer, code: u32, pc: u32) !void {
        return disasm.write(writer, code, pc, allowed);
    }

    /// Nothing to precompute.
    pub fn prepare() void {}

    /// Row index of a compressed or 32-bit code, without executing it.
    pub fn decodeOnly(code: u32) u32 {
        return if (code & 3 == 3) decode.indexWide(code, allowed) else decode.indexNarrow(code, allowed);
    }
};

comptime {
    harness.facade.assertMachine(Machine);
}
