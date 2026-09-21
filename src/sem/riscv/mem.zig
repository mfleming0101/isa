//! RV32I load and store handlers and the RV32C word transfers C.LW, C.SW, C.LWSP and C.SWSP. An
//! access whose address is not a multiple of its size is answered or refused as the hart's model
//! says, Privileged 3.6, which the access helpers apply. The compressed offsets are scattered over
//! the parcel and scaled by four, section 27.3.2. Bound by `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const access = root.access;

const sp = 2;

fn load(s: *State, host: anytype, d: u32, at: u32, comptime width: u8, comptime signed: bool) Outcome {
    const value = access.read(@TypeOf(host.*), host, s.csr.implementation.misaligned, at, width, signed) catch |err| return Outcome.faulted(err);
    root.write(s, d, value);
    return .next;
}

fn store(s: *State, host: anytype, at: u32, value: u32, comptime width: u8) Outcome {
    access.write(@TypeOf(host.*), host, s.csr.implementation.misaligned, at, width, value) catch |err| return Outcome.faulted(err);
    return .next;
}

/// LB, LH, LW, LBU and LHU (RV32I): load at rs1 plus offset, sign- or zero-extended, into rd.
pub fn Load(comptime width: u8, comptime signed: bool) type {
    return struct {
        /// Loads at rs1 plus the sign-extended twelve-bit offset into rd.
        pub fn call(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
            return load(s, host, d, s.x[n] +% root.sext(12, i), width, signed);
        }
    };
}

/// SB, SH and SW (RV32I): store the low bits of rs2 at rs1 plus offset.
pub fn Store(comptime width: u8) type {
    return struct {
        /// Stores rs2 at rs1 plus the sign-extended twelve-bit offset.
        pub fn call(s: *State, host: anytype, i: u32, m: u32, n: u32, j: u32) Outcome {
            return store(s, host, s.x[n] +% root.sext(12, i << 5 | j), s.x[m], width);
        }
    };
}

fn wordOffset(a: u32, i: u32, j: u32) u32 {
    return j << 6 | a << 3 | i << 2;
}

/// C.LW (RV32C): loads a word at rs1′ plus the offset scaled by four into rd′.
pub fn clw(s: *State, host: anytype, a: u32, n: u32, i: u32, j: u32, d: u32) Outcome {
    return load(s, host, root.primed(d), s.x[root.primed(n)] +% wordOffset(a, i, j), 32, false);
}

/// C.SW (RV32C): stores rs2′ at rs1′ plus the offset scaled by four.
pub fn csw(s: *State, host: anytype, a: u32, n: u32, i: u32, j: u32, m: u32) Outcome {
    return store(s, host, s.x[root.primed(n)] +% wordOffset(a, i, j), s.x[root.primed(m)], 32);
}

/// C.LWSP (RV32C): loads a word at sp plus the offset scaled by four into rd.
pub fn lwsp(s: *State, host: anytype, i: u32, d: u32, a: u32, b: u32) Outcome {
    return load(s, host, d, s.x[sp] +% (b << 6 | i << 5 | a << 2), 32, false);
}

/// C.SWSP (RV32C): stores rs2 at sp plus the offset scaled by four.
pub fn swsp(s: *State, host: anytype, a: u32, b: u32, m: u32) Outcome {
    return store(s, host, s.x[sp] +% (b << 6 | a << 2), s.x[m], 32);
}
