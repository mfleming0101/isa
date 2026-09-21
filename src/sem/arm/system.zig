//! System-instruction semantics for the T32 rows: SVC, the WFE, WFI and SEV sleep hints and the
//! wide hint space including PACBTI, CPS, MSR and MRS over the special registers and the Security
//! Extension's banked copies, SG, TT and its variants, and CLRM. Rows take the machine state, host
//! host and decoded fields and return an `Outcome`; anything that changes which exceptions the core
//! may take is signalled to the host. root.zig binds each row to its name for the generated
//! decoder.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const pac = root.pac;

/// SVC, A7.7.175: reported to the host, which enters the handler.
pub fn svc(s: *State, host: anytype, i: u32) Outcome {
    _ = .{ s, host, i };
    return .supervisor_call;
}

/// WFE: the host holds the wait until an event or deliverable exception arrives, B1.5.18.
pub fn wfe(s: *State, host: anytype) Outcome {
    _ = s;
    host.sleep(.event);
    return .next;
}

/// WFI: the host holds the wait until a deliverable exception arrives, B1.5.19.
pub fn wfi(s: *State, host: anytype) Outcome {
    _ = s;
    host.sleep(.interrupt);
    return .next;
}

/// SEV, A7.7.129: sets the event register so the next WFE retires, B1.5.18.
pub fn sev(s: *State, host: anytype) Outcome {
    _ = s;
    host.event();
    return .next;
}

/// The wide hint space: WFE.W, WFI.W, SEV.W, the PACBTI hints on a core carrying them, else NOP.
pub fn hint(s: *State, host: anytype, h: u32) Outcome {
    const Host = root.Host(@TypeOf(host));
    return switch (h) {
        0x02 => wfe(s, host),
        0x03 => wfi(s, host),
        0x04 => sev(s, host),
        pac.pac_hint => pac.sign(Host, s, host, false),
        pac.pacbti_hint => pac.sign(Host, s, host, true),
        pac.aut_hint => pac.authenticate(Host, s, host),
        pac.bti_hint => {
            pac.cleared(s);
            return .next;
        },
        else => .next,
    };
}

/// CPS, A7.7.29: writes PRIMASK and FAULTMASK when privileged and re-arms the host, B1.5.16.
pub fn Cps(comptime disable: bool, comptime interrupt: bool, comptime fault: bool) type {
    return struct {
        /// Sets or clears the masks when privileged and re-arms the host.
        pub fn call(s: *State, host: anytype) Outcome {
            if (!s.privileged()) return .next;
            if (interrupt) s.primask = disable;
            if (fault and (!disable or s.maskable())) s.faultmask = disable;
            host.rearm();
            return .next;
        }
    };
}

fn priorityMask(host: anytype) u32 {
    return (@as(u32, 0xff) << @intCast(8 - host.priorityBits())) & 0xff;
}

fn apsrMask(host: anytype) u32 {
    return if (!host.architecture().main()) 0xf000_0000 else 0xf800_0000;
}

fn geMask(host: anytype) u32 {
    return switch (host.architecture()) {
        .armv7em, .armv8m_main, .armv8_1m_main => State.flag_ge,
        else => 0,
    };
}

fn limited(host: anytype, secure: bool) bool {
    const stack_limits = switch (host.architecture()) {
        .armv8m_base, .armv8m_main, .armv8_1m_main => true,
        else => false,
    };
    return stack_limits and (secure or host.architecture().main());
}

fn treatAsSecure(host: anytype) bool {
    const Host = root.Host(@TypeOf(host));
    return @hasDecl(Host, "treatAsSecure") and host.treatAsSecure();
}

fn alternate(host: anytype) ?*State.Banked {
    const Host = root.Host(@TypeOf(host));
    return if (@hasDecl(Host, "alternate")) host.alternate() else null;
}

fn pacbtiMask(host: anytype) u32 {
    return if (host.pacbti()) State.control_bti_en | State.control_ubti_en | State.control_pac_en | State.control_upac_en else 0;
}

