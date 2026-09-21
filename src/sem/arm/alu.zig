//! Integer data-processing semantics for the T32 rows: adds, shifts, logic, moves, multiplies, bit
//! fields, saturation and division. Each `pub fn`, or the `call` of each `pub fn ... type`
//! generator, takes the machine state, the host and the decoded operand fields, returns an
//! `Outcome`, and is bound to a row name in root.zig for the generated decoder to invoke. The
//! adder, shifter and immediate expander are shared with dsp.zig and the disassembler.
const std = @import("std");
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;

/// Result of `add`: the value plus the carry and overflow it produced.
pub const Sum = struct { value: u32, carry: bool, overflow: bool };

/// AddWithCarry, A2.2.1: one adder for add and subtract, so the carry and overflow rules agree.
pub fn add(a: u32, b: u32, carry_in: bool) Sum {
    const wide = @as(u64, a) + @as(u64, b) + @intFromBool(carry_in);
    const value: u32 = @truncate(wide);
    return .{
        .value = value,
        .carry = wide >> 32 != 0,
        .overflow = ((a ^ value) & (b ^ value)) >> 31 == 1,
    };
}

/// The four shift operations a shifter operand can name.
pub const ShiftKind = enum { lsl, lsr, asr, ror };

/// Result of `shift`: the value and the carry out.
pub const Shifted = struct { value: u32, carry: bool };

/// Shift_C, A2.2.1; an amount of zero passes the carry through unchanged.
pub fn shift(comptime kind: ShiftKind, value: u32, amount: u32, carry_in: bool) Shifted {
    if (amount == 0) return .{ .value = value, .carry = carry_in };
    const n: u5 = @intCast(@min(amount, 31));
    return switch (kind) {
        .lsl => if (amount > 32) .{ .value = 0, .carry = false } else if (amount == 32) .{ .value = 0, .carry = value & 1 != 0 } else .{ .value = value << n, .carry = (value >> @intCast(32 - amount)) & 1 != 0 },
        .lsr => if (amount > 32) .{ .value = 0, .carry = false } else if (amount == 32) .{ .value = 0, .carry = value >> 31 != 0 } else .{ .value = value >> n, .carry = (value >> (n - 1)) & 1 != 0 },
        .asr => if (amount >= 32) .{ .value = if (value >> 31 != 0) 0xffff_ffff else 0, .carry = value >> 31 != 0 } else .{ .value = @bitCast(@as(i32, @bitCast(value)) >> n), .carry = (value >> (n - 1)) & 1 != 0 },
        .ror => blk: {
            const rotated = std.math.rotr(u32, value, amount);
            break :blk .{ .value = rotated, .carry = rotated >> 31 != 0 };
        },
    };
}

/// Shifted second operand of a wide register form, A6.3.11: imm5 zero is 32 for LSR/ASR, RRX for ROR.
pub fn shiftedBy(s: *const State, m: u32, kind: u32, imm5: u32) Shifted {
    const value = root.get(s, m);
    const carry = s.xpsr & root.flag_c != 0;
    const amount: u32 = if (imm5 == 0 and kind != 0) 32 else imm5;
    return switch (kind) {
        0 => shift(.lsl, value, amount, carry),
        1 => shift(.lsr, value, amount, carry),
        2 => shift(.asr, value, amount, carry),
        else => if (imm5 == 0)
            .{ .value = (value >> 1) | (@as(u32, @intFromBool(carry)) << 31), .carry = value & 1 != 0 }
        else
            shift(.ror, value, amount, carry),
    };
}

/// MOVS (immediate), narrow: writes Rd and sets N and Z outside an IT block.
pub fn movs(s: *State, host: anytype, d: u32, i: u32) Outcome {
    _ = host;
    s.r[d] = i;
    if (!root.inIt(s)) root.setNZ(s, i);
    return .next;
}

/// ADDS (immediate) three-register narrow form: Rd = Rn + imm3, flags outside IT.
pub fn adds(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
    _ = host;
    return flagged(s, d, add(s.r[n], i, false));
}

