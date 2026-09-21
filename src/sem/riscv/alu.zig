//! RV32I integer arithmetic and logic handlers, and the RV32C rows that expand to them. The ten
//! base operations of section 2.4 are computed once so the compressed rows of section 27.5 share
//! the arithmetic of their expansions. The `Reg`, `Imm`, `Shamt`, `CShift` and `CReg` builders make
//! one handler per operation; the rest are single rows. Bound by `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;

/// The ten base operations, section 2.4, shared with the compressed rows of section 27.5.
pub const Operation = enum { add, sub, sll, slt, sltu, xor, srl, sra, @"or", @"and" };

/// Applies a base operation to two words; shifts take their amount from the low five bits.
pub fn compute(comptime kind: Operation, a: u32, b: u32) u32 {
    const amount: u5 = @truncate(b);
    return switch (kind) {
        .add => a +% b,
        .sub => a -% b,
        .sll => a << amount,
        .slt => @intFromBool(@as(i32, @bitCast(a)) < @as(i32, @bitCast(b))),
        .sltu => @intFromBool(a < b),
        .xor => a ^ b,
        .srl => a >> amount,
        .sra => @bitCast(@as(i32, @bitCast(a)) >> amount),
        .@"or" => a | b,
        .@"and" => a & b,
    };
}

/// The RV32I register-register rows, ADD through AND: rd = rs1 op rs2.
pub fn Reg(comptime kind: Operation) type {
    return struct {
        /// Writes rs1 op rs2 to rd.
        pub fn call(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
            _ = host;
            root.write(s, d, compute(kind, s.x[n], s.x[m]));
            return .next;
        }
    };
}

/// The RV32I immediate rows, ADDI through ANDI: rd = rs1 op sign-extended immediate.
pub fn Imm(comptime kind: Operation) type {
    return struct {
        /// Writes rs1 op the sign-extended twelve-bit immediate to rd.
        pub fn call(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
            _ = host;
            root.write(s, d, compute(kind, s.x[n], root.sext(12, i)));
            return .next;
        }
    };
}

/// SLLI, SRLI and SRAI (RV32I): rd = rs1 shifted by the five-bit shamt.
pub fn Shamt(comptime kind: Operation) type {
    return struct {
        /// Writes rs1 shifted by shamt to rd.
        pub fn call(s: *State, host: anytype, h: u32, n: u32, d: u32) Outcome {
            _ = host;
            root.write(s, d, compute(kind, s.x[n], h));
            return .next;
        }
    };
}

/// LUI (RV32I): writes the immediate to the high twenty bits of rd.
pub fn lui(s: *State, host: anytype, u: u32, d: u32) Outcome {
    _ = host;
    root.write(s, d, u << 12);
    return .next;
}

/// AUIPC (RV32I): writes pc plus the immediate shifted by twelve to rd.
pub fn auipc(s: *State, host: anytype, u: u32, d: u32) Outcome {
    _ = host;
    root.write(s, d, s.pc +% (u << 12));
    return .next;
}

fn imm6(i: u32, j: u32) u32 {
    return root.sext(6, i << 5 | j);
}

/// C.ADDI4SPN (RV32C): rd′ = sp plus the zero-extended immediate scaled by four.
pub fn addi4spn(s: *State, host: anytype, a: u32, b: u32, i: u32, j: u32, d: u32) Outcome {
    _ = host;
    root.write(s, root.primed(d), s.x[2] +% (b << 6 | a << 4 | j << 3 | i << 2));
    return .next;
}

/// C.ADDI (RV32C): adds the sign-extended six-bit immediate to rd in place.
pub fn addi(s: *State, host: anytype, i: u32, d: u32, j: u32) Outcome {
    _ = host;
    root.write(s, d, s.x[d] +% imm6(i, j));
    return .next;
}

/// C.NOP (RV32C): C.ADDI with rd=x0, section 27.5.5, so it changes nothing.
pub fn nop(s: *State, host: anytype, i: u32, j: u32) Outcome {
    _ = .{ s, host, i, j };
    return .next;
}

/// C.LI (RV32C): writes the sign-extended six-bit immediate to rd.
pub fn li(s: *State, host: anytype, i: u32, d: u32, j: u32) Outcome {
    _ = host;
    root.write(s, d, imm6(i, j));
    return .next;
}

/// C.LUI (RV32C): puts the six-bit immediate at bits 17 to 12, sign-extending bit 17 upwards,
/// section 27.5.1.
pub fn clui(s: *State, host: anytype, i: u32, d: u32) Outcome {
    _ = host;
    root.write(s, d, root.sext(6, i) << 12);
    return .next;
}

/// C.ADDI16SP (RV32C): adds the non-zero sign-extended immediate scaled by sixteen to sp, section
/// 27.5.2.
pub fn addi16sp(s: *State, host: anytype, i: u32, a: u32, b: u32, c: u32, e: u32) Outcome {
    _ = host;
    s.x[2] = s.x[2] +% (root.sext(6, i << 5 | c << 3 | b << 2 | e << 1 | a) << 4);
    return .next;
}

/// C.SRLI and C.SRAI (RV32C): CB-format shifts of rd′ in place, section 27.5.2.
pub fn CShift(comptime kind: Operation) type {
    return struct {
        /// Shifts rd′ by the amount in place.
        pub fn call(s: *State, host: anytype, d: u32, j: u32) Outcome {
            _ = host;
            const at = root.primed(d);
            root.write(s, at, compute(kind, s.x[at], j));
            return .next;
        }
    };
}

/// C.ANDI (RV32C): ands rd′ with the sign-extended six-bit immediate in place.
pub fn andi(s: *State, host: anytype, i: u32, d: u32, j: u32) Outcome {
    _ = host;
    const at = root.primed(d);
    root.write(s, at, compute(.@"and", s.x[at], imm6(i, j)));
    return .next;
}

/// C.SUB, C.XOR, C.OR and C.AND (RV32C): CA-format rows with rd′ as destination and first source,
/// section 27.5.3.
pub fn CReg(comptime kind: Operation) type {
    return struct {
        /// Writes rd′ op rs2′ to rd′.
        pub fn call(s: *State, host: anytype, d: u32, m: u32) Outcome {
            _ = host;
            const at = root.primed(d);
            root.write(s, at, compute(kind, s.x[at], s.x[root.primed(m)]));
            return .next;
        }
    };
}

/// C.SLLI (RV32C): shifts rd left by the shamt in place.
pub fn slli(s: *State, host: anytype, d: u32, j: u32) Outcome {
    _ = host;
    root.write(s, d, compute(.sll, s.x[d], j));
    return .next;
}

/// C.MV (RV32C): copies rs2 into rd.
pub fn mv(s: *State, host: anytype, d: u32, m: u32) Outcome {
    _ = host;
    root.write(s, d, s.x[m]);
    return .next;
}

/// C.ADD (RV32C): adds rs2 into rd.
pub fn addTo(s: *State, host: anytype, d: u32, m: u32) Outcome {
    _ = host;
    root.write(s, d, s.x[d] +% s.x[m]);
    return .next;
}