/// MSR, A7.7.84: writes a special register by name; the mask picks APSR halves, privilege the rest.
pub fn msr(s: *State, host: anytype, n: u32, a: u32, m: u32) Outcome {
    const value = root.get(s, n);
    const privileged = s.privileged();
    const main_extension = host.architecture().main();
    switch (m >> 3) {
        0 => if (m & 4 == 0) {
            const mask = (if (a & 2 != 0) apsrMask(host) else 0) | (if (a & 1 != 0) geMask(host) else 0);
            s.xpsr = (s.xpsr & ~mask) | (value & mask);
        },
        1 => switch (m & 7) {
            0 => if (privileged) {
                s.msp = value & ~@as(u32, 3);
            },
            1 => if (privileged) {
                s.psp = value & ~@as(u32, 3);
            },
            2 => if (privileged and limited(host, s.secure)) {
                s.msplim = value & ~@as(u32, 7);
            },
            3 => if (privileged and limited(host, s.secure)) {
                s.psplim = value & ~@as(u32, 7);
            },
            else => {},
        },
        2 => switch (m & 7) {
            0 => if (privileged) {
                s.primask = value & 1 != 0;
                host.rearm();
            },
            1, 2 => if (main_extension and privileged) {
                const masked: u8 = @truncate(value & priorityMask(host));
                if (m & 7 == 1 or (masked != 0 and (s.basepri == 0 or masked < s.basepri))) s.basepri = masked;
                host.rearm();
            },
            3 => if (main_extension and privileged and (value & 1 == 0 or s.maskable())) {
                s.faultmask = value & 1 != 0;
                host.rearm();
            },
            4 => {
                if (privileged) {
                    const context = if (treatAsSecure(host)) State.control_fpca else 0;
                    s.control = (value & (State.control_npriv | context | pacbtiMask(host))) | (if (s.handler()) s.control & State.control_spsel else value & State.control_spsel);
                }
                if (treatAsSecure(host) and host.security() and s.secure) {
                    s.control = (s.control & ~State.control_sfpa) | (value & State.control_sfpa);
                }
            },
            else => {},
        },
        4 => if (host.pacbti() and privileged) {
            s.pac_key[m & 7] = value;
        },
        17, 18, 19, 20 => if (host.security() and s.secure and privileged) {
            if (alternate(host)) |other| writeAlternate(s, host, other, @truncate(m), value);
        },
        else => {},
    }
    return .next;
}

fn writeAlternate(s: *State, host: anytype, other: *State.Banked, m: u8, value: u32) void {
    const main_extension = host.architecture().main();
    switch (m) {
        0x88 => other.msp = value & ~@as(u32, 3),
        0x89 => other.psp = value & ~@as(u32, 3),
        0x8a => if (main_extension) {
            other.msplim = value & ~@as(u32, 7);
        },
        0x8b => if (main_extension) {
            other.psplim = value & ~@as(u32, 7);
        },
        0x90 => {
            other.primask = value & 1 != 0;
            host.rearm();
        },
        0x91 => if (main_extension) {
            other.basepri = @truncate(value & priorityMask(host));
            host.rearm();
        },
        0x93 => if (main_extension) {
            other.faultmask = value & 1 != 0;
            host.rearm();
        },
        0x94 => other.control = value & (State.control_npriv | State.control_spsel | State.control_fpca | pacbtiMask(host)),
        0x98 => alternateStack(s, other).* = value & ~@as(u32, 3),
        0xa0...0xa7 => if (host.pacbti()) {
            other.pac_key[m & 7] = value;
        },
        else => {},
    }
}

fn alternateStack(s: *State, other: *State.Banked) *u32 {
    if (!s.handler() and other.control & State.control_spsel != 0) return &other.psp;
    return &other.msp;
}

/// MRS, A7.7.83: reads a special register by name; an absent or unprivileged name reads zero.
pub fn mrs(s: *State, host: anytype, d: u32, m: u32) Outcome {
    const privileged = s.privileged();
    const main_extension = host.architecture().main();
    var value: u32 = 0;
    switch (m >> 3) {
        0 => {
            if (m & 1 != 0) value |= s.xpsr & State.ipsr_mask;
            if (m & 4 == 0) value |= s.xpsr & (apsrMask(host) | geMask(host));
        },
        1 => switch (m & 7) {
            0 => if (privileged) {
                value = s.msp;
            },
            1 => if (privileged) {
                value = s.psp;
            },
            2 => if (privileged and limited(host, s.secure)) {
                value = s.msplim;
            },
            3 => if (privileged and limited(host, s.secure)) {
                value = s.psplim;
            },
            else => {},
        },
        2 => switch (m & 7) {
            0 => if (privileged and s.primask) {
                value = 1;
            },
            1, 2 => if (main_extension and privileged) {
                value = s.basepri;
            },
            3 => if (main_extension and privileged and s.faultmask) {
                value = 1;
            },
            4 => {
                const unprivileged = State.control_ubti_en | State.control_upac_en;
                const gates = pacbtiMask(host) & (if (privileged) ~@as(u32, 0) else unprivileged);
                value = s.control & (State.control_npriv | State.control_spsel | State.control_fpca | State.control_sfpa | gates);
            },
            else => {},
        },
        4 => if (host.pacbti() and privileged) {
            value = s.pac_key[m & 7];
        },
        17, 18, 19, 20 => if (host.security() and s.secure and privileged) {
            if (alternate(host)) |other| value = readAlternate(s, host, other, @truncate(m));
        },
        else => {},
    }
    root.set(s, d, value);
    return .next;
}