/// SUBS (immediate) three-register narrow form: Rd = Rn - imm3, flags outside IT.
pub fn subs(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
    _ = host;
    return flagged(s, d, add(s.r[n], ~i, true));
}

/// ADDS and SUBS with an eight-bit immediate, reading and writing one register.
pub fn Arith8(comptime subtract: bool) type {
    return struct {
        /// Adds or subtracts the immediate into Rd, setting flags outside IT.
        pub fn call(s: *State, host: anytype, d: u32, i: u32) Outcome {
            _ = host;
            return flagged(s, d, if (subtract) add(s.r[d], ~i, true) else add(s.r[d], i, false));
        }
    };
}

/// CMP (immediate), narrow: sets the four flags from Rn minus imm8.
pub fn cmp(s: *State, host: anytype, n: u32, i: u32) Outcome {
    _ = host;
    const result = add(s.r[n], ~i, true);
    root.setNZCV(s, result.value, result.carry, result.overflow);
    return .next;
}

/// CMP (register), narrow: sets the four flags from Rn minus Rm.
pub fn cmpReg(s: *State, host: anytype, m: u32, n: u32) Outcome {
    _ = host;
    const result = add(s.r[n], ~s.r[m], true);
    root.setNZCV(s, result.value, result.carry, result.overflow);
    return .next;
}

/// CMN (register), A7.7.26: the add whose result is only the four flags.
pub fn cmnReg(s: *State, host: anytype, m: u32, n: u32) Outcome {
    _ = host;
    const result = add(s.r[n], s.r[m], false);
    root.setNZCV(s, result.value, result.carry, result.overflow);
    return .next;
}

/// LSLS (immediate), narrow: shifts Rm left into Rd, setting N, Z and C outside IT.
pub fn lsls(s: *State, host: anytype, i: u32, m: u32, d: u32) Outcome {
    _ = host;
    const shifted = shift(.lsl, s.r[m], i, s.xpsr & root.flag_c != 0);
    s.r[d] = shifted.value;
    if (!root.inIt(s)) root.setNZC(s, shifted.value, shifted.carry);
    return .next;
}

/// ADD high-register form: reaches every register; writing r15 is a branch.
pub fn addHigh(s: *State, host: anytype, d: u32, m: u32) Outcome {
    _ = host;
    return writeOrBranch(s, d, root.get(s, d) +% root.get(s, m));
}

/// MOV high-register form: reaches every register; writing r15 is a branch.
pub fn movHigh(s: *State, host: anytype, d: u32, m: u32) Outcome {
    _ = host;
    return writeOrBranch(s, d, root.get(s, m));
}

fn writeOrBranch(s: *State, d: u32, value: u32) Outcome {
    if (d != 15) {
        root.set(s, d, value);
        return .next;
    }
    s.pc = value & ~@as(u32, 1);
    return .branched;
}

fn flagged(s: *State, d: u32, sum: Sum) Outcome {
    s.r[d] = sum.value;
    if (!root.inIt(s)) root.setNZCV(s, sum.value, sum.carry, sum.overflow);
    return .next;
}

fn imm16(i: u32, h: u32, k: u32, l: u32) u32 {
    return h << 12 | i << 11 | k << 8 | l;
}

/// MOVW: writes a sixteen-bit immediate assembled from four fields, zero-extended.
pub fn movw(s: *State, host: anytype, i: u32, h: u32, k: u32, d: u32, l: u32) Outcome {
    _ = host;
    root.set(s, d, imm16(i, h, k, l));
    return .next;
}

/// MOVT: replaces the top halfword of Rd with a sixteen-bit immediate.
pub fn movt(s: *State, host: anytype, i: u32, h: u32, k: u32, d: u32, l: u32) Outcome {
    _ = host;
    root.set(s, d, (root.get(s, d) & 0xffff) | (imm16(i, h, k, l) << 16));
    return .next;
}

/// Result of `expand`: the constant and the carry out.
pub const Expanded = struct { value: u32, carry: bool };

