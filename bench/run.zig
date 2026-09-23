//! The bench driver behind `zig build metrics`. Rebuilds the consumers against a cold cache, runs
//! every corpus image several times on one core keeping the minimum, reads the size probes and
//! interface counts, runs the test suite, the decode sweeps, the loop images, the decode-only
//! timing and the disassembly and lockstep oracles, then appends one schema-valid row to
//! bench/summary.tsv with per-image logs. Refuses the row if the binaries
//! changed underneath the run.

const std = @import("std");
const harness = @import("harness");
const spec = @import("spec");

const metrics = harness.metrics;
const corpus = harness.corpus;

const Oracle = struct { match: u32 = 0, total: u32 = 0, skipped: u32 = 0 };

const alt = "tree";

const Options = struct {
    variant: []const u8 = "",
    knobs: []const []const u8 = &.{},
    optimize: []const u8 = "ReleaseFast",
    runs: usize = 5,
    budget: u64 = 4_000_000_000,
    cold: bool = true,
    sweep: bool = true,
    lockstep: bool = true,
    loop_instrs: u64 = 20_000_000,
    decode_reps: u64 = 2_000,
    cpu_mhz: f64 = 0,
    pin: ?u16 = null,
    release: bool = false,
};

/// Parses the flags, runs every measurement layer and appends the row.
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next();

    var options: Options = .{};
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--optimize")) {
            options.optimize = args.next() orelse return usage(init);
        } else if (std.mem.eql(u8, flag, "--variant")) {
            options.variant = args.next() orelse return usage(init);
            if (!metrics.validVariant(options.variant)) return usage(init);
            options.knobs = try knobsOf(gpa, options.variant);
        } else if (std.mem.eql(u8, flag, "--runs")) {
            options.runs = try std.fmt.parseInt(usize, args.next() orelse return usage(init), 10);
        } else if (std.mem.eql(u8, flag, "--pin")) {
            options.pin = try std.fmt.parseInt(u16, args.next() orelse return usage(init), 10);
        } else if (std.mem.eql(u8, flag, "--cpu-mhz")) {
            options.cpu_mhz = try std.fmt.parseFloat(f64, args.next() orelse return usage(init));
        } else if (std.mem.eql(u8, flag, "--warm")) {
            options.cold = false;
        } else if (std.mem.eql(u8, flag, "--no-sweep")) {
            options.sweep = false;
        } else if (std.mem.eql(u8, flag, "--no-lockstep")) {
            options.lockstep = false;
        } else if (std.mem.eql(u8, flag, "--release")) {
            options.release = true;
        } else return usage(init);
    }

    var buffer: [1 << 16]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    try images(init, gpa, out);
    const build = try rebuild(init, gpa, options);
    const gen_s = try generate(init, gpa);
    const binaries = try consumerDigest(init, gpa);
    const detail = try measure(init, gpa, options, out);
    const size = try sizes(init, gpa);
    const about = try interface(init, gpa);
    const vectors = try selftest(init, gpa, options);
    const swept = try sweeps(init, gpa, options);
    const loop = try loops(init, gpa, options);
    const decoded = try decodeOnly(init, gpa, options);
    var oracle = try oracles(init, gpa);
    const stepped = try lockstep(init, gpa, options);
    if (!std.mem.eql(u8, binaries, try consumerDigest(init, gpa))) {
        try out.print("error=the measured binaries changed during the run; no row written\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    try out.print("oracle   disasm={d}/{d} skipped={d}   lockstep={d}/{d} windows\n", .{
        oracle.match, oracle.total, oracle.skipped, stepped.match, stepped.total,
    });
    oracle.match += stepped.match;
    oracle.total += stepped.total;

    var row = metrics.Summary{
        .date = try today(init, gpa),
        .commit = describe(init, gpa),
        .alt = alt,
        .variant = options.variant,
        .target = @tagName(@import("builtin").target.cpu.arch) ++ "-" ++ @tagName(@import("builtin").target.os.tag),
        .optimize = options.optimize,
        .zig = @import("builtin").zig_version_string,
        .cpu_mhz = if (options.cpu_mhz != 0) options.cpu_mhz else cpuMhz(init, gpa),
        .status = .fail,

        .ambiguity_pairs = spec.schema.ambiguities(spec.arm) + spec.schema.ambiguities(spec.riscv),
        .totality_holes = swept.holes,
        .decode_sweep_arm = swept.arm,
        .decode_sweep_rv = swept.riscv,
        .vectors_pass = vectors.passed,
        .vectors_total = vectors.total,
        .oracle_match = oracle.match,
        .oracle_total = oracle.total,
        .corpus_pass = detail.passed,
        .corpus_total = @intCast(corpus.images.len),

        .fw_ns_per_instr = detail.overall,
        .fw_ns_arm = detail.arm,
        .fw_ns_rv = detail.riscv,
        .fw_instrs = detail.retired,

        .decode_only_ns = decoded,
        .loop_ns_arm_bdot = loop.arm_bdot,
        .loop_ns_arm_mixed = loop.arm_mixed,
        .loop_ns_arm_bl = loop.arm_bl,
        .loop_ns_rv_mixed = loop.rv_mixed,
        .loop_ns_rv_c = loop.rv_c,

        .obj_text = size.text,
        .obj_rodata = size.rodata,
        .obj_data = size.data,
        .obj_bss = size.bss,
        .link_delta_bytes = size.link_delta,
        .runtime_heap_peak = detail.heap_peak,
        .bytes_per_row = if (about.rows_total == 0) 0 else @as(f64, @floatFromInt(size.text + size.rodata)) / @as(f64, @floatFromInt(about.rows_total)),

        .cold_build_s = build.seconds,
        .compiler_peak_rss_mb = build.peak_rss_mb,
        .gen_s = gen_s,

        .host_decls_required = about.host_required,
        .host_decls_optional = about.host_optional,
        .host_types_imported = about.imported_types,

        .rows_implemented = about.rows_implemented,
        .rows_total = about.rows_total,
        .spec_sha = try digestOf(init, gpa, &.{ "spec/schema.zig", "spec/arm/t32_narrow.zon", "spec/arm/t32_wide.zon", "spec/riscv/rv32i.zon", "spec/riscv/rv32m.zon", "spec/riscv/rv32c.zon" }),
        .stub_sha = try digestOf(init, gpa, &.{"src/host/memory.zig"}),
        .corpus_sha = try corpusDigest(init, gpa),
        .oracle_sha = try digestOf(init, gpa, &.{ "oracle/disasm_arm.txt", "oracle/disasm_riscv.txt", "oracle/sweep_arm.txt", "oracle/sweep_riscv.txt" }),
    };
    row.status = metrics.statusOf(row);

    try append(init, gpa, if (options.release) "bench/release-metrics.tsv" else "bench/summary.tsv", row);
    try appendLog(init, gpa, "bench/detail.tsv", "alt\timage\tarch\tns_per_instr\tretired\tstop\tchecksum\tok\n", detail.log);
    try out.print("\n", .{});
    try out.writeAll(try metrics.header(try gpa.alloc(u8, 4096)));
    try out.writeAll(try metrics.line(row, try gpa.alloc(u8, 4096)));
}

