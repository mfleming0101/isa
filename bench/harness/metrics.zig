//! Schema of one bench/summary.tsv row, defined once so every alternative writes the same columns
//! in the same order. Correctness columns are gates: a row that fails one is still written with
//! status fail so a regression stays visible; a row that implements part of the core and holds
//! every gate defined against that part is partial. Also renders the TSV header and a row's line.

const std = @import("std");

/// One summary row: provenance, correctness gates, runtime, size, build and interface columns.
pub const Summary = struct {
    date: []const u8,
    commit: []const u8,
    variant: []const u8,
    target: []const u8,
    optimize: []const u8,
    zig: []const u8,
    cpu_mhz: f64,
    status: Status,

    ambiguity_pairs: u32,
    totality_holes: u32,
    decode_sweep_arm: bool,
    decode_sweep_rv: bool,
    vectors_pass: u32,
    vectors_total: u32,
    oracle_match: u32,
    oracle_total: u32,
    corpus_pass: u32,
    corpus_total: u32,

    fw_ns_per_instr: f64,
    fw_ns_arm: f64,
    fw_ns_rv: f64,
    fw_instrs: u64,

    decode_only_ns: f64,
    loop_ns_arm_bdot: f64,
    loop_ns_arm_mixed: f64,
    loop_ns_arm_bl: f64,
    loop_ns_rv_mixed: f64,
    loop_ns_rv_c: f64,

    obj_text: u64,
    obj_rodata: u64,
    obj_data: u64,
    obj_bss: u64,
    link_delta_bytes: i64,
    runtime_heap_peak: u64,
    bytes_per_row: f64,

    cold_build_s: f64,
    compiler_peak_rss_mb: u64,
    gen_s: f64,

    host_decls_required: u32,
    host_decls_optional: u32,
    host_types_imported: u32,

    rows_implemented: u32,
    rows_total: u32,
    spec_sha: []const u8,
    stub_sha: []const u8,
    corpus_sha: []const u8,
    oracle_sha: []const u8,
};

/// Admissibility of a row: pass, partial for a tranche, or fail.
pub const Status = enum { pass, partial, fail };

/// Whether a variant is non-empty `key=value` pairs joined by semicolons, without whitespace.
pub fn validVariant(text: []const u8) bool {
    if (text.len == 0) return false;
    var pairs = std.mem.splitScalar(u8, text, ';');
    while (pairs.next()) |pair| {
        const at = std.mem.indexOfScalar(u8, pair, '=') orelse return false;
        if (at == 0 or at + 1 == pair.len) return false;
        if (std.mem.indexOfAny(u8, pair, " \t\r\n") != null) return false;
    }
    return true;
}

/// Whether the whole core is implemented and every gate holds; each ratio is floored above zero.
pub fn gated(row: Summary) bool {
    return row.rows_implemented == row.rows_total and
        row.ambiguity_pairs == 0 and
        row.totality_holes == 0 and
        row.decode_sweep_arm and row.decode_sweep_rv and
        row.vectors_total > 0 and row.vectors_pass == row.vectors_total and
        row.oracle_total > 0 and row.oracle_match == row.oracle_total and
        row.corpus_total > 0 and row.corpus_pass == row.corpus_total and
        row.host_types_imported == 0;
}

fn tranched(row: Summary) bool {
    return row.rows_implemented < row.rows_total and
        row.ambiguity_pairs == 0 and
        row.totality_holes == 0 and
        row.decode_sweep_arm and row.decode_sweep_rv and
        row.vectors_total > 0 and row.vectors_pass == row.vectors_total and
        row.oracle_total > 0 and row.oracle_match == row.oracle_total and
        row.host_types_imported == 0;
}

/// Pass when gated, partial when a tranche holds its own gates, otherwise fail.
pub fn statusOf(row: Summary) Status {
    if (gated(row)) return .pass;
    if (tranched(row)) return .partial;
    return .fail;
}

/// Columns measured against the full core, which a partial row carries but no comparison reads.
pub const full_core_only: []const []const u8 = &.{
    "fw_ns_per_instr", "fw_ns_arm", "fw_ns_rv", "fw_instrs", "decode_only_ns", "runtime_heap_peak",
};

/// Whether a comparison may read this column from a row of this status.
pub fn admits(status: Status, column: []const u8) bool {
    return switch (status) {
        .pass => true,
        .partial => for (full_core_only) |name| {
            if (std.mem.eql(u8, name, column)) break false;
        } else true,
        .fail => false,
    };
}

/// Writes the tab-separated column names and a newline into buffer.
pub fn header(buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(Summary).@"struct".fields, 0..) |field, i| {
        at += (try std.fmt.bufPrint(buffer[at..], "{s}{s}", .{ if (i == 0) "" else "\t", field.name })).len;
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}

/// Writes the row's values tab-separated, floats to three places, into buffer.
pub fn line(row: Summary, buffer: []u8) ![]u8 {
    var at: usize = 0;
    inline for (@typeInfo(Summary).@"struct".fields, 0..) |field, i| {
        if (i != 0) at += (try std.fmt.bufPrint(buffer[at..], "\t", .{})).len;
        const value = @field(row, field.name);
        at += switch (@typeInfo(field.type)) {
            .float => (try std.fmt.bufPrint(buffer[at..], "{d:.3}", .{value})).len,
            .@"enum" => (try std.fmt.bufPrint(buffer[at..], "{s}", .{@tagName(value)})).len,
            .bool => (try std.fmt.bufPrint(buffer[at..], "{d}", .{@intFromBool(value)})).len,
            .pointer => (try std.fmt.bufPrint(buffer[at..], "{s}", .{value})).len,
            else => (try std.fmt.bufPrint(buffer[at..], "{d}", .{value})).len,
        };
    }
    at += (try std.fmt.bufPrint(buffer[at..], "\n", .{})).len;
    return buffer[0..at];
}