/// ThumbExpandImm_C, A6.3.2: a repeat pattern keeping the carry, or a rotated eight-bit value whose
/// carry is its top bit.
pub fn expand(imm12: u32, carry_in: bool) Expanded {
    const imm8 = imm12 & 0xff;
    if (imm12 >> 10 == 0) {
        return .{ .value = switch (imm12 >> 8 & 3) {
            0 => imm8,
            1 => imm8 << 16 | imm8,
            2 => imm8 << 24 | imm8 << 8,
            else => imm8 *% 0x0101_0101,
        }, .carry = carry_in };
    }
    const value = std.math.rotr(u32, 0x80 | (imm12 & 0x7f), imm12 >> 7);
    return .{ .value = value, .carry = value >> 31 != 0 };
}

/// The expanded constant alone, for disassembly, where no carry is read or rendered.
pub fn expandImm(imm12: u32) u32 {
    return expand(imm12, false).value;
}

/// The wide data-processing operations, logical and arithmetic.
pub const Op = enum { orr, orn, @"and", eor, bic, add, sub, rsb, adc, sbc };

fn operandN(s: *const State, comptime kind: Op, n: u32) u32 {
    return if (n == 15 and (kind == .orr or kind == .orn)) 0 else root.get(s, n);
}

fn compute(s: *State, comptime kind: Op, d: u32, x: u32, y: u32, carry: bool, flags: bool) Outcome {
    switch (kind) {
        .orr, .orn, .@"and", .eor, .bic => {
            const result = switch (kind) {
                .orr => x | y,
                .orn => x | ~y,
                .@"and" => x & y,
                .eor => x ^ y,
                else => x & ~y,
            };
            if (d != 15) root.set(s, d, result);
            if (flags) root.setNZC(s, result, carry);
            return .next;
        },
        else => {},
    }
    const carry_in = s.xpsr & root.flag_c != 0;
    const sum = switch (kind) {
        .sub => add(x, ~y, true),
        .rsb => add(~x, y, true),
        .adc => add(x, y, carry_in),
        .sbc => add(x, ~y, carry_in),
        else => add(x, y, false),
    };
    if (d != 15) root.set(s, d, sum.value);
    if (flags) root.setNZCV(s, sum.value, sum.carry, sum.overflow);
    return .next;
}

/// Wide data-processing with a modified immediate, A6.3.11; n=15 on ORR and ORN reads zero.
pub fn Imm(comptime kind: Op) type {
    return struct {
        /// Applies the operation to Rn and the expanded immediate, setting flags when S is set.
        pub fn call(s: *State, host: anytype, i: u32, sets: u32, n: u32, d: u32) Outcome {
            _ = host;
            const imm = expand(i, s.xpsr & root.flag_c != 0);
            return compute(s, kind, d, operandN(s, kind, n), imm.value, imm.carry, sets == 1);
        }
    };
}

/// Wide data-processing with a shifted register, A6.3.11; n=15 on ORR and ORN reads zero.
pub fn Reg(comptime kind: Op) type {
    return struct {
        /// Applies the operation to Rn and shifted Rm, setting flags when S is set.
        pub fn call(s: *State, host: anytype, sets: u32, n: u32, i: u32, d: u32, y: u32, m: u32) Outcome {
            _ = host;
            const second = shiftedBy(s, m, y, i);
            return compute(s, kind, d, operandN(s, kind, n), second.value, second.carry, sets == 1);
        }
    };
}

/// The narrow arithmetic operations that share one adder.
pub const ArithKind = enum { add, sub, adc, sbc, rsb };

fn narrowSum(s: *const State, comptime kind: ArithKind, x: u32, y: u32) Sum {
    const carry_in = s.xpsr & root.flag_c != 0;
    return switch (kind) {
        .add => add(x, y, false),
        .sub => add(x, ~y, true),
        .adc => add(x, y, carry_in),
        .sbc => add(x, ~y, carry_in),
        .rsb => add(~x, 0, true),
    };
}

/// Narrow `adcs r{d}, r{m}` and siblings: the destination is also the first operand.
pub fn Accum(comptime kind: ArithKind) type {
    return struct {
        /// Combines Rd and Rm through the adder, setting flags outside IT.
        pub fn call(s: *State, host: anytype, m: u32, d: u32) Outcome {
            _ = host;
            return flagged(s, d, narrowSum(s, kind, s.r[d], s.r[m]));
        }
    };
}