fn readAlternate(s: *State, host: anytype, other: *State.Banked, m: u8) u32 {
    const main_extension = host.architecture().main();
    return switch (m) {
        0x88 => other.msp,
        0x89 => other.psp,
        0x8a => if (main_extension) other.msplim else 0,
        0x8b => if (main_extension) other.psplim else 0,
        0x90 => @intFromBool(other.primask),
        0x91 => if (main_extension) other.basepri else 0,
        0x93 => @intFromBool(main_extension and other.faultmask),
        0x94 => other.control & (State.control_npriv | State.control_spsel | State.control_fpca | pacbtiMask(host)),
        0x98 => alternateStack(s, other).*,
        0xa0...0xa7 => if (host.pacbti()) other.pac_key[m & 7] else 0,
        else => 0,
    };
}

/// SG: a Secure gateway; entry from Non-secure code switches to Secure and clears the IT state.
pub fn sg(s: *State, host: anytype) Outcome {
    const Host = root.Host(@TypeOf(host));
    pac.cleared(s);
    if (@hasDecl(Host, "attribute")) {
        if (host.attribute(s.pc, true).ns) return .next;
        if (!s.secure) {
            s.lr &= ~@as(u32, 1);
            s.control &= ~State.control_sfpa;
            s.secure = true;
            if (@hasDecl(Host, "bank")) host.bank();
        }
        s.xpsr &= ~State.it_mask;
    }
    return .next;
}

const tt_r: u32 = 1 << 18;
const tt_rw: u32 = 1 << 19;
const tt_nsr: u32 = 1 << 20;
const tt_nsrw: u32 = 1 << 21;
const tt_s: u32 = 1 << 22;
const tt_srvalid: u32 = 1 << 17;

fn probedControl(comptime alt: bool, s: *State, host: anytype) u32 {
    if (!alt) return s.control;
    const other = alternate(host) orelse return s.control;
    return other.control;
}

/// TT, TTT, TTA and TTAT: test target address for region, security and access permissions.
pub fn Tt(comptime alt: bool, comptime forced_unpriv: bool) type {
    return struct {
        /// Writes the TT response for the address in Rn into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32) Outcome {
            const Host = root.Host(@TypeOf(host));
            const secure = host.security() and s.secure;
            if (alt and !secure) return .undefined;
            const at = root.get(s, n);
            var resp: u32 = 0;
            var address_secure = false;
            if (@hasDecl(Host, "attribute")) {
                if (secure) {
                    const found = host.attribute(at, false);
                    address_secure = !found.ns;
                    if (address_secure) resp |= tt_s;
                    if (found.region) |r| resp |= tt_srvalid | @as(u32, r) << 8;
                }
            }
            if (s.privileged() or alt) {
                const privileged = !forced_unpriv and
                    (s.handler() or probedControl(alt, s, host) & State.control_npriv == 0);
                var readable = true;
                var writable = true;
                if (@hasDecl(Host, "accessible")) {
                    const reach = host.accessible(at, privileged, secure and !alt);
                    readable = reach.read;
                    writable = reach.write;
                }
                if (readable) resp |= tt_r;
                if (writable) resp |= tt_rw;
                if (secure and !address_secure) {
                    if (readable) resp |= tt_nsr;
                    if (writable) resp |= tt_nsrw;
                }
            }
            root.set(s, d, resp);
            return .next;
        }
    };
}

/// CLRM: zeroes the listed registers, lr when named, and the APSR when asked.
pub fn clrm(s: *State, host: anytype, a: u32, l: u32, r: u32) Outcome {
    var list = r;
    while (list != 0) : (list &= list - 1) s.r[@ctz(list)] = 0;
    if (l == 1) s.lr = 0;
    if (a == 1) s.xpsr &= ~(apsrMask(host) | geMask(host));
    return .next;
}
