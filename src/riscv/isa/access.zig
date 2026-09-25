//! Memory access helpers for the RV32 rows: effective address, alignment, and the read, write and
//! fetch paths over a generic host. Whether a misaligned load or store is refused or answered is
//! the hart's own choice (Privileged 3.6), so the caller hands down its model's answer; an
//! answered access is one lookup at the address itself, which the span contract serves. Fetch
//! answers one parcel at a time and keeps the span it came from, so a 32-bit instruction's second
//! parcel needs no second lookup unless it straddles the span's end. Used by the semantics
//! handlers and the step loop.
const std = @import("std");
const State = @import("state.zig").State;
const Misaligned = @import("csr.zig").Misaligned;
const Failure = @import("instruction.zig").Failure;

/// Effective address: base register plus the sign-extended twelve-bit offset, section 2.6.
pub fn address(s: *const State, base: u5, offset: u32) u32 {
    return s.get(base) +% offset;
}

/// Whether an address is a multiple of the access width, section 2.6.
pub fn aligned(at: u32, comptime width: u8) bool {
    return at % (width / 8) == 0;
}

/// Notes the address to the host, then refuses a misaligned one on a hart that does not answer it.
pub fn check(comptime Host: type, host: *Host, misaligned: Misaligned, at: u32, comptime width: u8) Failure!void {
    host.touch(at);
    if (misaligned == .refused and !aligned(at, width)) return error.Unaligned;
}

/// The slice a host answers a span with, which a host over a read-only image makes const.
pub fn Span(comptime Host: type) type {
    return @typeInfo(@TypeOf(Host.span)).@"fn".return_type.?;
}

fn writable(comptime Host: type) bool {
    return !@typeInfo(Span(Host)).pointer.is_const;
}

fn word(span: []const u8, comptime width: u8) u32 {
    return std.mem.readInt(std.meta.Int(.unsigned, width), span[0 .. width / 8], .little);
}

fn extended(value: u32, comptime width: u8, comptime signed: bool) u32 {
    if (!signed or width == 32) return value;
    return @bitCast(@as(i32, @as(std.meta.Int(.signed, width), @bitCast(@as(std.meta.Int(.unsigned, width), @truncate(value))))));
}

/// Reads a byte, halfword or word, optionally sign-extended, faulting where the hart refuses it.
pub fn read(comptime Host: type, host: *Host, misaligned: Misaligned, at: u32, comptime width: u8, comptime signed: bool) Failure!u32 {
    try check(Host, host, misaligned, at, width);
    const span = host.span(at, .{ .kind = .read, .bytes = width / 8 });
    if (span.len < width / 8) {
        @branchHint(.unlikely);
        return extended(host.access(at, .{ .kind = .read, .bytes = width / 8 }, 0) catch return error.DataFault, width, signed);
    }
    return extended(word(span, width), width, signed);
}

/// Writes the low bits of a value at the given width, faulting where the hart refuses it.
pub fn write(comptime Host: type, host: *Host, misaligned: Misaligned, at: u32, comptime width: u8, value: u32) Failure!void {
    try check(Host, host, misaligned, at, width);
    if (comptime writable(Host)) {
        const span = host.span(at, .{ .kind = .write, .bytes = width / 8 });
        if (span.len >= width / 8) {
            std.mem.writeInt(std.meta.Int(.unsigned, width), span[0 .. width / 8], @truncate(value), .little);
            return;
        }
    }
    _ = host.access(at, .{ .kind = .write, .bytes = width / 8 }, value) catch return error.DataFault;
}

/// The parcel at an address, and the rest of the span it came from, section 1.5.
pub fn fetch(comptime Host: type, host: *Host, at: u32, held: *Span(Host)) ?u16 {
    const span = host.span(at, .{ .kind = .fetch, .bytes = 2 });
    if (span.len < 2) {
        @branchHint(.unlikely);
        held.* = &.{};
        return @truncate(host.access(at, .{ .kind = .fetch, .bytes = 2 }, 0) catch return null);
    }
    held.* = span[2..];
    return std.mem.readInt(u16, span[0..2], .little);
}

/// The second parcel of a 32-bit instruction, taken from the held span or fetched anew.
pub fn parcel(comptime Host: type, host: *Host, held: *Span(Host), at: u32) ?u16 {
    if (held.len >= 2) {
        defer held.* = held.*[2..];
        return std.mem.readInt(u16, held.*[0..2], .little);
    }
    return fetch(Host, host, at, held);
}