/// Narrow `adds r{d}, r{n}, r{m}` and siblings.
pub fn Three(comptime kind: ArithKind) type {
    return struct {
        /// Combines Rn and Rm through the adder into Rd, setting flags outside IT.
        pub fn call(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
            _ = host;
            return flagged(s, d, narrowSum(s, kind, s.r[n], s.r[m]));
        }
    };
}

/// RSBS, A7.7.119: negation spelled as a reverse subtract from zero.
pub fn rsbs(s: *State, host: anytype, n: u32, d: u32) Outcome {
    _ = host;
    return flagged(s, d, narrowSum(s, .rsb, s.r[n], 0));
}

/// CMP high-register form, A7.7.28: four-bit fields, so either operand may be the program counter.
pub fn cmpHigh(s: *State, host: anytype, n: u32, m: u32) Outcome {
    _ = host;
    const sum = narrowSum(s, .sub, root.get(s, n), root.get(s, m));
    root.setNZCV(s, sum.value, sum.carry, sum.overflow);
    return .next;
}

/// The narrow logical operations.
pub const LogicKind = enum { @"and", eor, orr, bic, mvn };

fn logic(comptime kind: LogicKind, x: u32, y: u32) u32 {
    return switch (kind) {
        .@"and" => x & y,
        .eor => x ^ y,
        .orr => x | y,
        .bic => x & ~y,
        .mvn => ~y,
    };
}

/// Narrow logical forms, A7.7.9 onward: no shifter runs, so the carry is left alone.
pub fn Logic(comptime kind: LogicKind) type {
    return struct {
        /// Combines Rd and Rm logically, setting N and Z outside IT.
        pub fn call(s: *State, host: anytype, m: u32, d: u32) Outcome {
            _ = host;
            const result = logic(kind, s.r[d], s.r[m]);
            s.r[d] = result;
            if (!root.inIt(s)) root.setNZ(s, result);
            return .next;
        }
    };
}

/// TST (register), A7.7.188: the AND whose result is only the flags.
pub fn tst(s: *State, host: anytype, m: u32, n: u32) Outcome {
    _ = host;
    root.setNZ(s, s.r[n] & s.r[m]);
    return .next;
}

/// Narrow shift by immediate; an encoded zero means 32 for LSR and ASR.
pub fn ShiftImm(comptime kind: ShiftKind) type {
    return struct {
        /// Shifts Rm into Rd, setting N, Z and C outside IT.
        pub fn call(s: *State, host: anytype, i: u32, m: u32, d: u32) Outcome {
            _ = host;
            const amount: u32 = if (kind != .lsl and i == 0) 32 else i;
            const shifted = shift(kind, s.r[m], amount, s.xpsr & root.flag_c != 0);
            s.r[d] = shifted.value;
            if (!root.inIt(s)) root.setNZC(s, shifted.value, shifted.carry);
            return .next;
        }
    };
}

/// Narrow shift by register, A7.7.68: only the low eight bits of Rm count.
pub fn ShiftReg(comptime kind: ShiftKind) type {
    return struct {
        /// Shifts Rd by Rm, setting N, Z and C outside IT.
        pub fn call(s: *State, host: anytype, m: u32, d: u32) Outcome {
            _ = host;
            const shifted = shift(kind, s.r[d], s.r[m] & 0xff, s.xpsr & root.flag_c != 0);
            s.r[d] = shifted.value;
            if (!root.inIt(s)) root.setNZC(s, shifted.value, shifted.carry);
            return .next;
        }
    };
}

/// Wide shift by register, A7.7.68: four-bit destination and optional flag update.
pub fn ShiftWide(comptime kind: ShiftKind) type {
    return struct {
        /// Shifts Rn by Rm into Rd, setting N, Z and C when S is set.
        pub fn call(s: *State, host: anytype, sets: u32, n: u32, d: u32, m: u32) Outcome {
            _ = host;
            const shifted = shift(kind, root.get(s, n), root.get(s, m) & 0xff, s.xpsr & root.flag_c != 0);
            root.set(s, d, shifted.value);
            if (sets == 1) root.setNZC(s, shifted.value, shifted.carry);
            return .next;
        }
    };
}

