//! Control-flow semantics for the T32 rows: B, BL, BLX, BX, the conditional and compare-and-branch
//! forms, table branches, IT, the Security Extension's BXNS and BLXNS, and the Armv8.1-M
//! low-overhead loops. Rows take the machine state, host and decoded fields and return an
//! `Outcome`; root.zig binds them to row names for the generated decoder. The `target*` functions
//! compute branch destinations from encoded fields and are shared with the disassembler.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const pac = root.pac;

/// B T2, A7.7.12: an eleven-bit halfword offset from the following instruction.
pub fn b(s: *State, host: anytype, i: u32) Outcome {
    _ = host;
    s.pc = targetB(s.pc, i);
    return .branched;
}

/// BL T1, A7.7.18: links the return address with the T bit set, then branches.
pub fn bl(s: *State, host: anytype, sign: u32, i: u32, j: u32) Outcome {
    _ = host;
    const to = targetBl(s.pc, sign, i, j);
    s.lr = (s.pc +% 4) | 1;
    s.pc = to;
    return .branched;
}

/// The fourteen condition codes a branch or IT block can name.
pub const Cond = enum { eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le };

/// ConditionPassed, A7.3: tests the condition against the flags.
pub fn passes(flags: u32, comptime c: Cond) bool {
    const n = flags & root.flag_n != 0;
    const z = flags & root.flag_z != 0;
    const carry = flags & root.flag_c != 0;
    const v = flags & root.flag_v != 0;
    return switch (c) {
        .eq => z,
        .ne => !z,
        .cs => carry,
        .cc => !carry,
        .mi => n,
        .pl => !n,
        .vs => v,
        .vc => !v,
        .hi => carry and !z,
        .ls => !carry or z,
        .ge => n == v,
        .lt => n != v,
        .gt => !z and n == v,
        .le => z or n != v,
    };
}

/// B T1, A7.7.12: a conditional branch with an eight-bit halfword offset.
pub fn Narrow(comptime c: Cond) type {
    return struct {
        /// Branches when the condition passes, else falls through.
        pub fn call(s: *State, host: anytype, i: u32) Outcome {
            _ = host;
            if (!passes(s.xpsr, c)) return .next;
            s.pc = targetCond(s.pc, i);
            return .branched;
        }
    };
}

/// B T3, A7.7.12: a conditional wide branch with a twenty-bit halfword offset.
pub fn Wide(comptime c: Cond) type {
    return struct {
        /// Branches when the condition passes, else falls through.
        pub fn call(s: *State, host: anytype, sign: u32, i: u32, j: u32) Outcome {
            _ = host;
            if (!passes(s.xpsr, c)) return .next;
            s.pc = targetWide(s.pc, sign, i, j);
            return .branched;
        }
    };
}

/// B T3 target, A7.7.12: J2 and J1 sit above the six-bit field; twenty-bit halfword offset.
pub fn targetWide(pc: u32, sign: u32, i: u32, j: u32) u32 {
    const joined = sign << 19 | (j & 1) << 18 | (j >> 1) << 17 | i;
    return pc +% 4 +% (sext(20, joined) *% 2);
}

/// B T4, A7.7.12: BL's offset without BL's link.
pub fn bw(s: *State, host: anytype, sign: u32, i: u32, j: u32) Outcome {
    _ = host;
    s.pc = targetBl(s.pc, sign, i, j);
    return .branched;
}

/// BLX (register), A7.7.19: links pc+2 with the T bit set; never a return.
pub fn blx(s: *State, host: anytype, m: u32) Outcome {
    const to = root.get(s, m);
    s.lr = (s.pc +% 2) | 1;
    pac.land(root.Host(@TypeOf(host)), s, host);
    s.branchTo(to);
    return .branched;
}

/// CBNZ, A7.7.21: branches forward when Rn is non-zero.
pub fn cbnz(s: *State, host: anytype, i: u32, n: u32) Outcome {
    _ = host;
    if (s.r[n] == 0) return .next;
    s.pc = targetCbz(s.pc, i, n);
    return .branched;
}

/// TBB and TBH, A7.7.185: a byte or halfword table entry as a forward halfword count.
pub fn Table(comptime halfword: bool) type {
    return struct {
        /// Reads the table entry at Rn indexed by Rm and branches by it.
        pub fn call(s: *State, host: anytype, n: u32, m: u32) Outcome {
            const index = root.get(s, m);
            const at = root.get(s, n) +% (if (halfword) index *% 2 else index);
            const step = root.read(host, at, if (halfword) 16 else 8, false, false) catch |err| return Outcome.faulted(err);
            s.pc = s.pc +% 4 +% step *% 2;
            return .branched;
        }
    };
}

