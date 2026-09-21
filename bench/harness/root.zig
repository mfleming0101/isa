//! Root of the `harness` module every bench program imports. Re-exports the machine facade, the
//! trace snapshot format, the metrics row schema, the ELF loader, the `consumer` CLI generator, the
//! size probe, the corpus manifest and the oracle-line parser, and gathers their tests under `zig
//! build harness`.

/// Machine facade every measured alternative must expose.
pub const facade = @import("facade.zig");
/// Architectural snapshot and stop reason that cross the facade boundary.
pub const snapshot = @import("snapshot.zig");
/// Summary schema of bench/summary.tsv, its gates and TSV rendering.
pub const metrics = @import("metrics.zig");
/// ELF32 image loader and object section sizes.
pub const elf = @import("elf.zig");
/// Generator of the `consumer` CLI over any facade machine.
pub const consumer = @import("consumer.zig");
/// Exports the two entry points the size probe object measures.
pub const sizeprobe = @import("sizeprobe.zig");
/// Pinned corpus manifest and its image lookups.
pub const corpus = @import("corpus.zig");
/// Pinned oracle line parsing, spelling normaliser and trace-window hashing.
pub const oracle = @import("oracle.zig");

test {
    _ = @import("elf_test.zig");
    _ = @import("metrics_test.zig");
    _ = @import("oracle.zig");
    _ = @import("corpus.zig");
}