fn usage(init: std.process.Init) !void {
    _ = init;
    std.debug.print("bench/run.zig [--variant <k=v;k=v>] [--optimize <mode>] [--runs <n>] [--warm] [--no-sweep] [--no-lockstep] [--cpu-mhz <mhz>] [--pin <cpu>] [--release]\n", .{});
    std.process.exit(2);
}

fn knobsOf(gpa: std.mem.Allocator, variant: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, variant, ';');
    while (pairs.next()) |pair| try out.append(gpa, try std.fmt.allocPrint(gpa, "-D{s}", .{pair}));
    return out.items;
}

fn zigBuild(gpa: std.mem.Allocator, options: Options, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(gpa, &.{ "zig", "build" });
    try out.appendSlice(gpa, args);
    try out.appendSlice(gpa, options.knobs);
    return out.items;
}

const Build = struct { seconds: f64, peak_rss_mb: u64 };

fn rebuild(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !Build {
    const cache = ".zig-cache-cold";
    if (options.cold) std.Io.Dir.cwd().deleteTree(init.io, cache) catch {};

    const started = std.Io.Timestamp.now(init.io, .awake);
    var child = try std.process.spawn(init.io, .{
        .argv = try zigBuild(gpa, options, &.{
            "bench",
            try std.fmt.allocPrint(gpa, "-Doptimize={s}", .{options.optimize}),
            "--cache-dir",
            cache,
            "--global-cache-dir",
            try std.fmt.allocPrint(gpa, "{s}/global", .{cache}),
        }),
        .request_resource_usage_statistics = true,
        .stdout = .ignore,
    });
    const term = try child.wait(init.io);
    const elapsed = std.Io.Timestamp.now(init.io, .awake).nanoseconds - started.nanoseconds;
    if (term != .exited or term.exited != 0) return error.BuildFailed;

    return .{
        .seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s,
        .peak_rss_mb = (child.resource_usage_statistics.getMaxRss() orelse 0) >> 20,
    };
}

const Detail = struct { arm: f64, riscv: f64, overall: f64, retired: u64, passed: u32, heap_peak: u64, log: []const u8 = "" };

fn measure(init: std.process.Init, gpa: std.mem.Allocator, options: Options, out: *std.Io.Writer) !Detail {
    var log: std.ArrayList(u8) = .empty;

    var sums: [2]f64 = @splat(0);
    var counts: [2]usize = @splat(0);
    var detail: Detail = .{ .arm = 0, .riscv = 0, .overall = 0, .retired = 0, .passed = 0, .heap_peak = 0 };

    for (corpus.images) |image| {
        const which: usize = if (corpus.archOf(image) == .armv7m) 0 else 1;
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{image.arch});
        if (!present(init, consumer)) continue;
        const path = try std.fmt.allocPrint(gpa, "corpus/{s}", .{image.path});
        const budget = try std.fmt.allocPrint(gpa, "{d}", .{options.budget});

        var best: u64 = std.math.maxInt(u64);
        var seen: Ran = .{};
        var steady = true;
        for (0..options.runs) |run| {
            const one = try once(init, gpa, try onOneCore(gpa, options, &.{ consumer, "run", path, budget }));
            if (run != 0 and (one.retired != seen.retired or one.stop != seen.stop or one.checksum != seen.checksum)) steady = false;
            seen = one;
            best = @min(best, one.ns);
            detail.heap_peak = @max(detail.heap_peak, one.heap);
        }

        const ok = steady and corpus.matches(image, seen.retired, seen.stop, seen.checksum);
        detail.passed += @intFromBool(ok);
        detail.retired += seen.retired;

        const per = if (seen.retired == 0) 0 else @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(seen.retired));
        if (per > 0) {
            sums[which] += @log(per);
            counts[which] += 1;
        }

        try log.print(gpa, "{s}\t{s}\t{s}\t{d:.4}\t{d}\t{s}\t{x:0>8}\t{d}\n", .{
            alt, image.name, image.arch, per, seen.retired, @tagName(seen.stop), seen.checksum, @intFromBool(ok),
        });
        try out.print("{s:<6} {s:<9} {d:>8.3} ns/instr  {s}\n", .{ image.arch, image.name, per, if (!steady) "UNSTABLE" else if (ok) "ok" else "MISMATCH" });
    }
    detail.log = log.items;

    detail.arm = if (counts[0] == 0) 0 else @exp(sums[0] / @as(f64, @floatFromInt(counts[0])));
    detail.riscv = if (counts[1] == 0) 0 else @exp(sums[1] / @as(f64, @floatFromInt(counts[1])));
    detail.overall = if (detail.arm == 0 or detail.riscv == 0) 0 else @sqrt(detail.arm * detail.riscv);
    return detail;
}