/// BX, A7.7.20: interworks to Rm, or returns via EXC_RETURN or FNC_RETURN.
pub fn bx(s: *State, host: anytype, m: u32) Outcome {
    return interwork(root.Host(@TypeOf(host)), s, host, root.get(s, m), m != 14);
}

/// The FNC_RETURN address a Non-secure function call returns through.
pub const fnc_return: u32 = 0xfeff_fffe;

/// Where a computed branch lands: exception return, function return, or an ordinary branch that may
/// set the landing pad.
pub fn interwork(comptime Host: type, s: *State, host: *Host, address: u32, lands: bool) Outcome {
    if (address >= 0xf000_0000 and s.handler()) {
        s.pc = address;
        return .exception_return;
    }
    if (address | 1 == fnc_return | 1 and !s.secure) {
        s.pc = address;
        return .function_return;
    }
    if (lands) pac.land(Host, s, host);
    s.branchTo(address);
    return .branched;
}

/// `interwork` for a host held by value, which is every row but BX.
pub fn landing(s: *State, host: anytype, address: u32, lands: bool) Outcome {
    return interwork(root.Host(@TypeOf(host)), s, host, address, lands);
}

/// CBZ, A7.7.21: branches forward when Rn is zero.
pub fn cbz(s: *State, host: anytype, i: u32, n: u32) Outcome {
    _ = host;
    if (s.r[n] != 0) return .next;
    s.pc = targetCbz(s.pc, i, n);
    return .branched;
}

/// CBZ and CBNZ target: pc + 4 plus a zero-extended halfword offset.
pub fn targetCbz(pc: u32, i: u32, n: u32) u32 {
    _ = n;
    return pc +% 4 +% (i << 1);
}

/// B T1 target, A7.7.12: an eight-bit signed halfword offset from pc + 4.
pub fn targetCond(pc: u32, i: u32) u32 {
    return pc +% 4 +% (sext(8, i) *% 2);
}

/// B T2 target, A7.7.12: an eleven-bit signed halfword offset from pc + 4.
pub fn targetB(pc: u32, i: u32) u32 {
    return pc +% 4 +% (sext(11, i) *% 2);
}

/// BL T1 target, A7.7.18: I1 and I2 undo the inversion of J1 and J2 against S.
pub fn targetBl(pc: u32, sign: u32, i: u32, j: u32) u32 {
    const hi = ~((j >> 1) ^ sign) & 1;
    const lo = ~(j ^ sign) & 1;
    const joined = sign << 23 | hi << 22 | lo << 21 | i;
    return pc +% 4 +% (sext(24, joined) *% 2);
}

fn sext(comptime width: u6, value: u32) u32 {
    const shift: u5 = @intCast(32 - width);
    return @bitCast(@as(i32, @bitCast(value << shift)) >> shift);
}

/// IT, A7.7.38: opens a block with a condition and a mask; `tail` fixes the mask's low bits.
pub fn It(comptime tail: u8) type {
    return struct {
        /// Sets the IT state from the condition and mask fields.
        pub fn call(s: *State, host: anytype, c: u32, m: u32) Outcome {
            _ = host;
            root.setItState(s, @intCast(c << 4 | tail | m));
            return .next;
        }
    };
}

/// The one-slot IT block, whose mask the encoding spells out in full.
pub fn ItAlone(comptime mask: u8) type {
    return struct {
        /// Sets the IT state from the condition field and the fixed mask.
        pub fn call(s: *State, host: anytype, c: u32) Outcome {
            _ = host;
            root.setItState(s, @intCast(c << 4 | mask));
            return .next;
        }
    };
}

/// BXNS: branches to Rm, switching to Non-secure state when its low bit is clear; Secure only.
pub fn bxns(s: *State, host: anytype, m: u32) Outcome {
    const Host = root.Host(@TypeOf(host));
    if (!s.secure) return .undefined;
    const target = root.get(s, m);
    if (target >= 0xf000_0000 and s.handler()) return interwork(Host, s, host, target, m != 14);
    if (target & 1 == 0) {
        s.control &= ~State.control_sfpa;
        s.secure = false;
        if (@hasDecl(Host, "bank")) host.bank();
    }
    if (m != 14) pac.land(Host, s, host);
    s.branchTo(target | 1);
    return .branched;
}

