//! Register masks of a code from its meta entry. An entry places up to four register operands in
//! the code and gives each its role bits, a lane apiece: written at bit 0, source at 16, address at
//! 32, shifted by the operand's fixed register offset. A lookup shifts each operand's lanes by the
//! register its field holds and joins them with the implied registers and the register list.
//! Operand 0 may join a second bit run and name nothing at r15; operand 1 may take its written
//! role from the writeback bit.

const Class = @import("instruction.zig").Class;

/// Registers a code writes, reads as sources and forms its memory address from, one bit each.
pub const Masks = packed struct(u64) { written: u16, sources: u16, addressed: u16, _: u16 = 0 };

/// A row's or alias's class and where its registers sit in a code.
pub const Entry = struct {
    class: Class = .data_processing,
    lanes: [4]u64 = @splat(0),
    shift: [4]u5 = @splat(0),
    mask: [4]u8 = @splat(0),
    split: u5 = 0,
    split_mask: u8 = 0,
    keep: u64 = ~@as(u64, 0),
    writeback: u5 = 0,
    writeback_mask: u8 = 0,
    writeback_at: u6 = 0,
    list: u32 = 0,
    list_high: u32 = 0,
    list_shift: u5 = 0,
    list_lane: u6 = 0,
    fixed: u64 = 0,
};

/// The masks of a code under its entry.
pub fn of(e: *const Entry, code: u32) Masks {
    const first = ((code >> e.shift[0]) & e.mask[0]) | ((code >> e.split) & e.split_mask);
    const based = e.lanes[1] | @as(u64, (code >> e.writeback) & e.writeback_mask) << e.writeback_at;
    const list = (code & e.list) | ((code & e.list_high) << e.list_shift);
    var lanes = e.fixed | @as(u64, list) << e.list_lane;
    lanes |= (e.lanes[0] << @intCast(first)) & e.keep;
    lanes |= based << @intCast((code >> e.shift[1]) & e.mask[1]);
    inline for (2..4) |k| lanes |= e.lanes[k] << @intCast((code >> e.shift[k]) & e.mask[k]);
    return @bitCast(lanes);
}