fn onOneCore(gpa: std.mem.Allocator, options: Options, argv: []const []const u8) ![]const []const u8 {
    const cpu = options.pin orelse return argv;
    const out = try gpa.alloc([]const u8, argv.len + 3);
    out[0] = "taskset";
    out[1] = "-c";
    out[2] = try std.fmt.allocPrint(gpa, "{d}", .{cpu});
    @memcpy(out[3..], argv);
    return out;
}

const Ran = struct { retired: u64 = 0, stop: harness.snapshot.Stop = .running, ns: u64 = 0, checksum: u32 = 0, heap: u64 = 0 };

fn once(init: std.process.Init, gpa: std.mem.Allocator, argv: []const []const u8) !Ran {
    const result = try std.process.run(gpa, init.io, .{ .argv = argv });
    var out: Ran = .{};
    var fields = std.mem.tokenizeAny(u8, result.stdout, " \n");
    while (fields.next()) |field| {
        const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..split];
        const value = field[split + 1 ..];
        if (std.mem.eql(u8, key, "retired")) out.retired = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "ns")) out.ns = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "checksum")) out.checksum = try std.fmt.parseInt(u32, value, 16);
        if (std.mem.eql(u8, key, "heap")) out.heap = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, key, "stop")) out.stop = std.meta.stringToEnum(harness.snapshot.Stop, value) orelse .running;
    }
    return out;
}

