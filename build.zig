const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spec = b.addModule("spec", .{
        .root_source_file = b.path("spec/check.zig"),
        .target = target,
        .optimize = optimize,
    });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "spec", .module = spec },
    };

    const generator = b.addExecutable(.{
        .name = "gen-tree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "spec", .module = spec }},
        }),
    });
    const generate = b.addRunArtifact(generator);
    const emitted = generate.addOutputDirectoryArg("generated");
    const presets = b.option([]const u8, "presets", "Which group-set presets the generated tree answers for") orelse "v7m,v6m,v8mbase,v81mmain";
    const shape = b.option([]const u8, "shape", "One tree over the union of the presets, gated at its leaves, or one tree per preset") orelse "union";
    generate.addArgs(&.{ presets, shape });

    const isa = b.addModule("isa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    attachGenerated(b, isa, emitted, target, optimize);

    const unit_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    attachGenerated(b, unit_module, emitted, target, optimize);
    const unit = b.addTest(.{ .root_module = unit_module });
    const spec_test = b.addTest(.{ .root_module = spec });
    const run_spec = b.addRunArtifact(spec_test);
    const spec_step = b.step("spec", "Check the shared row set is well formed and disjoint");
    spec_step.dependOn(&run_spec.step);

    const test_step = b.step("test", "Run every test that needs only zig");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&run_spec.step);

    const examples_step = b.step("examples", "Run the examples under examples/");
    for ([_][]const u8{ "execute_arm", "execute_riscv", "disassemble", "allow_at_runtime", "arm_processors", "riscv_processors", "step_loop", "host_contract", "row_name" }) |name| {
        const example = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "isa", .module = isa }},
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(example).step);
    }
    test_step.dependOn(examples_step);

    const harness = b.addModule("harness", .{
        .root_source_file = b.path("bench/harness/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "isa", .module = isa }},
    });
    harness.addAnonymousImport("manifest", .{ .root_source_file = b.path("corpus/manifest.zon") });

    const bench_imports = [_]std.Build.Module.Import{
        .{ .name = "isa", .module = isa },
        .{ .name = "spec", .module = spec },
        .{ .name = "harness", .module = harness },
    };

    b.step("harness", "Check the harness").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = harness })).step);

    const bench_step = b.step("bench", "Build the consumers, size probes and bench tools");
    bench_step.dependOn(&b.addInstallArtifact(generator, .{}).step);

    const consumers = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "consumer-null", .root = "bench/nullisa/consumer.zig" },
        .{ .name = "consumer-arm", .root = "bench/arm/consumer.zig" },
        .{ .name = "consumer-riscv", .root = "bench/riscv/consumer.zig" },
    };
    for (consumers) |c| {
        const exe = b.addExecutable(.{
            .name = c.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(c.root),
                .target = target,
                .optimize = optimize,
                .imports = &bench_imports,
            }),
        });
        bench_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    const probes = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "sizeprobe-arm", .root = "bench/arm/sizeprobe.zig" },
        .{ .name = "sizeprobe-riscv", .root = "bench/riscv/sizeprobe.zig" },
    };
    for (probes) |p| {
        const obj = b.addObject(.{
            .name = p.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(p.root),
                .target = target,
                .optimize = optimize,
                .imports = &bench_imports,
            }),
        });
        bench_step.dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("{s}.o", .{p.name})).step);
    }

    const tools = [_]struct { name: []const u8, root: []const u8, step: []const u8, desc: []const u8 }{
        .{ .name = "bench", .root = "bench/run.zig", .step = "metrics", .desc = "Append one schema-valid row to bench/summary.tsv, or release-metrics.tsv with --release" },
        .{ .name = "compare", .root = "bench/compare.zig", .step = "compare", .desc = "Render every arm's latest row side by side" },
    };
    for (tools) |t| {
        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(t.root),
                .target = target,
                .optimize = .ReleaseSafe,
                .imports = &bench_imports,
            }),
        });
        bench_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        if (b.args) |args| run.addArgs(args);
        b.step(t.step, t.desc).dependOn(&run.step);
    }
}

fn attachGenerated(
    b: *std.Build,
    lib: *std.Build.Module,
    dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    for ([_][]const u8{ "arm", "riscv" }) |arch| {
        var made: [3]*std.Build.Module = undefined;
        for ([_][]const u8{ "decode", "disasm", "meta" }, &made) |kind, *m| {
            const name = b.fmt("{s}_{s}", .{ arch, kind });
            m.* = b.createModule(.{
                .root_source_file = dir.path(b, b.fmt("{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            });
            lib.addImport(name, m.*);
        }
        made[0].addImport("isa", lib);
        made[1].addImport("isa", lib);
        made[1].addImport(b.fmt("{s}_decode", .{arch}), made[0]);
    }
}
