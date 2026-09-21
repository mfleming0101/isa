//! The flat reference memory every semantic test and bench alternative runs on: the caller's
//! slice at a base address with the exclusive monitor's tag beside it. No interrupts, no protection
//! unit, no device model. `span` answers the span contract from the single block, `access`
//! refuses everything off its end, and monitor is the local exclusive monitor. Both reference
//! hosts delegate their memory declarations to it.

/// Byte length the bench gives the backing store, 16 MiB.
pub const size = 16 << 20;

/// Flat backing store with the exclusive monitor's tag; no interrupts, protection or devices.
pub const Memory = struct {
    bytes: []u8,
    base: u32,
    exclusive: ?u32 = null,

    /// The only refusal: an access off the end of the store.
    pub const Failure = error{DataFault};

    /// Bytes from address to the end of the store, or empty when the access does not fit.
    pub fn span(self: *Memory, address: u32, comptime a: anytype) []u8 {
        const offset = address -% self.base;
        if (@as(u64, offset) + a.bytes > self.bytes.len) return &.{};
        return self.bytes[offset..];
    }

    /// Refuses with DataFault, since nothing beyond the store is modelled.
    pub fn access(self: *Memory, address: u32, comptime a: anytype, value: u32) Failure!u32 {
        _ = .{ self, address, a, value };
        return error.DataFault;
    }

    /// Ignores the lookup address; no fault address register is kept.
    pub fn touch(_: *Memory, _: u32) void {}

    /// The local exclusive monitor's tag, the one core's whole reservation.
    pub fn monitor(self: *Memory) *?u32 {
        return &self.exclusive;
    }
};