const Sizes = struct { text: u64 = 0, rodata: u64 = 0, data: u64 = 0, bss: u64 = 0, link_delta: i64 = 0 };

fn sizes(init: std.process.Init, gpa: std.mem.Allocator) !Sizes {
    var out: Sizes = .{};
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const object = try std.fmt.allocPrint(gpa, "zig-out/sizeprobe-{s}.o", .{which});
        if (!present(init, object)) continue;
        const section = try harness.elf.sizes(try read(init, gpa, object));
        out.text += section.text;
        out.rodata += section.rodata;
        out.data += section.data;
        out.bss += section.bss;

        const linked = try std.fmt.allocPrint(gpa, "zig-out/bin/consumer-{s}", .{which});
        if (!present(init, linked) or !present(init, "zig-out/bin/consumer-null")) continue;
        out.link_delta += @as(i64, @intCast((try read(init, gpa, linked)).len));
        out.link_delta -= @as(i64, @intCast((try read(init, gpa, "zig-out/bin/consumer-null")).len));
    }
    return out;
}

const About = struct {
    rows_implemented: u32 = 0,
    rows_total: u32 = 0,
    imported_types: u32 = 0,
    host_required: u32 = 0,
    host_optional: u32 = 0,
};

fn interface(init: std.process.Init, gpa: std.mem.Allocator) !About {
    var out: About = .{};
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        if (!present(init, consumer)) continue;
        const result = try std.process.run(gpa, init.io, .{ .argv = &.{ consumer, "about" } });

        var one: About = .{};
        var fields = std.mem.tokenizeAny(u8, result.stdout, " \n");
        while (fields.next()) |field| {
            const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..split];
            const value = std.fmt.parseInt(u32, field[split + 1 ..], 10) catch continue;
            inline for (@typeInfo(About).@"struct".fields) |f| {
                if (std.mem.eql(u8, key, f.name)) @field(one, f.name) = value;
            }
        }
        out.rows_implemented += one.rows_implemented;
        out.rows_total += one.rows_total;
        out.imported_types += one.imported_types;
        out.host_required = @max(out.host_required, one.host_required);
        out.host_optional = @max(out.host_optional, one.host_optional);
    }
    return out;
}

fn appendLog(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, head: []const u8, body: []const u8) !void {
    const existing = read(init, gpa, path) catch "";
    if (existing.len != 0 and !std.mem.startsWith(u8, existing, head)) return error.LogHeaderChanged;
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(if (existing.len == 0) head else existing);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn images(init: std.process.Init, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    var corpus_missing: usize = 0;
    for (harness.corpus.images) |image| {
        if (!present(init, try std.fmt.allocPrint(gpa, "corpus/{s}", .{image.path}))) corpus_missing += 1;
    }
    var loops_missing: usize = 0;
    inline for (std.meta.fields(Loops)) |field| {
        if (!present(init, "bench/loops/" ++ field.name ++ ".elf")) loops_missing += 1;
    }
    if (corpus_missing == 0 and loops_missing == 0) return;
    if (corpus_missing != 0) try out.print("error={d} of {d} corpus images missing under corpus/out; run corpus/build.sh first\n", .{ corpus_missing, harness.corpus.images.len });
    if (loops_missing != 0) try out.print("error={d} of {d} loop images missing under bench/loops; run bench/loops/build.sh first\n", .{ loops_missing, std.meta.fields(Loops).len });
    try out.flush();
    std.process.exit(1);
}

fn present(init: std.process.Init, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(init.io, std.mem.trimStart(u8, path, "./"), .{}) catch return false;
    file.close(init.io);
    return true;
}

fn read(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(256 << 20));
}