/// MULS, narrow: Rd = Rn * Rd, setting N and Z outside IT.
pub fn muls(s: *State, host: anytype, n: u32, d: u32) Outcome {
    _ = host;
    const result = s.r[n] *% s.r[d];
    s.r[d] = result;
    if (!root.inIt(s)) root.setNZ(s, result);
    return .next;
}

/// Narrow SXTB, SXTH, UXTB and UXTH.
pub fn Extend(comptime width: u5, comptime signed: bool) type {
    return struct {
        /// Cuts Rm to the width, sign- or zero-extended, into Rd.
        pub fn call(s: *State, host: anytype, m: u32, d: u32) Outcome {
            _ = host;
            s.r[d] = cut(width, signed, s.r[m]);
            return .next;
        }
    };
}

/// Wide extends, A7.7.171: rotate by a byte count, then cut.
pub fn ExtendWide(comptime width: u5, comptime signed: bool) type {
    return struct {
        /// Rotates Rm by r bytes, cuts to the width and writes Rd.
        pub fn call(s: *State, host: anytype, d: u32, r: u32, m: u32) Outcome {
            _ = host;
            root.set(s, d, cut(width, signed, std.math.rotr(u32, root.get(s, m), r * 8)));
            return .next;
        }
    };
}

/// Truncates to `width` bits and extends back to 32, signed or unsigned.
pub fn cut(comptime width: u5, comptime signed: bool, value: u32) u32 {
    const low: std.meta.Int(.unsigned, width) = @truncate(value);
    return if (signed) @bitCast(@as(i32, @as(std.meta.Int(.signed, width), @bitCast(low)))) else low;
}

/// The four byte and bit rearrangements of one word.
pub const ByteOp = enum { rev, rev16, rbit, revsh };

fn shuffled(comptime op: ByteOp, value: u32) u32 {
    return switch (op) {
        .rev => @byteSwap(value),
        .rev16 => (value & 0x00ff_00ff) << 8 | (value & 0xff00_ff00) >> 8,
        .rbit => @bitReverse(value),
        .revsh => @bitCast(@as(i32, @as(i16, @bitCast(@byteSwap(@as(u16, @truncate(value))))))),
    };
}

/// Narrow REV, REV16 and REVSH, A7.7.113 onward.
pub fn Shuffle(comptime op: ByteOp) type {
    return struct {
        /// Rearranges Rm into Rd.
        pub fn call(s: *State, host: anytype, m: u32, d: u32) Outcome {
            _ = host;
            s.r[d] = shuffled(op, s.r[m]);
            return .next;
        }
    };
}

/// Wide REV, REV16, RBIT and REVSH, A7.7.113 onward; the duplicated n field is ignored.
pub fn ShuffleWide(comptime op: ByteOp) type {
    return struct {
        /// Rearranges Rm into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            _ = .{ host, n };
            root.set(s, d, shuffled(op, root.get(s, m)));
            return .next;
        }
    };
}

/// CLZ: counts the leading zeros of Rm into Rd; the duplicated n field is ignored.
pub fn clz(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
    _ = .{ host, n };
    root.set(s, d, @clz(root.get(s, m)));
    return .next;
}

/// ADR, A7.7.7: the word-aligned program counter plus a scaled immediate.
pub fn adr(s: *State, host: anytype, d: u32, i: u32) Outcome {
    _ = host;
    s.r[d] = root.base(s, 15) +% (i << 2);
    return .next;
}

/// ADD (SP plus immediate), A7.7.5: Rd = SP + imm8 * 4.
pub fn addSpImm8(s: *State, host: anytype, d: u32, i: u32) Outcome {
    _ = host;
    s.r[d] = s.sp() +% (i << 2);
    return .next;
}

/// ADD and SUB (SP plus or minus immediate) writing the stack pointer back.
pub fn SpAdjust(comptime subtract: bool) type {
    return struct {
        /// Moves SP by imm7 * 4 in the fixed direction.
        pub fn call(s: *State, host: anytype, i: u32) Outcome {
            _ = host;
            const by = i << 2;
            s.setSp(if (subtract) s.sp() -% by else s.sp() +% by);
            return .next;
        }
    };
}

