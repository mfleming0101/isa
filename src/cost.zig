//! One saturating cycle charge shared by both step loops. Result.cycles is eight bits and a load
//! multiple or taken branch adds to its class cost, so the sum clamps at 255 instead of wrapping.

/// Adds extra to cost, saturating at 255 rather than wrapping the eight-bit cycle field.
pub fn charge(cost: u8, extra: u8) u8 {
    return cost +| extra;
}
