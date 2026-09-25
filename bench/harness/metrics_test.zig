//! Tests of the metrics row schema against a sample row: variant validation, header and line column
//! counts, and the pass, partial or fail status a row earns from its gates, including which columns
//! a partial row may carry into a comparison.

const std = @import("std");
const metrics = @import("metrics.zig");

const sample: metrics.Summary = .{
    .date = "2026-09-12",
    .commit = "0000000",
    .variant = "",
    .target = "x86_64-linux",
    .optimize = "ReleaseFast",
    .zig = "0.16.0",
    .cpu_mhz = 0,
    .status = .pass,
    .ambiguity_pairs = 0,
    .totality_holes = 0,
    .decode_sweep_arm = true,
    .decode_sweep_rv = true,
    .vectors_pass = 7,
    .vectors_total = 7,
    .oracle_match = 3,
    .oracle_total = 3,
    .corpus_pass = 12,
    .corpus_total = 12,
    .fw_ns_per_instr = 1.5,
    .fw_ns_arm = 1.4,
    .fw_ns_rv = 1.6,
    .fw_instrs = 1,
    .decode_only_ns = 0.5,
    .loop_ns_arm_bdot = 1,
    .loop_ns_arm_mixed = 1,
    .loop_ns_arm_bl = 1,
    .loop_ns_rv_mixed = 1,
    .loop_ns_rv_c = 1,
    .obj_text = 1,
    .obj_rodata = 1,
    .obj_data = 1,
    .obj_bss = 1,
    .link_delta_bytes = -1,
    .runtime_heap_peak = 1,
    .bytes_per_row = 1,
    .cold_build_s = 1,
    .compiler_peak_rss_mb = 1,
    .gen_s = 1,
    .host_decls_required = 8,
    .host_decls_optional = 1,
    .host_types_imported = 0,
    .rows_implemented = 393,
    .rows_total = 393,
    .spec_sha = "0",
    .stub_sha = "0",
    .corpus_sha = "0",
    .oracle_sha = "0",
};

test "a variant names a knob per pair, or is refused" {
    try std.testing.expect(metrics.validVariant("inline=small"));
    try std.testing.expect(metrics.validVariant("inline=small;dispatch=tail"));
    try std.testing.expect(!metrics.validVariant(""));
    try std.testing.expect(!metrics.validVariant("inline"));
    try std.testing.expect(!metrics.validVariant("=small"));
    try std.testing.expect(!metrics.validVariant("inline="));
    try std.testing.expect(!metrics.validVariant("inline=small;"));
    try std.testing.expect(!metrics.validVariant("inline=small; dispatch=tail"));
    try std.testing.expect(!metrics.validVariant("inline=small\tdispatch=tail"));
}

test "a line carries one field per header column" {
    var head: [4096]u8 = undefined;
    var body: [4096]u8 = undefined;
    const columns = std.mem.count(u8, try metrics.header(&head), "\t");
    try std.testing.expectEqual(columns, std.mem.count(u8, try metrics.line(sample, &body), "\t"));
}

test "a failing correctness gate makes the row inadmissible" {
    try std.testing.expect(metrics.gated(sample));

    var holed = sample;
    holed.totality_holes = 1;
    try std.testing.expect(!metrics.gated(holed));

    var leaked = sample;
    leaked.host_types_imported = 1;
    try std.testing.expect(!metrics.gated(leaked));

    var unchecked = sample;
    unchecked.oracle_match = 0;
    unchecked.oracle_total = 0;
    try std.testing.expect(!metrics.gated(unchecked));
}

test "a tranche whose own gates hold is partial, not failed" {
    var tranche = sample;
    tranche.rows_implemented = 14;
    tranche.corpus_pass = 0;
    try std.testing.expectEqual(metrics.Status.partial, metrics.statusOf(tranche));

    var drifted = tranche;
    drifted.decode_sweep_arm = false;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(drifted));

    var disagreeing = tranche;
    disagreeing.oracle_match = 0;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(disagreeing));

    var unproven = tranche;
    unproven.totality_holes = 1;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(unproven));

    var unchecked = tranche;
    unchecked.vectors_pass = 0;
    unchecked.vectors_total = 0;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(unchecked));
}

test "a tranche that holds every full core gate is still partial, not passed" {
    var tranche = sample;
    tranche.rows_implemented = 305;
    try std.testing.expectEqual(metrics.Status.partial, metrics.statusOf(tranche));
}

test "a full core row that fails the corpus is failed, not partial" {
    var full = sample;
    full.corpus_pass = 11;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(full));
    try std.testing.expectEqual(metrics.Status.pass, metrics.statusOf(sample));
}

test "a partial row carries the slope columns and not the full core ones" {
    var tranche = sample;
    tranche.rows_implemented = 14;
    tranche.corpus_pass = 0;
    try std.testing.expect(!metrics.gated(tranche));
    for ([_][]const u8{ "obj_text", "obj_bss", "bytes_per_row", "cold_build_s", "compiler_peak_rss_mb", "gen_s", "loop_ns_arm_mixed" }) |column| {
        try std.testing.expect(metrics.admits(.partial, column));
    }
    for (metrics.full_core_only) |column| {
        try std.testing.expect(!metrics.admits(.partial, column));
        try std.testing.expect(metrics.admits(.pass, column));
        try std.testing.expect(!metrics.admits(.fail, column));
    }
}
