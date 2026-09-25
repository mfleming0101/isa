//! The Armv7-M machine the bench measures: the library's generated decode, disassembly and metadata
//! over the reference host and flat memory. Fetches halfwords, executes narrow or wide encodings
//! under the Armv7-M group set, skips failed IT-block slots, maps outcomes onto the harness stop
//! taxonomy and converts state to and from snapshots. Wrapped by consumer.zig and sizeprobe.zig.

const std = @import("std");
const isa = @import("isa");
const harness = @import("harness");
const decode = isa.generated.arm_decode;
const disasm = isa.generated.arm_disasm;
const meta = isa.generated.arm_meta;
const access = isa.sem.arm.access;
const State = isa.sem.arm.State;

const Snapshot = harness.snapshot.Snapshot;

const allowed = isa.arm.decode.selectionOf(.armv7m).groups;

/// Facade machine over the ISA's Armv7-M rows, the reference host and flat memory.
pub const Machine = struct {
    /// This machine answers for Armv7-M.
    pub const arch: harness.facade.Arch = .armv7m;
    /// Rows the generated tree carries.
    pub const rows_implemented: usize = meta.rows_implemented;
    /// Rows the spec defines for Armv7-M.
    pub const rows_total: usize = meta.rows_total;
    /// Host types imported by the machine; none.
    pub const imported_types: usize = 0;
    /// Register the console checksum is read from: r0.
    pub const result_register: u5 = 0;
    /// Host declarations the Armv7-M rows require, checked by the facade.
    pub const host_requirements = &isa.contract.arm_requirements;

    /// The reference Armv7-M host this machine executes against.
    pub const Host = @import("host").arm.Host;

    state: State = .{},
    host: Host,

    /// Builds a machine over the image with pc, msp and the published reset LR and xPSR.
    pub fn init(image: harness.facade.Image) Machine {
        var self: Machine = .{ .host = .{ .memory = .{ .bytes = image.memory, .base = image.base } } };
        self.state.pc = image.entry;
        self.state.msp = image.sp;
        self.state.lr = harness.facade.armv7m_reset.lr;
        self.state.xpsr = harness.facade.armv7m_reset.xpsr;
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

    /// Fetches, decodes and executes one instruction, honouring IT-block predication.
    pub fn stepOnce(self: *Machine) harness.facade.Ran {
        if (self.state.xpsr & State.flag_t == 0) return .{ .retired = 0, .stop = .undefined_instruction };
        const at = self.state.pc;
        var held: access.Span(Host) = &.{};
        const hw1 = access.fetch(Host, &self.host, at, &held) catch return .{ .retired = 0, .stop = .fetch_fault };
        const wide = hw1 >> 11 >= 0x1d;
        const conditional = self.state.inIt();
        if (conditional and !self.state.itPasses()) return self.skip(at, &held, hw1, wide);
        const done = if (wide) blk: {
            const hw2 = access.halfword(Host, &self.host, &held, at +% 2) catch return .{ .retired = 0, .stop = .fetch_fault };
            break :blk decode.executeWide(Host, &self.state, &self.host, @as(u32, hw1) << 16 | hw2, allowed);
        } else decode.executeNarrow(Host, &self.state, &self.host, hw1, allowed);

        const ran: harness.facade.Ran = switch (done.outcome) {
            .next => blk: {
                self.state.pc = at +% @as(u32, if (wide) 4 else 2);
                break :blk .{ .retired = 1, .stop = .running };
            },
            .branched => .{ .retired = 1, .stop = .running },
            .supervisor_call, .exception_return, .function_return => .{ .retired = 0, .stop = .exited },
            .data_fault, .violation, .secure => .{ .retired = 0, .stop = .data_fault },
            .unaligned => .{ .retired = 0, .stop = .unaligned },
            .breakpoint => .{ .retired = 0, .stop = .breakpoint },
            else => .{ .retired = 0, .stop = .undefined_instruction },
        };
        if (conditional and ran.stop == .running) self.state.itAdvance();
        return ran;
    }

    fn skip(self: *Machine, at: u32, held: *[]u8, hw1: u16, wide: bool) harness.facade.Ran {
        if (!wide and hw1 & 0xff00 == 0xbe00) return .{ .retired = 0, .stop = .breakpoint };
        if (wide) _ = access.halfword(Host, &self.host, held, at +% 2) catch return .{ .retired = 0, .stop = .fetch_fault };
        self.state.pc = at +% @as(u32, if (wide) 4 else 2);
        self.state.itAdvance();
        return .{ .retired = 1, .stop = .running };
    }

    /// Copies r0-r12, sp, lr, pc and xPSR into a harness snapshot.
    pub fn snapshot(self: *const Machine) Snapshot {
        var out: Snapshot = .{ .pc = self.state.pc, .flags = self.state.xpsr };
        @memcpy(out.regs[0..13], &self.state.r);
        out.regs[13] = self.state.sp();
        out.regs[14] = self.state.lr;
        out.regs[15] = self.state.pc;
        return out;
    }

    /// Restores registers, pc and xPSR from a snapshot; clears psp, control and the exclusive monitor.
    pub fn load(self: *Machine, snap: Snapshot) void {
        @memcpy(&self.state.r, snap.regs[0..13]);
        self.state.msp = snap.regs[13];
        self.state.psp = 0;
        self.state.control = 0;
        self.state.lr = snap.regs[14];
        self.state.pc = snap.pc;
        self.state.xpsr = snap.flags;
        self.state.exclusive = null;
    }

    /// Renders one code at pc with the generated disassembler.
    pub fn disassemble(writer: *std.Io.Writer, code: u32, pc: u32) !void {
        return disasm.write(writer, code, pc, allowed);
    }

    /// Nothing to precompute.
    pub fn prepare() void {}

    /// Row index of a narrow or wide code, without executing it.
    pub fn decodeOnly(code: u32) u32 {
        return if (code > 0xffff) decode.indexWide(code, allowed) else decode.indexNarrow(code, allowed);
    }
};

comptime {
    harness.facade.assertMachine(Machine);
}
