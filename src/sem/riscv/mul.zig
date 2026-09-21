//! RV32M handlers: the four multiplies, which differ only in how they read the operands for the
//! upper half of the 64-bit product, section 12.1, and the four divides, where a divisor of zero
//! and the one signed overflow trap nothing and answer what table 11 gives, section 12.2. Bound by
//! `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;

fn high(product: u64) u32 {
    return @truncate(product >> 32);
}

/// MUL (RV32M): the lower word of the product, the same whether signed or unsigned, section 12.1.
pub fn mul(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    root.write(s, d, s.x[n] *% s.x[m]);
    return .next;
}

/// MULH (RV32M): the upper word of the signed-by-signed product, section 12.1.
pub fn mulh(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a: i64 = @as(i32, @bitCast(s.x[n]));
    const b: i64 = @as(i32, @bitCast(s.x[m]));
    root.write(s, d, high(@bitCast(a * b)));
    return .next;
}

/// MULHSU (RV32M): the upper word of rs1 signed times rs2 unsigned, section 12.1.
pub fn mulhsu(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a: i64 = @as(i32, @bitCast(s.x[n]));
    const b: i64 = s.x[m];
    root.write(s, d, high(@bitCast(a * b)));
    return .next;
}

/// MULHU (RV32M): the upper word of the unsigned-by-unsigned product, section 12.1.
pub fn mulhu(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a: u64 = s.x[n];
    const b: u64 = s.x[m];
    root.write(s, d, high(a * b));
    return .next;
}

const most_negative: i32 = -0x8000_0000;

/// DIV (RV32M): signed quotient; divide by zero gives all ones and the overflow case the dividend,
/// table 11.
pub fn div(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a: i32 = @bitCast(s.x[n]);
    const b: i32 = @bitCast(s.x[m]);
    const quotient: i32 = if (b == 0) -1 else if (a == most_negative and b == -1) a else @divTrunc(a, b);
    root.write(s, d, @bitCast(quotient));
    return .next;
}

/// DIVU (RV32M): unsigned quotient; divide by zero gives all ones, table 11.
pub fn divu(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const b = s.x[m];
    root.write(s, d, if (b == 0) 0xffff_ffff else s.x[n] / b);
    return .next;
}

/// REM (RV32M): signed remainder; divide by zero gives the dividend and the overflow case zero,
/// table 11.
pub fn rem(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a: i32 = @bitCast(s.x[n]);
    const b: i32 = @bitCast(s.x[m]);
    const remainder: i32 = if (b == 0) a else if (a == most_negative and b == -1) 0 else @rem(a, b);
    root.write(s, d, @bitCast(remainder));
    return .next;
}

/// REMU (RV32M): unsigned remainder; divide by zero gives the dividend, table 11.
pub fn remu(s: *State, host: anytype, m: u32, n: u32, d: u32) Outcome {
    _ = host;
    const a = s.x[n];
    const b = s.x[m];
    root.write(s, d, if (b == 0) a else a % b);
    return .next;
}
