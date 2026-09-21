//! The decode groups of the Arm T32 sets. Names the row groups an architecture may hold, maps
//! each architecture to its groups, and pairs those groups with the xPSR mask the step loop
//! tests, which is what the generated tree is gated on.
const Architecture = @import("architecture.zig").Architecture;
const State = @import("state.zig").State;

/// Row groups an architecture may include.
pub const Group = enum(u4) {
    v6m,
    v7m,
    main,
    dsp,
    v8m,
    v8m_main,
    v8_1m,
    mve,
};

/// Bit set of groups.
pub const Groups = u16;

/// The groups word holding exactly the listed groups.
pub fn only(comptime list: []const Group) Groups {
    comptime {
        var out: Groups = 0;
        for (list) |g| out |= @as(Groups, 1) << @intFromEnum(g);
        return out;
    }
}

/// The groups word with every group this family models.
pub const every = only(&.{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main, .v8_1m, .mve });

const architecture_groups = blk: {
    var out: [@typeInfo(Architecture).@"enum".fields.len]Groups = undefined;
    out[@intFromEnum(Architecture.armv6m)] = only(&.{.v6m});
    out[@intFromEnum(Architecture.armv8m_base)] = only(&.{ .v6m, .v7m, .v8m });
    out[@intFromEnum(Architecture.armv7m)] = only(&.{ .v6m, .v7m, .main });
    out[@intFromEnum(Architecture.armv7em)] = only(&.{ .v6m, .v7m, .main, .dsp });
    out[@intFromEnum(Architecture.armv8m_main)] = only(&.{ .v6m, .v7m, .main, .dsp, .v8m, .v8m_main });
    out[@intFromEnum(Architecture.armv8_1m_main)] = every;
    break :blk out;
};

fn groupsOf(a: Architecture) Groups {
    return architecture_groups[@intFromEnum(a)];
}

/// What one architecture decodes with: itself, its groups and its xPSR mask.
pub const Selection = struct {
    architecture: Architecture,
    groups: Groups,
    xpsr_mask: u32,
};

/// Selection for an architecture: its groups and the xPSR bits the step loop tests.
pub fn selectionOf(a: Architecture) Selection {
    return .{
        .architecture = a,
        .groups = groupsOf(a),
        .xpsr_mask = if (a == .armv8_1m_main) State.flag_t | State.it_mask | State.flag_b else if (a.main()) State.flag_t | State.it_mask else State.flag_t,
    };
}