fn digestOf(init: std.process.Init, gpa: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths) |path| hash.update(try read(init, gpa, path));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.allocPrint(gpa, "{x}", .{digest[0..8].*});
}

fn consumerDigest(init: std.process.Init, gpa: std.mem.Allocator) ![]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const path = try std.fmt.allocPrint(gpa, "zig-out/bin/consumer-{s}", .{which});
        if (present(init, path)) try paths.append(gpa, path);
    }
    if (present(init, "zig-out/bin/consumer-null")) try paths.append(gpa, "zig-out/bin/consumer-null");
    return digestOf(init, gpa, paths.items);
}

fn corpusDigest(init: std.process.Init, gpa: std.mem.Allocator) ![]const u8 {
    var paths = try gpa.alloc([]const u8, corpus.images.len);
    for (corpus.images, 0..) |image, i| paths[i] = try std.fmt.allocPrint(gpa, "corpus/{s}", .{image.path});
    return digestOf(init, gpa, paths);
}

fn today(init: std.process.Init, gpa: std.mem.Allocator) ![]const u8 {
    const now = std.Io.Timestamp.now(init.io, .real).nanoseconds;
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(now, std.time.ns_per_s)) };
    const date = day.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    return std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2}", .{ date.year, month.month.numeric(), month.day_index + 1 });
}

fn describe(init: std.process.Init, gpa: std.mem.Allocator) []const u8 {
    const result = std.process.run(gpa, init.io, .{ .argv = &.{ "git", "rev-parse", "--short", "HEAD" } }) catch return "-";
    if (result.term != .exited or result.term.exited != 0) return "-";
    const text = std.mem.trim(u8, result.stdout, " \n");
    return if (text.len == 0) "-" else text;
}

fn append(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, row: metrics.Summary) !void {
    const existing = read(init, gpa, path) catch "";
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(init.io, &buffer);

    if (existing.len == 0) try writer.interface.writeAll(try metrics.header(try gpa.alloc(u8, 4096))) else try writer.interface.writeAll(existing);
    try writer.interface.writeAll(try metrics.line(row, try gpa.alloc(u8, 4096)));
    try writer.interface.flush();
}

fn generate(init: std.process.Init, gpa: std.mem.Allocator) !f64 {
    const scratch = ".zig-cache-cold-gen";
    std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);
    const started = std.Io.Timestamp.now(init.io, .awake);
    const result = try std.process.run(gpa, init.io, .{
        .argv = &.{ "zig-out/bin/gen-tree", scratch, "v7m,v6m,v8mbase,v81mmain", "union" },
    });
    const elapsed = std.Io.Timestamp.now(init.io, .awake).nanoseconds - started.nanoseconds;
    if (result.term != .exited or result.term.exited != 0) return error.GeneratorFailed;
    return @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
}

const Vectors = struct { passed: u32 = 0, total: u32 = 0 };

