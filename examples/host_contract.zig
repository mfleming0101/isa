const std = @import("std");
const isa = @import("isa");

const Host = struct {
    inner: @import("host").arm.Host,

    pub fn span(self: *Host, address: u32, comptime a: anytype) []u8 {
        return self.inner.span(address, a);
    }
    pub fn access(self: *Host, address: u32, comptime a: anytype, value: u32) !u32 {
        return self.inner.access(address, a, value);
    }
    pub fn touch(self: *Host, address: u32) void {
        self.inner.touch(address);
    }
    pub fn trapsUnaligned(_: *Host) bool {
        return true; // CCR.UNALIGN_TRP set, unlike the reference host
    }
    pub fn architecture(self: *Host) isa.arm.Architecture {
        return self.inner.architecture();
    }
    pub fn security(self: *Host) bool {
        return self.inner.security();
    }
    pub fn pacbti(self: *Host) bool {
        return self.inner.pacbti();
    }
    pub fn priorityBits(self: *Host) u4 {
        return self.inner.priorityBits();
    }
    pub fn trapsDivideByZero(self: *Host) bool {
        return self.inner.trapsDivideByZero();
    }
    pub fn mve(self: *Host) bool {
        return self.inner.mve();
    }
    pub fn floatingPoint(self: *Host) bool {
        return self.inner.floatingPoint();
    }
    pub fn coprocessorEnabled(self: *Host) bool {
        return self.inner.coprocessorEnabled();
    }
    pub fn doublePrecision(self: *Host) bool {
        return self.inner.doublePrecision();
    }
    pub fn halfPrecision(self: *Host) bool {
        return self.inner.halfPrecision();
    }
    pub fn fpv5(self: *Host) bool {
        return self.inner.fpv5();
    }
    pub fn automaticFpState(self: *Host) bool {
        return self.inner.automaticFpState();
    }
    pub fn defaultFpscr(self: *Host) u32 {
        return self.inner.defaultFpscr();
    }
    pub fn lazyFpFrame(self: *Host) ?u32 {
        return self.inner.lazyFpFrame();
    }
    pub fn lazyFpEnabled(self: *Host) bool {
        return self.inner.lazyFpEnabled();
    }
    pub fn lazyFpCallee(self: *Host) bool {
        return self.inner.lazyFpCallee();
    }
    pub fn treatAsSecure(self: *Host) bool {
        return self.inner.treatAsSecure();
    }
    pub fn nonSecureFpscr(self: *Host) u32 {
        return self.inner.nonSecureFpscr();
    }
    pub fn signal(self: *Host, which: isa.arm.step.Signal) void {
        self.inner.signal(which);
    }
    pub fn rearm(self: *Host) void {
        self.inner.rearm();
    }
    pub fn sleep(self: *Host, kind: isa.arm.step.Wait) void {
        self.inner.sleep(kind);
    }
    pub fn event(self: *Host) void {
        self.inner.event();
    }
    pub fn setLazyFp(self: *Host, frame: ?u32) void {
        self.inner.setLazyFp(frame);
    }
};

comptime {
    isa.contract.assertHost(Host, &isa.contract.arm_requirements);
}

test "a host that traps unaligned accesses turns ldr r0, [r1] at an odd address into a fault" {
    const decode = isa.generated.arm_decode;
    const armv7m = isa.arm.decode.selectionOf(.armv7m).groups;
    const ldr: u32 = 0x6808; // ldr r0, [r1]
    var ram = [_]u8{0} ** 64;
    var host: Host = .{ .inner = .{ .memory = .{ .bytes = &ram, .base = 0 } } };
    var s: isa.arm.State = .{};
    s.r[1] = 1;

    const done = decode.executeNarrow(Host, &s, &host, ldr, armv7m);
    try std.testing.expectEqual(.unaligned, done.outcome);

    const reference = decode.executeNarrow(@import("host").arm.Host, &s, &host.inner, ldr, armv7m);
    try std.testing.expectEqual(.next, reference.outcome);
}
