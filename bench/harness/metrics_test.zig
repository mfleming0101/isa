//! Tests of the metrics row schema against a sample row: header and line column counts, and the
//! pass or fail status a row earns from its gates.

const std = @import("std");
const metrics = @import("metrics.zig");

const sample: metrics.Summary = .{
    .date = "2026-09-12",
    .commit = "0000000",
    .target = "x86_64-linux",
    .optimize = "ReleaseFast",
    .zig = "0.16.0",
    .status = .pass,
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
    .link_delta_bytes = -1,
    .runtime_heap_peak = 1,
    .bytes_per_row = 1,
    .cold_build_s = 1,
    .compiler_peak_rss_mb = 1,
    .gen_s = 1,
    .host_decls_required = 8,
    .spec_sha = "0",
    .stub_sha = "0",
    .corpus_sha = "0",
    .oracle_sha = "0",
};

test "a line carries one field per header column" {
    var head: [4096]u8 = undefined;
    var body: [4096]u8 = undefined;
    const columns = std.mem.count(u8, try metrics.header(&head), "\t");
    try std.testing.expectEqual(columns, std.mem.count(u8, try metrics.line(sample, &body), "\t"));
}

test "a failing correctness gate makes the row inadmissible" {
    try std.testing.expect(metrics.gated(sample));
    try std.testing.expectEqual(metrics.Status.pass, metrics.statusOf(sample));

    var drifted = sample;
    drifted.decode_sweep_arm = false;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(drifted));

    var disagreeing = sample;
    disagreeing.oracle_match = 0;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(disagreeing));

    var unchecked = sample;
    unchecked.oracle_match = 0;
    unchecked.oracle_total = 0;
    try std.testing.expect(!metrics.gated(unchecked));

    var failing = sample;
    failing.corpus_pass = 11;
    try std.testing.expectEqual(metrics.Status.fail, metrics.statusOf(failing));
}