fn selftest(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !Vectors {
    const cache = ".zig-cache-cold-test";
    if (options.cold) std.Io.Dir.cwd().deleteTree(init.io, cache) catch {};

    const result = try std.process.run(gpa, init.io, .{
        .argv = try zigBuild(gpa, options, &.{ "test", "--summary", "all", "--cache-dir", cache, "--global-cache-dir", try std.fmt.allocPrint(gpa, "{s}/global", .{cache}) }),
    });
    if (result.term != .exited or result.term.exited != 0) return error.TestsFailed;

    var out: Vectors = .{};
    var lines = std.mem.tokenizeScalar(u8, result.stderr, '\n');
    while (lines.next()) |line| {
        const seen = summary(line) orelse continue;
        out.passed += seen.passed;
        out.total += seen.total;
    }
    return out;
}

fn summary(line: []const u8) ?Vectors {
    const at = std.mem.indexOf(u8, line, " pass") orelse return null;
    const open = std.mem.indexOfPos(u8, line, at, " (") orelse return null;
    const from = open + " (".len;
    const to = std.mem.indexOfScalarPos(u8, line, from, ' ') orelse return null;
    if (!std.mem.startsWith(u8, line[to + 1 ..], "total)")) return null;
    const total = std.fmt.parseInt(u32, line[from..to], 10) catch return null;

    const passed = precedingCount(line[0..at]) orelse return null;
    const skip_at = std.mem.indexOfPos(u8, line, at, " skip") orelse open;
    const skipped = if (skip_at < open) precedingCount(line[0..skip_at]) orelse return null else 0;
    if (skipped > total) return null;
    return .{ .passed = passed, .total = total - skipped };
}

fn precedingCount(head: []const u8) ?u32 {
    var back = head.len;
    while (back > 0 and std.ascii.isDigit(head[back - 1])) back -= 1;
    return std.fmt.parseInt(u32, head[back..], 10) catch null;
}

const Loops = struct {
    arm_bdot: f64 = 0,
    arm_mixed: f64 = 0,
    arm_bl: f64 = 0,
    rv_mixed: f64 = 0,
    rv_c: f64 = 0,
};

fn loops(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !Loops {
    var out: Loops = .{};
    const budget = try std.fmt.allocPrint(gpa, "{d}", .{options.loop_instrs});
    inline for (@typeInfo(Loops).@"struct".fields) |field| {
        const which = if (comptime std.mem.startsWith(u8, field.name, "arm")) "arm" else "riscv";
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        const path = "bench/loops/" ++ field.name ++ ".elf";
        if (present(init, consumer) and present(init, path)) {
            var best: u64 = std.math.maxInt(u64);
            var seen: Ran = .{};
            var steady = true;
            for (0..options.runs) |run| {
                const one = try once(init, gpa, try onOneCore(gpa, options, &.{ consumer, "run", path, budget }));
                if (run != 0 and (one.retired != seen.retired or one.stop != seen.stop or one.checksum != seen.checksum)) steady = false;
                seen = one;
                best = @min(best, one.ns);
            }
            if (steady and seen.retired != 0) {
                @field(out, field.name) = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(seen.retired));
            }
        }
    }
    return out;
}

fn decodeOnly(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !f64 {
    const scratch = ".zig-cache-cold-decode";
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);

    var product: f64 = 1;
    var counted: usize = 0;
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        if (!present(init, consumer)) continue;
        const pinned = read(init, gpa, try std.fmt.allocPrint(gpa, "oracle/disasm_{s}.txt", .{which})) catch continue;

        var asked: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, pinned, '\n');
        while (lines.next()) |raw| {
            const line = harness.oracle.parse(raw) orelse continue;
            try asked.print(gpa, "{s}\n", .{line.code});
        }
        const request = try std.fmt.allocPrint(gpa, "{s}/{s}.in", .{ scratch, which });
        const response = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ scratch, which });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = request, .data = asked.items });

        var best: f64 = 0;
        for (0..options.runs) |_| {
            const seen = try timeDecodes(init, gpa, options, consumer, request, response);
            if (seen != 0 and (best == 0 or seen < best)) best = seen;
        }
        if (best == 0) continue;
        product *= best;
        counted += 1;
    }
    return if (counted == 0) 0 else std.math.pow(f64, product, 1.0 / @as(f64, @floatFromInt(counted)));
}

fn timeDecodes(init: std.process.Init, gpa: std.mem.Allocator, options: Options, consumer: []const u8, request: []const u8, response: []const u8) !f64 {
    {
        const from = try std.Io.Dir.cwd().openFile(init.io, request, .{});
        defer from.close(init.io);
        const to = try std.Io.Dir.cwd().createFile(init.io, response, .{});
        defer to.close(init.io);
        var child = try std.process.spawn(init.io, .{
            .argv = try onOneCore(gpa, options, &.{ consumer, "decode", try std.fmt.allocPrint(gpa, "{d}", .{options.decode_reps}) }),
            .stdin = .{ .file = from },
            .stdout = .{ .file = to },
        });
        _ = try child.wait(init.io);
    }

    var count: u64 = 0;
    var ns: u64 = 0;
    var fields = std.mem.tokenizeAny(u8, try read(init, gpa, response), " \n");
    while (fields.next()) |field| {
        const split = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const value = field[split + 1 ..];
        if (std.mem.eql(u8, field[0..split], "decodes")) count = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, field[0..split], "ns")) ns = std.fmt.parseInt(u64, value, 10) catch 0;
    }
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(count));
}

