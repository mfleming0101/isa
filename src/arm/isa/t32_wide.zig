//! The parts of the 32-bit T32 set the library still computes with: the long shift kinds the
//! MVE scalar shifts apply, with their saturation, and the test of whether the instruction at a
//! branch target is a valid BTI landing.
const access = @import("access.zig");
const pac = @import("pac.zig");

const bkpt_mask: u16 = 0xff00;
const bkpt_match: u16 = 0xbe00;
const sg: u32 = 0xe97f_e97f;
const hint_mask: u32 = 0xffff_ff00;
const hint_match: u32 = 0xf3af_8000;

/// Long shift operation kinds.
pub const LongShift = enum { lsl, lsr, asr, sqshl, uqshl, srshr, urshr, sqrshr, uqrshl };

const Wide = i256;

fn shiftWide(value: Wide, amount: i32) Wide {
    return if (amount >= 0) value << @intCast(amount) else value >> @intCast(-amount);
}

fn powerOf(amount: i32) Wide {
    return if (amount >= 0) @as(Wide, 1) << @intCast(amount) else 0;
}

fn satSigned(raw: Wide, to: u9, q: *bool) Wide {
    const max = (@as(Wide, 1) << @intCast(to - 1)) - 1;
    if (raw > max) {
        q.* = true;
        return max;
    }
    if (raw < -max - 1) {
        q.* = true;
        return -max - 1;
    }
    return raw;
}

fn satUnsigned(raw: Wide, to: u9, q: *bool) Wide {
    const max = (@as(Wide, 1) << @intCast(to)) - 1;
    if (raw > max) {
        q.* = true;
        return max;
    }
    if (raw < 0) {
        q.* = true;
        return 0;
    }
    return raw;
}

/// Applies a long shift to a value, saturating where the kind asks and setting q.
pub fn longShift(comptime kind: LongShift, comptime width: u9, value: u64, amount: i32, to: u9, q: *bool) u64 {
    const signed: Wide = if (width == 64) @as(i64, @bitCast(value)) else @as(i32, @bitCast(@as(u32, @truncate(value))));
    const unsigned: Wide = value;
    const raw: Wide = switch (kind) {
        .lsl => shiftWide(unsigned, amount),
        .lsr => shiftWide(unsigned, -amount),
        .asr => shiftWide(signed, -amount),
        .sqshl => satSigned(shiftWide(signed, amount), width, q),
        .uqshl => satUnsigned(shiftWide(unsigned, amount), width, q),
        .srshr => shiftWide(signed + powerOf(amount - 1), -amount),
        .urshr => shiftWide(unsigned + powerOf(amount - 1), -amount),
        .sqrshr => satSigned(shiftWide(signed + powerOf(amount - 1), -amount), to, q),
        .uqrshl => satUnsigned(shiftWide(unsigned + powerOf(-1 - amount), amount), to, q),
    };
    return @truncate(@as(u256, @bitCast(raw)));
}

/// Whether the instruction at an address is a valid BTI landing: BKPT, SG, BTI or PACBTI.
pub fn lands(comptime Host: type, host: *Host, held: *access.Span(Host), address: u32, hw1: u16) bool {
    if (hw1 & bkpt_mask == bkpt_match) return true;
    if (hw1 != sg >> 16 and hw1 != hint_match >> 16) return false;
    const hw2 = access.halfword(Host, host, held, address +% 2) catch return false;
    const code = @as(u32, hw1) << 16 | hw2;
    if (code == sg) return true;
    if (code & hint_mask != hint_match) return false;
    const value: u8 = @truncate(code);
    return value == pac.bti_hint or value == pac.pacbti_hint;
}
