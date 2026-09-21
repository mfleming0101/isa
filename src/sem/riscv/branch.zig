//! RV32I and RV32C control-flow handlers: the six conditional branches, JAL, JALR, and the
//! compressed C.J, C.JAL, C.BEQZ, C.BNEZ, C.JR and C.JALR, with the target functions that assemble
//! each scattered offset. Every offset is even and counted from the instruction itself; a register
//! target has its lowest bit cleared. A link is written after the target is read. The target
//! functions are also what the disassembler prints. Bound by `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;

const ra = 1;

/// The six branch conditions, section 2.5.2.
pub const Condition = enum { eq, ne, lt, ge, ltu, geu };

/// The RV32I conditional branches, BEQ through BGEU: jump by the B-type offset when the pair
/// agrees.
pub fn Branch(comptime cond: Condition) type {
    return struct {
        /// Compares rs1 with rs2 and takes the branch where the condition holds.
        pub fn call(s: *State, host: anytype, a: u32, j: u32, m: u32, n: u32, k: u32, b: u32) Outcome {
            _ = host;
            const x = s.x[n];
            const y = s.x[m];
            const taken = switch (cond) {
                .eq => x == y,
                .ne => x != y,
                .lt => @as(i32, @bitCast(x)) < @as(i32, @bitCast(y)),
                .ge => @as(i32, @bitCast(x)) >= @as(i32, @bitCast(y)),
                .ltu => x < y,
                .geu => x >= y,
            };
            if (!taken) return .next;
            s.pc = targetB(s.pc, a, j, m, n, k, b);
            return .branched;
        }
    };
}

/// B-type target, section 2.3: pc plus the even offset assembled from four scattered pieces.
pub fn targetB(pc: u32, a: u32, j: u32, m: u32, n: u32, k: u32, b: u32) u32 {
    _ = m;
    _ = n;
    return pc +% root.sext(13, a << 12 | b << 11 | j << 5 | k << 1);
}

/// JAL (RV32I): jumps by the J-type offset and links the instruction after it in rd.
pub fn jal(s: *State, host: anytype, a: u32, j: u32, b: u32, k: u32, d: u32) Outcome {
    _ = host;
    const link = s.pc +% 4;
    s.pc = targetJ(s.pc, a, j, b, k, d);
    root.write(s, d, link);
    return .branched;
}

/// J-type target: pc plus the even, sign-extended 21-bit offset.
pub fn targetJ(pc: u32, a: u32, j: u32, b: u32, k: u32, d: u32) u32 {
    _ = d;
    return pc +% root.sext(21, a << 20 | k << 12 | b << 11 | j << 1);
}

/// JALR (RV32I): jumps to rs1 plus offset with bit zero cleared, section 2.5.1, linking pc+4.
pub fn jalr(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
    _ = host;
    const link = s.pc +% 4;
    s.pc = (s.x[n] +% root.sext(12, i)) & ~@as(u32, 1);
    root.write(s, d, link);
    return .branched;
}

/// C.BEQZ and C.BNEZ (RV32C): branch on rs1′ against zero, section 27.4.
pub fn Compare(comptime on_zero: bool) type {
    return struct {
        /// Takes the branch where rs1′ is zero or non-zero as selected.
        pub fn call(s: *State, host: anytype, a: u32, b: u32, n: u32, c: u32, e: u32, f: u32) Outcome {
            _ = host;
            if ((s.x[root.primed(n)] == 0) != on_zero) return .next;
            s.pc = targetCB(s.pc, a, b, n, c, e, f);
            return .branched;
        }
    };
}

/// CB target: pc plus the even, sign-extended 9-bit offset.
pub fn targetCB(pc: u32, a: u32, b: u32, n: u32, c: u32, e: u32, f: u32) u32 {
    _ = n;
    return pc +% root.sext(9, a << 8 | c << 6 | f << 5 | b << 3 | e << 1);
}

/// C.J and C.JAL (RV32C): jump by the CJ offset; C.JAL links the parcel two bytes on, section 27.4.
pub fn Jump(comptime links: bool) type {
    return struct {
        /// Jumps to the CJ target, linking pc+2 into ra where the row links.
        pub fn call(s: *State, host: anytype, a: u32, b: u32, c: u32, e: u32, f: u32, g: u32, h: u32, i: u32) Outcome {
            _ = host;
            const link = s.pc +% 2;
            s.pc = targetCJ(s.pc, a, b, c, e, f, g, h, i);
            if (links) s.x[ra] = link;
            return .branched;
        }
    };
}

/// CJ target: pc plus the even, sign-extended 12-bit offset.
pub fn targetCJ(pc: u32, a: u32, b: u32, c: u32, e: u32, f: u32, g: u32, h: u32, i: u32) u32 {
    return pc +% root.sext(12, a << 11 | e << 10 | c << 8 | g << 7 | f << 6 | i << 5 | b << 4 | h << 1);
}

/// C.JR (RV32C): jumps to rs1 with bit zero cleared, section 27.4.
pub fn jr(s: *State, host: anytype, n: u32) Outcome {
    _ = host;
    s.pc = s.x[n] & ~@as(u32, 1);
    return .branched;
}

/// C.JALR (RV32C): jumps to rs1 with bit zero cleared and links pc+2 into ra, section 27.4.
pub fn jalrC(s: *State, host: anytype, n: u32) Outcome {
    _ = host;
    const link = s.pc +% 2;
    s.pc = s.x[n] & ~@as(u32, 1);
    s.x[ra] = link;
    return .branched;
}