fn cpuMhz(init: std.process.Init, gpa: std.mem.Allocator) f64 {
    const text = read(init, gpa, "/proc/cpuinfo") catch return 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "MHz") orelse continue;
        const colon = std.mem.indexOfScalarPos(u8, line, at, ':') orelse continue;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \t\r")) catch 0;
    }
    const khz = read(init, gpa, "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq") catch return 0;
    const parsed = std.fmt.parseFloat(f64, std.mem.trim(u8, khz, " \n\r\t")) catch return 0;
    return parsed / 1000.0;
}

fn lockstep(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !Oracle {
    var out: Oracle = .{};
    if (!options.lockstep) return out;
    const buffer = try gpa.alloc(u8, 1 << 20);
    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        if (!present(init, consumer)) continue;
        const pinned = read(init, gpa, try std.fmt.allocPrint(gpa, "oracle/trace_{s}.txt", .{which})) catch return error.MissingOracle;
        const pins = try trace(gpa, pinned);

        for (corpus.images) |image| {
            if (!std.mem.eql(u8, image.arch, which)) continue;

            const pin = pins.get(image.name) orelse continue;
            const expected = pin.windows;
            const budget = pin.retired orelse image.retired;
            if (expected.items.len == 0) continue;

            var child = try std.process.spawn(init.io, .{
                .argv = &.{
                    consumer,
                    "trace",
                    try std.fmt.allocPrint(gpa, "corpus/{s}", .{image.path}),
                    try std.fmt.allocPrint(gpa, "{d}", .{budget}),
                },
                .stdout = .pipe,
            });
            var reader = child.stdout.?.readerStreaming(init.io, buffer);

            var digest = harness.oracle.seed;
            var count: u64 = 0;
            var index: usize = 0;
            while (reader.interface.takeDelimiterInclusive('\n')) |raw| {
                const record = harness.oracle.state(raw) orelse continue;
                digest = harness.oracle.fold(digest, record);
                count += 1;
                if (count % harness.oracle.window != 0) continue;
                index += tally(&out, expected.items, index, digest);
                digest = harness.oracle.seed;
            } else |_| {}
            if (count % harness.oracle.window != 0) index += tally(&out, expected.items, index, digest);
            _ = try child.wait(init.io);

            out.total += @intCast(expected.items.len -| index);
        }
    }
    return out;
}

const Pin = struct { windows: std.ArrayList([]const u8) = .empty, retired: ?u64 = null };

fn trace(gpa: std.mem.Allocator, pinned: []const u8) !std.StringHashMapUnmanaged(Pin) {
    var out: std.StringHashMapUnmanaged(Pin) = .empty;
    var lines = std.mem.splitScalar(u8, pinned, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        if (raw[0] == '#') {
            var head = std.mem.tokenizeScalar(u8, raw[1..], ' ');
            const name = head.next() orelse continue;
            const count = head.next() orelse continue;
            const entry = try out.getOrPutValue(gpa, name, .{});
            entry.value_ptr.retired = std.fmt.parseInt(u64, count, 10) catch null;
            continue;
        }
        var fields = std.mem.splitScalar(u8, raw, ' ');
        const name = fields.next() orelse continue;
        _ = fields.next();
        const hash = fields.next() orelse continue;
        const entry = try out.getOrPutValue(gpa, name, .{});
        try entry.value_ptr.windows.append(gpa, hash);
    }
    return out;
}

fn tally(out: *Oracle, expected: []const []const u8, index: usize, digest: u64) usize {
    if (index >= expected.len) {
        out.total += 1;
        return 1;
    }
    var hex: [16]u8 = undefined;
    const written = std.fmt.bufPrint(&hex, "{x:0>16}", .{digest}) catch unreachable;
    out.total += 1;
    out.match += @intFromBool(std.mem.eql(u8, written, expected[index]));
    return 1;
}

