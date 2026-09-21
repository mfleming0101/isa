//! Builds the size probe object for a machine. `attach` exports `isa_step` and `isa_disasm`,
//! C-callable shims over the machine's `stepOnce` and `disassemble`, so the linked object's section
//! sizes measure the ISA alone; bench/run.zig reads them from zig-out/sizeprobe-*.o.

const std = @import("std");
const facade = @import("facade.zig");

/// Exports C-callable `isa_step` and `isa_disasm` shims over M, after asserting the facade.
pub fn attach(comptime M: type) void {
    comptime facade.assertMachine(M);

    const shim = struct {
        fn step(machine: *M) callconv(.c) u64 {
            const ran = machine.stepOnce();
            return ran.retired << 8 | @intFromEnum(ran.stop);
        }

        fn disasm(code: u32, pc: u32, into: [*]u8, len: usize) callconv(.c) usize {
            var writer: std.Io.Writer = .fixed(into[0..len]);
            M.disassemble(&writer, code, pc) catch {};
            return writer.buffered().len;
        }
    };

    @export(&shim.step, .{ .name = "isa_step" });
    @export(&shim.disasm, .{ .name = "isa_disasm" });
}
