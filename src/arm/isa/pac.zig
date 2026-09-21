//! Pointer authentication and branch target identification for Armv8.1-M. Holds the
//! implementation-defined authentication code algorithm, the hint values of the PACBTI,
//! BTI, PAC and AUT instructions, the executors that sign LR, authenticate it, mark a
//! landing and run PACG, AUTG and BXAUT, and the interworking branch BXAUT takes.
const instruction = @import("instruction.zig");
const State = @import("state.zig").State;

const Outcome = instruction.Outcome;
const Failure = instruction.Failure;

/// Implementation-defined authentication code of a pointer under a modifier and key.
pub fn compute(pointer: u32, modifier: u32, key: *const [4]u32) u32 {
    const cipher = @as(u64, key[1]) << 32 | key[0];
    const whitening = @as(u64, key[3]) << 32 | key[2];
    var v = (@as(u64, pointer) << 32 | modifier) ^ whitening;
    for (0..4) |_| {
        v = (v ^ v >> 31 ^ cipher) *% (cipher | 1);
        v = v << 17 | v >> 47;
        v +%= 0x9e37_79b9_7f4a_7c15;
    }
    return @truncate(v ^ v >> 32);
}

/// Hint value of PACBTI.
pub const pacbti_hint: u8 = 0x0d;
/// Hint value of BTI.
pub const bti_hint: u8 = 0x0f;
/// Hint value of PAC.
pub const pac_hint: u8 = 0x1d;
/// Hint value of AUT.
pub const aut_hint: u8 = 0x2d;

/// Sets EPSR.B after an indirect branch when BTI is enabled for the current privilege.
pub fn land(comptime Host: type, s: *State, host: *Host) void {
    if (!host.pacbti()) return;
    if (s.control & (if (s.privileged()) State.control_bti_en else State.control_ubti_en) != 0) s.xpsr |= State.flag_b;
}

/// Clears EPSR.B, marking a valid branch target.
pub fn cleared(s: *State) void {
    s.xpsr &= ~State.flag_b;
}

fn enabled(comptime Host: type, s: *const State, host: *Host) bool {
    if (!host.pacbti()) return false;
    return s.control & (if (s.privileged()) State.control_pac_en else State.control_upac_en) != 0;
}

fn create(s: *const State, pointer: u32, modifier: u32) u32 {
    return compute(pointer, modifier, s.pacKey());
}

/// Executes PAC or PACBTI: signs LR with SP into r12 when enabled.
pub fn sign(comptime Host: type, s: *State, host: *Host, comptime lands: bool) Outcome {
    if (lands) cleared(s);
    if (enabled(Host, s, host)) s.r[12] = create(s, s.lr, s.sp());
    return .next;
}

/// Executes AUT: fails authentication when r12 is not the code for LR.
pub fn authenticate(comptime Host: type, s: *State, host: *Host) Outcome {
    if (enabled(Host, s, host) and s.r[12] != create(s, s.lr, s.sp())) return .authentication_failure;
    return .next;
}

/// Executes PACG: writes the code for Rn under modifier Rm to Rd.
pub fn pacg(comptime Host: type, s: *State, host: *Host, d: u4, n: u4, m: u4) Outcome {
    if (enabled(Host, s, host)) s.set(d, create(s, s.get(n), s.get(m)));
    return .next;
}

/// Executes AUTG or BXAUT: checks Ra against Rn under Rm, then optionally branches to Rn.
pub fn autg(comptime Host: type, s: *State, host: *Host, comptime branches: bool, a: u4, n: u4, m: u4) Outcome {
    const address = s.get(n);
    if (enabled(Host, s, host) and s.get(a) != create(s, address, s.get(m))) return .authentication_failure;
    return if (branches) interwork(s, address) else .next;
}

const fnc_return: u32 = 0xfeff_fffe;

fn interwork(s: *State, address: u32) Outcome {
    if (address >= 0xf000_0000 and s.handler()) {
        s.pc = address;
        return .exception_return;
    }
    if (address | 1 == fnc_return | 1 and !s.secure) {
        s.pc = address;
        return .function_return;
    }
    s.branchTo(address);
    return .branched;
}
