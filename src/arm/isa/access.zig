//! Memory access helpers for the Arm core. Forms operand addresses, performs loads and
//! stores through the span contract with the alignment rule of DDI0403 E2.1.125, runs
//! consecutive-word transfers for load and store multiple, push and pop, and fetches
//! instruction halfwords out of resolved spans.
const std = @import("std");
const State = @import("state.zig").State;
const Failure = @import("instruction.zig").Failure;

/// Which register an operand address is formed from: a general register, sp or pc.
pub const Base = enum { register, sp, pc };

/// Effective address of a load or store operand from its base and register or scaled immediate.
pub fn address(s: *const State, op: anytype, comptime base: Base, comptime width: u8) u32 {
    const offset: u32 = if (@hasField(@TypeOf(op), "m")) s.r[op.m] else @as(u32, op.i) * (width / 8);
    return switch (base) {
        .register => s.r[op.n] +% offset,
        .sp => s.sp() +% offset,
        .pc => ((s.pc +% 4) & ~@as(u32, 3)) +% offset,
    };
}

/// The slice a host answers a span with, which a host over a read-only image makes const.
pub fn Span(comptime Host: type) type {
    return @typeInfo(@TypeOf(Host.span)).@"fn".return_type.?;
}

fn writable(comptime Host: type) bool {
    return !@typeInfo(Span(Host)).pointer.is_const;
}

fn misaligned(comptime Host: type, host: *Host, at: u32, comptime width: u8, comptime strict: bool) bool {
    return at % (width / 8) != 0 and (strict or !host.architecture().main() or host.trapsUnaligned());
}

fn word(span: []const u8, comptime width: u8) u32 {
    return std.mem.readInt(std.meta.Int(.unsigned, width), span[0 .. width / 8], .little);
}

fn extended(value: u32, comptime width: u8, comptime signed: bool) u32 {
    if (!signed or width == 32) return value;
    return @bitCast(@as(i32, @as(std.meta.Int(.signed, width), @bitCast(@as(std.meta.Int(.unsigned, width), @truncate(value))))));
}

/// Loads a width-bit value at an address through the host, sign-extending if asked.
pub fn read(comptime Host: type, host: *Host, at: u32, comptime width: u8, comptime signed: bool, comptime strict: bool) Failure!u32 {
    host.touch(at);
    if (misaligned(Host, host, at, width, strict)) return error.Unaligned;
    const span = host.span(at, .{ .kind = .read, .bytes = width / 8 });
    if (span.len < width / 8) {
        @branchHint(.unlikely);
        return extended(try host.access(at, .{ .kind = .read, .bytes = width / 8 }, 0), width, signed);
    }
    return extended(word(span, width), width, signed);
}

/// Stores the low width bits of a value at an address through the host.
pub fn write(comptime Host: type, host: *Host, at: u32, comptime width: u8, value: u32, comptime strict: bool) Failure!void {
    host.touch(at);
    if (misaligned(Host, host, at, width, strict)) return error.Unaligned;
    if (comptime writable(Host)) {
        const span = host.span(at, .{ .kind = .write, .bytes = width / 8 });
        if (span.len >= width / 8) {
            @branchHint(.likely);
            std.mem.writeInt(std.meta.Int(.unsigned, width), span[0 .. width / 8], @truncate(value), .little);
            return;
        }
    }
    _ = try host.access(at, .{ .kind = .write, .bytes = width / 8 }, value);
}

/// Consecutive-word access run for load and store multiple, push and pop, A6.7.40 and B3.2.20.
pub fn Run(comptime Host: type) type {
    return struct {
        host: *Host,
        at: u32,
        held: Span(Host) = &.{},

        const Self = @This();

        /// Reads the next word of the run and advances past it.
        pub fn read(self: *Self) Failure!u32 {
            if (self.held.len >= 4) return self.next();
            self.host.touch(self.at);
            if (misaligned(Host, self.host, self.at, 32, true)) return error.Unaligned;
            self.held = self.host.span(self.at, .{ .kind = .read, .bytes = 4 });
            if (self.held.len >= 4) return self.next();
            defer self.at +%= 4;
            return self.host.access(self.at, .{ .kind = .read, .bytes = 4 }, 0);
        }

        /// Writes the next word of the run and advances past it.
        pub fn write(self: *Self, value: u32) Failure!void {
            if (comptime writable(Host)) {
                if (self.held.len >= 4) return self.put(value);
                self.host.touch(self.at);
                if (misaligned(Host, self.host, self.at, 32, true)) return error.Unaligned;
                self.held = self.host.span(self.at, .{ .kind = .write, .bytes = 4 });
                if (self.held.len >= 4) return self.put(value);
            } else {
                self.host.touch(self.at);
                if (misaligned(Host, self.host, self.at, 32, true)) return error.Unaligned;
            }
            defer self.at +%= 4;
            _ = try self.host.access(self.at, .{ .kind = .write, .bytes = 4 }, value);
        }

        fn next(self: *Self) u32 {
            defer self.step();
            return word(self.held, 32);
        }

        fn put(self: *Self, value: u32) void {
            defer self.step();
            std.mem.writeInt(u32, self.held[0..4], value, .little);
        }

        fn step(self: *Self) void {
            self.held = self.held[4..];
            self.at +%= 4;
        }
    };
}

/// Fetches the halfword at an address and keeps the rest of its span, A6.1.
pub inline fn fetch(comptime Host: type, host: *Host, at: u32, held: *Span(Host)) Failure!u16 {
    const span = host.span(at, .{ .kind = .fetch, .bytes = 2 });
    if (span.len < 2) {
        @branchHint(.unlikely);
        held.* = &.{};
        return @truncate(try host.access(at, .{ .kind = .fetch, .bytes = 2 }, 0));
    }
    held.* = span[2..];
    return std.mem.readInt(u16, span[0..2], .little);
}

/// Second halfword of a 32-bit instruction, from the held span or a fresh fetch.
pub inline fn halfword(comptime Host: type, host: *Host, held: *Span(Host), at: u32) Failure!u16 {
    if (held.len >= 2) {
        @branchHint(.likely);
        defer held.* = held.*[2..];
        return std.mem.readInt(u16, held.*[0..2], .little);
    }
    return fetch(Host, host, at, held);
}