fn oracles(init: std.process.Init, gpa: std.mem.Allocator) !Oracle {
    var out: Oracle = .{};
    const scratch = ".zig-cache-cold-oracle";
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);

    for ([_][]const u8{ "arm", "riscv" }) |which| {
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        if (!present(init, consumer)) continue;
        const pinned = read(init, gpa, try std.fmt.allocPrint(gpa, "oracle/disasm_{s}.txt", .{which})) catch return error.MissingOracle;

        var asked: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, pinned, '\n');
        while (lines.next()) |raw| {
            const line = harness.oracle.parse(raw) orelse continue;
            try asked.print(gpa, "{s} {s}\n", .{ line.code, line.pc });
        }

        const request = try std.fmt.allocPrint(gpa, "{s}/{s}.in", .{ scratch, which });
        const response = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ scratch, which });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = request, .data = asked.items });
        {
            const from = try std.Io.Dir.cwd().openFile(init.io, request, .{});
            defer from.close(init.io);
            const to = try std.Io.Dir.cwd().createFile(init.io, response, .{});
            defer to.close(init.io);
            var child = try std.process.spawn(init.io, .{
                .argv = &.{ consumer, "disasm" },
                .stdin = .{ .file = from },
                .stdout = .{ .file = to },
            });
            _ = try child.wait(init.io);
        }

        var got = std.mem.splitScalar(u8, try read(init, gpa, response), '\n');
        var mine: [512]u8 = undefined;
        var theirs: [512]u8 = undefined;
        lines.reset();
        while (lines.next()) |raw| {
            const line = harness.oracle.parse(raw) orelse continue;
            const rendered = got.next() orelse break;
            if (line.kind == .skip) {
                out.skipped += 1;
                continue;
            }
            out.total += 1;
            const a = harness.oracle.normalize(&mine, std.mem.trimEnd(u8, rendered, "\r"));
            const b = harness.oracle.normalize(&theirs, line.text);
            out.match += @intFromBool(std.mem.eql(u8, a, b));
        }
    }
    return out;
}

const Sweep = struct { arm: bool = false, riscv: bool = false, holes: u32 = 0 };

fn sweeps(init: std.process.Init, gpa: std.mem.Allocator, options: Options) !Sweep {
    var out: Sweep = .{};
    if (!options.sweep) return out;

    const shards = @max(1, std.Thread.getCpuCount() catch 1);
    const span = (0x10000 + shards - 1) / shards;
    const scratch = ".zig-cache-cold-sweep";
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);

    var matched: [2]bool = @splat(false);
    for ([_][]const u8{ "arm", "riscv" }, 0..) |which, i| {
        const consumer = try std.fmt.allocPrint(gpa, "./zig-out/bin/consumer-{s}", .{which});
        if (!present(init, consumer)) continue;
        const pinned = read(init, gpa, try std.fmt.allocPrint(gpa, "oracle/sweep_{s}.txt", .{which})) catch return error.MissingOracle;

        const children = try gpa.alloc(std.process.Child, shards);
        const parts = try gpa.alloc([]const u8, shards);
        for (children, parts, 0..) |*child, *part, shard| {
            const lo = @min(shard * span, 0x10000);
            part.* = try std.fmt.allocPrint(gpa, "{s}/{s}.{d}", .{ scratch, which, shard });
            const file = try std.Io.Dir.cwd().createFile(init.io, part.*, .{});
            defer file.close(init.io);
            child.* = try std.process.spawn(init.io, .{
                .argv = &.{
                    consumer,
                    "sweep",
                    try std.fmt.allocPrint(gpa, "{d}", .{lo}),
                    try std.fmt.allocPrint(gpa, "{d}", .{@min(lo + span, 0x10000)}),
                },
                .stdout = .{ .file = file },
            });
        }

        for (children) |*child| _ = try child.wait(init.io);

        var joined: std.ArrayList(u8) = .empty;
        for (parts) |part| {
            var lines = std.mem.splitScalar(u8, try read(init, gpa, part), '\n');
            while (lines.next()) |raw| {
                if (raw.len == 0) continue;
                if (std.mem.startsWith(u8, raw, "holes=")) {
                    out.holes +|= std.fmt.parseInt(u32, raw["holes=".len..], 10) catch 0;
                    continue;
                }
                try joined.print(gpa, "{s}\n", .{raw});
            }
        }
        matched[i] = std.mem.eql(u8, pinned, joined.items);
    }
    out.arm = matched[0];
    out.riscv = matched[1];
    return out;
}
