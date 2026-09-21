//! The decode groups of the RV32 row set. One `Group` per extension; a core's `Groups` word says
//! which groups its generated tree answers for. A parcel whose lowest two bits are 11 opens a
//! 32-bit instruction (section 1.5), which is what `escapes` tells the step loop.

/// One decode group per extension; a core takes or leaves a group whole.
pub const Group = enum(u4) {
    rv32i,
    m,
    a,
    c,
    zicsr,
    f,
};

/// A bit set of groups, one bit per `Group`.
pub const Groups = u16;

/// The groups word holding exactly the listed groups.
pub fn only(comptime list: []const Group) Groups {
    comptime {
        var out: Groups = 0;
        for (list) |g| out |= @as(Groups, 1) << @intFromEnum(g);
        return out;
    }
}

/// The groups word with every extension this family models.
pub const every = only(&.{ .rv32i, .m, .a, .c, .zicsr, .f });

const wide_prefix: u2 = 0b11;

/// Whether a code opens a 32-bit instruction rather than a compressed one.
pub fn escapes(code: u32) bool {
    return @as(u2, @truncate(code)) == wide_prefix;
}
