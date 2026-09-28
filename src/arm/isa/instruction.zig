//! Instruction-level types shared by the Arm semantic handlers and the step loop: the
//! class a row belongs to, the cycle cost of a class, the outcome an executed row
//! reports, the failures a host access can raise, and the word count a multiple transfer
//! moves.

/// Kind of instruction a row is, used to price it and count its words.
pub const Class = enum(u4) { data_processing, load, store, load_multiple, store_multiple, push, pop, pop_pc, branch, branch_link, system, sleep, special_register, barrier, divide };

/// A measured divider's cycles: zero divisor, zero dividend, narrower dividend, else base plus one
/// per `bits` bits; SDIV adds `signed`.
pub const Divide = struct { zero_divisor: u4, zero_dividend: u4, narrower: u4, base: u4, bits: u4, signed: u4 };

/// UDIV and SDIV cycles under a core's divider, signed operands taken by magnitude.
pub fn divideCycles(dividend: u32, divisor: u32, signed: bool, divide: Divide) u8 {
    const a = if (signed) @abs(@as(i32, @bitCast(dividend))) else dividend;
    const b = if (signed) @abs(@as(i32, @bitCast(divisor))) else divisor;
    const extra: u8 = if (signed) divide.signed else 0;
    if (b == 0) return extra + divide.zero_divisor;
    if (a == 0) return extra + divide.zero_dividend;
    const n = @as(i8, @clz(b)) - @as(i8, @clz(a)) + 1;
    if (n <= 0) return extra + divide.narrower;
    return extra + divide.base + (@as(u8, @intCast(n)) + divide.bits - 1) / divide.bits;
}

/// Cycle price of a class: base cycles, the extra when taken, and what each register of its list
/// adds.
pub const Cost = packed struct(u24) { cycles: u8, taken: u8, per_register: u8 };

/// Number of instruction classes, the length of a cost table.
pub const costs_len = @typeInfo(Class).@"enum".fields.len;

/// What an executed row reports: retired, branched, or how it stopped.
pub const Outcome = enum(u8) {
    next,
    branched,
    breakpoint,
    data_fault,
    unaligned,
    violation,
    secure,
    divide_by_zero,
    no_coprocessor,
    authentication_failure,
    undefined,
    unimplemented,
    supervisor_call,
    exception_return,
    function_return,

    /// Outcome for a refused access, carrying the host's reason, B3.5.3 and E2.1.137.
    pub fn faulted(err: Failure) Outcome {
        return switch (err) {
            error.DataFault => .data_fault,
            error.Unaligned => .unaligned,
            error.Violation => .violation,
            error.Secure => .secure,
        };
    }
};

/// Reasons a host refuses an access.
pub const Failure = error{ DataFault, Unaligned, Violation, Secure };

/// Number of single-precision registers, bounding a floating-point block transfer.
pub const registers: u8 = 32;

/// Words a load or store multiple, push or pop moves; zero for other classes.
pub fn words(class: Class, code: u32) u8 {
    const first = @intFromEnum(Class.load_multiple);
    if (@intFromEnum(class) -% first > @intFromEnum(Class.pop_pc) - first) return 0;
    const wide = code >> 16 != 0;
    return switch (class) {
        .load_multiple, .store_multiple => if (!wide) @popCount(code & 0xff) else if (code >> 25 == 0b1110110) @min(@as(u8, @truncate(code & 0xff)), registers) else if (code & 1 << 22 != 0) 2 else @popCount(code & 0xffff),
        .push => if (wide) @popCount(code & 0xffff) else @popCount(code & 0x1ff),
        .pop => if (wide) @popCount(code & 0xffff) else @popCount(code & 0xff),
        .pop_pc => if (wide) @popCount(code & 0xffff) else @as(u8, @popCount(code & 0xff)) + 1,
        else => 0,
    };
}