/// ADDW and SUBW, A7.7.3 and A7.7.174: a plain twelve-bit immediate, no shifter and no flags.
pub fn Wide12(comptime subtract: bool) type {
    return struct {
        /// Adds or subtracts imm12 from Rn into Rd, no flags.
        pub fn call(s: *State, host: anytype, i: u32, n: u32, d: u32) Outcome {
            _ = host;
            const from = root.base(s, n);
            root.set(s, d, if (subtract) from -% i else from +% i);
            return .next;
        }
    };
}

/// ORR (register) split by field spelling; the m field names `r{m*scale+offset}`.
pub fn OrrReg(comptime flags: bool, comptime scale: u32, comptime offset: u32) type {
    return struct {
        /// ORs Rn with shifted Rm into Rd.
        pub fn call(s: *State, host: anytype, n: u32, i: u32, d: u32, y: u32, m: u32) Outcome {
            _ = host;
            const second = shiftedBy(s, m * scale + offset, y, i);
            return compute(s, .orr, d, operandN(s, .orr, n), second.value, second.carry, flags);
        }
    };
}

/// MLA and MLS, A7.7.74 and A7.7.75: r15 as accumulator is MUL, reading the addend as zero.
pub fn Multiply(comptime subtract: bool) type {
    return struct {
        /// Adds or subtracts Rn * Rm to the accumulator into Rd.
        pub fn call(s: *State, host: anytype, n: u32, a: u32, d: u32, m: u32) Outcome {
            _ = host;
            const product = root.get(s, n) *% root.get(s, m);
            const held = if (a == 15) 0 else root.get(s, a);
            root.set(s, d, if (subtract) held -% product else held +% product);
            return .next;
        }
    };
}

/// Long multiplies, A7.7.149 onward: a sixty-four-bit product across a low and a high register.
pub fn Long(comptime signed: bool, comptime accumulate: bool) type {
    return struct {
        /// Multiplies Rn by Rm, optionally accumulating, into RdLo and RdHi.
        pub fn call(s: *State, host: anytype, n: u32, l: u32, h: u32, m: u32) Outcome {
            _ = host;
            const x = root.get(s, n);
            const y = root.get(s, m);
            const product: u64 = if (signed)
                @bitCast(@as(i64, @as(i32, @bitCast(x))) * @as(i64, @as(i32, @bitCast(y))))
            else
                @as(u64, x) * y;
            const sum = product +% (if (accumulate) @as(u64, root.get(s, h)) << 32 | root.get(s, l) else 0);
            root.set(s, l, @truncate(sum));
            root.set(s, h, @intCast(sum >> 32));
            return .next;
        }
    };
}

/// BFI, A7.7.14: inserts the low bits of Rn into the named lane; r15 as source is BFC.
pub fn bfi(s: *State, host: anytype, n: u32, i: u32, d: u32, b: u32) Outcome {
    _ = host;
    if (b < i) return .next;
    const lane = (@as(u32, 0xffff_ffff) >> @intCast(31 - b)) & (@as(u32, 0xffff_ffff) << @intCast(i));
    const source = if (n == 15) 0 else root.get(s, n) << @intCast(i);
    root.set(s, d, (root.get(s, d) & ~lane) | (source & lane));
    return .next;
}

/// UBFX and SBFX, A7.7.191 and A7.7.127: the field is raised to the top and shifted back down.
pub fn Bfx(comptime signed: bool) type {
    return struct {
        /// Extracts the bit field of Rn into Rd.
        pub fn call(s: *State, host: anytype, n: u32, i: u32, d: u32, b: u32) Outcome {
            _ = host;
            const msb = i + b;
            if (msb > 31) return .next;
            const left: u5 = @intCast(31 - msb);
            const right: u5 = @intCast(31 - msb + i);
            const raised = root.get(s, n) << left;
            root.set(s, d, if (signed) @bitCast(@as(i32, @bitCast(raised)) >> right) else raised >> right);
            return .next;
        }
    };
}