/// BLXNS: calls Rm, stacking the return state; a clear low bit switches to Non-secure.
pub fn blxns(s: *State, host: anytype, m: u32) Outcome {
    const Host = root.Host(@TypeOf(host));
    if (!s.secure) return .undefined;
    const target = root.get(s, m);
    if (target & 1 != 0) {
        s.lr = (s.pc +% 2) | 1;
        pac.land(Host, s, host);
        s.branchTo(target);
        return .branched;
    }
    const stack: *u32 = if (!s.handler() and s.control & State.control_spsel != 0) &s.psp else &s.msp;
    const frame = (stack.* -% 8) & ~@as(u32, 7);
    const partial = (s.xpsr & State.ipsr_mask) | (s.control & State.control_sfpa) << 17;
    root.write(host, frame, 32, (s.pc +% 2) | 1, true) catch |err| return Outcome.faulted(err);
    root.write(host, frame +% 4, 32, partial, true) catch |err| return Outcome.faulted(err);
    stack.* = frame;
    s.lr = fnc_return | 1;
    s.xpsr = (s.xpsr & ~(State.ipsr_mask | State.it_mask)) | @intFromBool(s.handler());
    s.control &= ~State.control_sfpa;
    s.secure = false;
    if (@hasDecl(Host, "bank")) host.bank();
    pac.land(Host, s, host);
    s.branchTo(target | 1);
    return .branched;
}

const fp = root.fp;

fn loopOffset(j: u32, i: u32) u32 {
    return i << 2 | j << 1;
}

/// WLS: loads LR with the count, or branches past the loop when it is zero.
pub fn whileLoopStart(s: *State, host: anytype, n: u32, j: u32, i: u32) Outcome {
    _ = host;
    const count = root.get(s, n);
    if (count == 0) {
        s.pc = s.pc +% 4 +% loopOffset(j, i);
        return .branched;
    }
    s.lr = count;
    return .next;
}

/// DLS: loads LR with the loop count.
pub fn doLoopStart(s: *State, host: anytype, n: u32) Outcome {
    _ = host;
    s.lr = root.get(s, n);
    return .next;
}

fn invalidState(s: *State, host: anytype) bool {
    const Host = root.Host(@TypeOf(host));
    if (!host.mve() or fp.lib.tailSize(s) == 4) return false;
    if (@hasDecl(Host, "invalidState")) host.invalidState();
    return true;
}

/// LE: decrements LR and branches back while it exceeds one.
pub fn loopEnd(s: *State, host: anytype, j: u32, i: u32) Outcome {
    if (invalidState(s, host)) return .undefined;
    if (s.lr <= 1) return .next;
    s.lr -= 1;
    s.pc = s.pc +% 4 -% loopOffset(j, i);
    return .branched;
}

/// LE with no count: branches back unconditionally.
pub fn loopForever(s: *State, host: anytype, j: u32, i: u32) Outcome {
    if (invalidState(s, host)) return .undefined;
    s.pc = s.pc +% 4 -% loopOffset(j, i);
    return .branched;
}

/// BF and its siblings: branch-future hints, executed as no-ops.
pub fn branchFuture(s: *State, host: anytype, o: u32, p: u32, c: u32, i: u32) Outcome {
    _ = .{ s, host, o, p, c, i };
    return .next;
}

/// The wide branch-future forms, executed as no-ops.
pub fn branchFutureWide(s: *State, host: anytype, top: u32, o: u32, p: u32, c: u32, i: u32) Outcome {
    _ = .{ s, host, top, o, p, c, i };
    return .next;
}

/// WLS target: pc + 4 plus the loop-end offset.
pub fn targetLoopForward(pc: u32, n: u32, j: u32, i: u32) u32 {
    _ = n;
    return pc +% 4 +% loopOffset(j, i);
}

/// LE target: pc + 4 minus the loop-end offset.
pub fn targetLoopBack(pc: u32, j: u32, i: u32) u32 {
    return pc +% 4 -% loopOffset(j, i);
}

/// WLSTP target: pc + 4 plus the loop-end offset; the size field is unused.
pub fn targetLoopForwardTail(pc: u32, size: u32, n: u32, j: u32, i: u32) u32 {
    _ = .{ size, n };
    return pc +% 4 +% loopOffset(j, i);
}
