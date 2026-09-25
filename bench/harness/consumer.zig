//! Generator of the `consumer` CLI every measured alternative ships. `Consumer(M)` returns a
//! struct whose `main` dispatches the subcommands in `usage`: run and trace an ELF image,
//! disassemble or decode codes from stdin, sweep the decode space into bucket hashes, replay
//! selfcheck vectors, and print the machine's interface counts. bench/run.zig drives these
//! binaries to fill a metrics row.

const std = @import("std");
const elf = @import("elf.zig");
const facade = @import("facade.zig");
const snapshot = @import("snapshot.zig");
const stub = @import("host");
const contract = @import("isa").contract;

/// The subcommand grammar, printed on a usage error.
pub const usage =
    \\consumer run       <image> [budget] [probe]
    \\consumer trace     <image> [budget]
    \\consumer disasm    < codes
    \\consumer decode    <reps> < codes
    \\consumer sweep     <lo> <hi>
    \\consumer selfcheck <vectors>
    \\consumer about
    \\
;

/// Returns the CLI program for machine M, after asserting it satisfies the facade.
pub fn Consumer(comptime M: type) type {
    comptime facade.assertMachine(M);

    return struct {
        /// Entry point: dispatches the first argument to its subcommand.
        pub fn main(init: std.process.Init) !void {
            var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
            defer args.deinit();
            _ = args.next();

            var buffer: [1 << 16]u8 = undefined;
            var file = std.Io.File.stdout().writer(init.io, &buffer);
            const out = &file.interface;
            defer out.flush() catch {};

            M.prepare();

            const command = args.next() orelse return fail(out, "missing subcommand");
            if (std.mem.eql(u8, command, "run")) return run(init, out, &args);
            if (std.mem.eql(u8, command, "trace")) return trace(init, out, &args);
            if (std.mem.eql(u8, command, "disasm")) return disasm(init, out);
            if (std.mem.eql(u8, command, "decode")) return decode(init, out, &args);
            if (std.mem.eql(u8, command, "sweep")) return sweep(out, &args);
            if (std.mem.eql(u8, command, "selfcheck")) return selfcheck(init, out, &args);
            if (std.mem.eql(u8, command, "about")) return about(out);
            return fail(out, "unknown subcommand");
        }

        fn about(out: *std.Io.Writer) !void {
            const requirements = if (@hasDecl(M, "host_requirements")) M.host_requirements else &.{};
            try out.print("arch={s} rows_implemented={d} rows_total={d} imported_types={d} host_required={d} host_optional={d}\n", .{
                @tagName(M.arch),
                M.rows_implemented,
                M.rows_total,
                M.imported_types,
                comptime contract.required(requirements),
                comptime contract.optional(requirements),
            });
        }

        fn fail(out: *std.Io.Writer, message: []const u8) !void {
            try out.print("error={s}\n{s}", .{ message, usage });
            try out.flush();
            std.process.exit(2);
        }

        fn open(init: std.process.Init, path: []const u8) !struct { M, []u8 } {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(64 << 20));
            const memory = try init.arena.allocator().alloc(u8, stub.size);
            const loaded = try elf.load(bytes, memory, 0);
            if (loaded.arch != M.arch) return error.WrongArchitecture;
            return .{ M.init(.{
                .memory = memory,
                .base = 0,
                .entry = loaded.entry,
                .sp = loaded.sp,
            }), memory };
        }

        fn budgetOf(args: *std.process.Args.Iterator) u64 {
            const text = args.next() orelse return std.math.maxInt(u64);
            return std.fmt.parseInt(u64, text, 0) catch std.math.maxInt(u64);
        }

        fn run(init: std.process.Init, out: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
            const path = args.next() orelse return fail(out, "run needs an image");
            const budget = budgetOf(args);
            const probing = if (args.next()) |flag| std.mem.eql(u8, flag, "probe") else false;

            var machine, _ = try open(init, path);
            const started = std.Io.Timestamp.now(init.io, .awake);
            const ran = if (probing) try probe(init, &machine, budget) else machine.run(budget);
            const elapsed = std.Io.Timestamp.now(init.io, .awake).nanoseconds - started.nanoseconds;

            try out.print("retired={d} stop={s} ns={d} checksum={x:0>8} unique_pcs={d} decodes={d} heap={d}\n", .{
                ran.retired, @tagName(ran.stop), elapsed, machine.snapshot().regs[M.result_register], ran.unique_pcs, ran.decodes, resident(&machine),
            });
        }

        fn resident(machine: *M) u64 {
            return stub.size + if (@hasDecl(M, "bytesResident")) machine.bytesResident() else 0;
        }

        fn probe(init: std.process.Init, machine: *M, budget: u64) !facade.Ran {
            const seen = try init.arena.allocator().alloc(u8, stub.size / 8);
            @memset(seen, 0);
            var ran: facade.Ran = .{ .retired = 0, .stop = .running };
            while (ran.retired < budget) {
                const pc = machine.snapshot().pc;
                if (pc < stub.size) {
                    const bit = @as(u8, 1) << @truncate(pc & 7);
                    if (seen[pc >> 3] & bit == 0) {
                        seen[pc >> 3] |= bit;
                        ran.unique_pcs += 1;
                    }
                }
                const one = machine.stepOnce();
                ran.retired += one.retired;
                ran.decodes += 1;
                if (one.stop != .running) {
                    ran.stop = one.stop;
                    break;
                }
            } else ran.stop = .budget;
            return ran;
        }

        fn trace(init: std.process.Init, out: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
            const path = args.next() orelse return fail(out, "trace needs an image");
            const budget = budgetOf(args);
            var machine, _ = try open(init, path);

            var retired: u64 = 0;
            while (retired < budget) {
                const one = machine.stepOnce();
                retired += one.retired;
                try line(out, retired, machine.snapshot());
                if (one.stop != .running) {
                    try out.print("stop={s}\n", .{@tagName(one.stop)});
                    return;
                }
            }
            try out.print("stop=budget\n", .{});
        }

        fn line(out: *std.Io.Writer, retired: u64, state: snapshot.Snapshot) !void {
            if (M.arch == .armv7m and state.regs[15] != state.pc) return error.ArmPcNotMirrored;
            try out.print("{d} {x:0>8} {x:0>8}", .{ retired, state.pc, state.flags });
            for (state.regs) |r| try out.print(" {x:0>8}", .{r});
            try out.writeByte('\n');
        }

        fn disasm(init: std.process.Init, out: *std.Io.Writer) !void {
            var buffer: [4096]u8 = undefined;
            var file = std.Io.File.stdin().readerStreaming(init.io, &buffer);
            while (true) {
                const raw = file.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.EndOfStream => {
                        const rest = file.interface.buffered();
                        if (rest.len != 0) try renderOne(out, rest);
                        return;
                    },
                    else => return err,
                };
                try renderOne(out, raw);
            }
        }

        fn renderOne(out: *std.Io.Writer, raw: []const u8) !void {
            var fields = std.mem.tokenizeAny(u8, raw, " \t\r\n");
            const first = fields.next() orelse return;
            const code = std.fmt.parseInt(u32, first, 16) catch return out.writeAll("?\n");
            const pc = if (fields.next()) |at| std.fmt.parseInt(u32, at, 16) catch 0 else 0;
            try M.disassemble(out, code, pc);
            try out.writeByte('\n');
        }

        fn decode(init: std.process.Init, out: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
            const reps = std.fmt.parseInt(u64, args.next() orelse return fail(out, "decode needs a repeat count"), 0) catch
                return fail(out, "decode needs a repeat count");

            var codes: std.ArrayList(u32) = .empty;
            var buffer: [4096]u8 = undefined;
            var file = std.Io.File.stdin().readerStreaming(init.io, &buffer);
            while (file.interface.takeDelimiterInclusive('\n')) |raw| {
                if (codeOf(raw)) |code| try codes.append(init.arena.allocator(), code);
            } else |_| {
                if (codeOf(file.interface.buffered())) |code| try codes.append(init.arena.allocator(), code);
            }

            var sink: u32 = 0;
            const started = std.Io.Timestamp.now(init.io, .awake);
            for (0..reps) |_| {
                for (codes.items) |code| sink = sink *% 31 +% M.decodeOnly(code);
            }
            const elapsed = std.Io.Timestamp.now(init.io, .awake).nanoseconds - started.nanoseconds;
            std.mem.doNotOptimizeAway(sink);

            try out.print("decodes={d} ns={d}\n", .{ codes.items.len * reps, elapsed });
        }

        fn codeOf(raw: []const u8) ?u32 {
            var fields = std.mem.tokenizeAny(u8, raw, " \t\r\n");
            return std.fmt.parseInt(u32, fields.next() orelse return null, 16) catch null;
        }

        fn sweep(out: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
            const lo = try std.fmt.parseInt(u32, args.next() orelse return fail(out, "sweep needs lo"), 0);
            const hi = try std.fmt.parseInt(u32, args.next() orelse return fail(out, "sweep needs hi"), 0);

            var text: [256]u8 = undefined;
            var holes: u64 = 0;
            for (lo..hi) |bucket| {
                var hash: u64 = 0xcbf29ce484222325;
                for (0..1 << 16) |low| {
                    const code: u32 = @intCast(bucket << 16 | low);
                    var render: std.Io.Writer = .fixed(&text);
                    M.disassemble(&render, code, 0) catch {};
                    holes += @intFromBool(render.buffered().len == 0);
                    for (render.buffered()) |byte| hash = (hash ^ byte) *% 0x100000001b3;
                    hash = (hash ^ 0xff) *% 0x100000001b3;
                }
                try out.print("{x:0>4} {x:0>16}\n", .{ bucket, hash });
            }
            try out.print("holes={d}\n", .{holes});
        }

        fn selfcheck(init: std.process.Init, out: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
            const path = args.next() orelse return fail(out, "selfcheck needs a vector file");
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(1 << 30));
            const vectors = std.mem.bytesAsSlice(snapshot.Vector, bytes[0 .. bytes.len / @sizeOf(snapshot.Vector) * @sizeOf(snapshot.Vector)]);

            const memory = try init.arena.allocator().alloc(u8, stub.size);
            @memset(memory, 0);

            var passed: usize = 0;
            for (vectors, 0..) |vector, i| {
                if (@as(u64, vector.before.pc) + 4 > memory.len) {
                    try out.print("{d} fail\n", .{i});
                    continue;
                }
                std.mem.writeInt(u32, memory[vector.before.pc..][0..4], vector.code, .little);
                var machine = M.init(.{ .memory = memory, .base = 0, .entry = 0, .sp = 0 });
                machine.load(vector.before);
                _ = machine.stepOnce();
                const got = machine.snapshot();
                const ok = std.mem.eql(u8, std.mem.asBytes(&got), std.mem.asBytes(&vector.after));
                passed += @intFromBool(ok);
                try out.print("{d} {s}\n", .{ i, if (ok) "pass" else "fail" });
            }
            try out.print("vectors={d} pass={d}\n", .{ vectors.len, passed });
        }
    };
}