/// SSAT and USAT, A7.7.128 and A7.7.190; ASR with a zero shift is SSAT16 or USAT16, DSP only.
pub fn Sat(comptime signed: bool, comptime arithmetic: bool) type {
    return struct {
        /// Shifts Rn, clamps to the named width into Rd, setting Q when clamped.
        pub fn call(s: *State, host: anytype, n: u32, i: u32, d: u32, b: u32) Outcome {
            const to: u6 = if (signed) @as(u6, @intCast(b)) + 1 else @intCast(b);
            const max: i64 = (@as(i64, 1) << @intCast(if (signed) to - 1 else to)) - 1;
            const min: i64 = if (signed) -(@as(i64, 1) << @intCast(to - 1)) else 0;
            if (arithmetic and i == 0) {
                if (!host.architecture().dsp()) return .undefined;
                var q = false;
                var halves: u32 = 0;
                inline for (0..2) |k| {
                    const at: u5 = 16 * k;
                    const half: i64 = @as(i16, @bitCast(@as(u16, @truncate(root.get(s, n) >> at))));
                    const clamped_half = @min(@max(half, min), max);
                    if (clamped_half != half) q = true;
                    halves |= (@as(u32, @truncate(@as(u64, @bitCast(clamped_half)))) & 0xffff) << at;
                }
                root.set(s, d, halves);
                if (q) s.xpsr |= root.flag_q;
                return .next;
            }
            const value: i64 = @as(i32, @bitCast(shift(if (arithmetic) .asr else .lsl, root.get(s, n), i, false).value));
            const clamped = @min(@max(value, min), max);
            if (clamped != value) s.xpsr |= root.flag_q;
            root.set(s, d, @bitCast(@as(i32, @intCast(clamped))));
            return .next;
        }
    };
}

/// SDIV and UDIV, A7.7.126 and A7.7.195: division by zero answers zero unless CCR.DIV_0_TRP traps.
pub fn Div(comptime signed: bool) type {
    return struct {
        /// Divides Rn by Rm into Rd.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, m: u32) Outcome {
            const y = root.get(s, m);
            if (y == 0) {
                if (host.trapsDivideByZero()) return .divide_by_zero;
                root.set(s, d, 0);
                return .next;
            }
            const x = root.get(s, n);
            root.set(s, d, if (signed)
                @bitCast(@as(i32, @truncate(@divTrunc(@as(i64, @as(i32, @bitCast(x))), @as(i64, @as(i32, @bitCast(y)))))))
            else
                x / y);
            return .next;
        }
    };
}

/// UDF.W, A7.7.194: the permanently undefined instruction.
pub fn udf(s: *State, host: anytype, i: u32, j: u32) Outcome {
    _ = .{ s, host, i, j };
    return .undefined;
}

/// BKPT: reports a breakpoint to the host.
pub fn bkpt(s: *State, host: anytype, i: u32) Outcome {
    _ = .{ s, host, i };
    return .breakpoint;
}

fn zeroRegister(s: *const State, i: u32) u32 {
    return if (i == 15) 0 else root.get(s, i);
}

fn conditional(s: *State, other: u32, n: u32, k: u32, d: u32, c: u32) Outcome {
    root.set(s, d, if (s.condition(@intCast(c))) zeroRegister(s, n) else switch (k) {
        0 => other,
        1 => other +% 1,
        2 => ~other,
        else => ~other +% 1,
    });
    return .next;
}

/// CSEL family with a register second operand; `scale` and `first` map the m field; r15 reads zero.
pub fn Conditional(comptime scale: u32, comptime first: u32) type {
    return struct {
        /// Selects Rn or the transformed Rm by condition c into Rd.
        pub fn call(s: *State, host: anytype, n: u32, k: u32, d: u32, c: u32, m: u32) Outcome {
            _ = host;
            return conditional(s, zeroRegister(s, m * scale + first), n, k, d, c);
        }
    };
}

/// CSEL family with the second operand fixed at zero.
pub fn conditionalZero(s: *State, host: anytype, n: u32, k: u32, d: u32, c: u32) Outcome {
    _ = host;
    return conditional(s, 0, n, k, d, c);
}
