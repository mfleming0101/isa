//! The CSR file of an RV32 machine-and-user hart: the privilege modes, the CSR numbers the hart
//! answers to, the `Implementation` record of the choices the Privileged spec leaves open, the
//! mstatus layout of Privileged 3.1.6, and the storage with read, write, trap entry, interrupt
//! entry and MRET return. The PMP numbers are a separate list because those registers belong to
//! the protection unit and are reached through the host. `allowed` applies the access rules of
//! section 2.1. Used by the access helpers, the system handlers and the disassembler.
const std = @import("std");

/// The two privilege modes this file implements: user and machine, Privileged 1.2.
pub const Privilege = enum(u2) { user = 0, machine = 3 };

/// The CSR numbers the hart's own file answers to, Privileged 2.2.
pub const Number = enum(u12) {
    fflags = 0x001,
    frm = 0x002,
    fcsr = 0x003,
    mstatus = 0x300,
    misa = 0x301,
    mie = 0x304,
    mtvec = 0x305,
    mscratch = 0x340,
    mepc = 0x341,
    mcause = 0x342,
    mtval = 0x343,
    mip = 0x344,
    mvendorid = 0xf11,
    marchid = 0xf12,
    mimpid = 0xf13,
    mhartid = 0xf14,
};

/// The id of the single hart this file belongs to, read-only, Privileged 3.1.5.
pub const hart_id: u32 = 0x0000_0000;

/// Whether a misaligned load or store is answered or refused, which Privileged 3.6 leaves open.
pub const Misaligned = enum { answered, refused };

/// The mtvec MODE values a hart implements: one fixed mode, or a writable field, Privileged 3.1.8.
pub const TvecModes = enum { direct, vectored, both };

/// The choices the Privileged spec leaves to an implementation, and what its information
/// registers say.
pub const Implementation = struct {
    /// misa: the MXL field and the extension letters the hart reports, Privileged 3.1.1.
    isa: u32,
    /// mvendorid: the JEDEC vendor id, zero for a hart no vendor answers for, Privileged 3.1.2.
    vendor_id: u32,
    /// marchid, Privileged 3.1.3.
    architecture_id: u32,
    /// mimpid, Privileged 3.1.4.
    implementation_id: u32,
    /// The mstatus bits a write reaches; every other field keeps its value, Privileged 3.1.6.
    mstatus_writable: u32,
    /// The mcause bits a write keeps, its code field being WLRL, Privileged 3.1.15.
    cause_mask: u32,
    /// The writable bits of mtvec BASE, which fix the trap table's alignment, Privileged 3.1.8.
    tvec_base_mask: u32,
    /// The mtvec MODE values the hart implements, Privileged 3.1.8.
    tvec_modes: TvecModes,
    /// Whether a misaligned load or store is answered or refused, Privileged 3.6.
    misaligned: Misaligned,
    /// The non-zero word SC.W leaves in rd where it stored nothing, section 13.2.
    sc_failure: u32,
    /// Whether mie and mip are implemented, Privileged 3.1.10.
    interrupt_csrs: bool,
    /// Whether the unit and its fflags, frm and fcsr are implemented, section 20.2.
    float: bool,
};

/// The Sail RISC-V model as the lockstep oracle runs it: `sail_riscv_sim --rv32` under
/// `oracle/sail_rv32.json`.
pub const sail: Implementation = .{
    .isa = 0x4034_11af,
    .vendor_id = 0x0000_0000,
    .architecture_id = 0x0000_0000,
    .implementation_id = 0x0000_0000,
    .mstatus_writable = 0x0020_7888,
    .cause_mask = 0xffff_ffff,
    .tvec_base_mask = 0xffff_fffc,
    .tvec_modes = .both,
    .misaligned = .answered,
    .sc_failure = 1,
    .interrupt_csrs = true,
    .float = true,
};

/// The top bit of mcause, set for an interrupt and clear for an exception, Privileged 3.1.15.
pub const interrupt_flag: u32 = 0x8000_0000;

/// The exception codes this file writes into mcause, Privileged 3.1.15.
pub const Cause = enum(u32) {
    instruction_access_fault = 1,
    illegal_instruction = 2,
    load_access_fault = 5,
    store_access_fault = 7,
    ecall_from_user = 8,
    ecall_from_machine = 11,
};

/// The mstatus.FS states this hart tracks: off, or dirty, privileged section 3.1.6.7.
pub const ContextStatus = enum(u2) { off = 0, dirty = 3, _ };

/// The mstatus fields this file carries, Privileged 3.1.6; every other bit reads zero.
pub const Mstatus = packed struct(u32) {
    _0: u3 = 0,
    mie: bool = false,
    _4: u3 = 0,
    mpie: bool = false,
    _8: u3 = 0,
    mpp: Privilege = .user,
    fs: ContextStatus = .off,
    _15: u6 = 0,
    tw: bool = false,
    _22: u10 = 0,
};

/// The machine-mode CSR storage, the two halves of fcsr, and the implementation the hart runs.
pub const File = struct {
    mstatus: Mstatus = .{},
    mtvec: u32 = 0,
    mscratch: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,

    fflags: u5 = 0,
    frm: u3 = 0,
    implementation: Implementation = sail,

    /// The value a CSR number reads; fcsr is frm above fflags.
    pub fn read(self: *const File, number: Number) u32 {
        return switch (number) {
            .fflags => self.fflags,
            .frm => self.frm,
            .fcsr => @as(u32, self.frm) << 5 | self.fflags,
            .mstatus => @bitCast(self.mstatus),
            .misa => self.implementation.isa,
            .mie => self.mie,
            .mtvec => self.mtvec,
            .mscratch => self.mscratch,
            .mepc => self.mepc,
            .mcause => self.mcause,
            .mtval => self.mtval,
            .mip => self.mip,
            .mvendorid => self.implementation.vendor_id,
            .marchid => self.implementation.architecture_id,
            .mimpid => self.implementation.implementation_id,
            .mhartid => hart_id,
        };
    }

    /// Writes a CSR keeping only the bits the implementation has; mip and misa drop the write.
    pub fn write(self: *File, number: Number, value: u32) void {
        switch (number) {
            .mstatus => {
                const held: u32 = @bitCast(self.mstatus);
                const writable = self.implementation.mstatus_writable;
                const merged = (held & ~writable) | (value & writable);
                self.mstatus = .{
                    .mie = merged & 1 << 3 != 0,
                    .mpie = merged & 1 << 7 != 0,
                    .mpp = if (merged & 1 << 11 != 0) .machine else .user,
                    .fs = if (merged & 3 << 13 != 0) .dirty else .off,
                    .tw = merged & 1 << 21 != 0,
                };
            },
            .fflags => self.fflags = @truncate(value),
            .frm => self.frm = @truncate(value),
            .fcsr => {
                self.fflags = @truncate(value);
                self.frm = @truncate(value >> 5);
            },
            .mie => self.mie = value,
            .mip => {},
            .mtvec => self.mtvec = value & self.implementation.tvec_base_mask | self.mode(value),
            .mscratch => self.mscratch = value,
            .mepc => self.mepc = value & ~@as(u32, 1),
            .mcause => self.mcause = value & self.implementation.cause_mask,
            .mtval => self.mtval = value,
            .misa => {},
            .mvendorid, .marchid, .mimpid, .mhartid => unreachable,
        }
    }

    fn mode(self: *const File, value: u32) u32 {
        return switch (self.implementation.tvec_modes) {
            .direct => 0,
            .vectored => 1,
            .both => if (value & 3 < 2) value & 3 else self.mtvec & 3,
        };
    }

    /// Trap entry: stacks state for a synchronous exception and answers the mtvec base, section
    /// 3.1.6.1.
    pub fn enter(self: *File, privilege: *Privilege, cause: Cause, tval: u32, pc: u32) u32 {
        self.stack(privilege, @intFromEnum(cause), tval, pc);
        return self.mtvec & self.implementation.tvec_base_mask;
    }

    /// Interrupt entry: stacks state with mtval zero and answers the base, plus 4i where mtvec is
    /// vectored.
    pub fn interrupt(self: *File, privilege: *Privilege, id: u5, pc: u32) u32 {
        self.stack(privilege, interrupt_flag | id, 0, pc);
        const base = self.mtvec & self.implementation.tvec_base_mask;
        return if (self.mtvec & 3 == 1) base +% 4 * @as(u32, id) else base;
    }

    fn stack(self: *File, privilege: *Privilege, cause: u32, tval: u32, pc: u32) void {
        self.mepc = pc;
        self.mcause = cause;
        self.mtval = tval;
        self.mstatus.mpie = self.mstatus.mie;
        self.mstatus.mie = false;
        self.mstatus.mpp = privilege.*;
        privilege.* = .machine;
    }

    /// The MRET return: MIE from MPIE, MPIE set, privilege from MPP, resumes at mepc,
    /// Privileged 3.3.2.
    pub fn leave(self: *File, privilege: *Privilege) u32 {
        self.mstatus.mie = self.mstatus.mpie;
        self.mstatus.mpie = true;
        privilege.* = self.mstatus.mpp;
        self.mstatus.mpp = .user;
        return self.mepc;
    }
};

/// The PMP block's CSR numbers, Privileged 3.7.1, reached through the host rather than the hart.
pub const Protection = enum(u12) {
    pmpcfg0 = 0x3a0,
    pmpcfg1 = 0x3a1,
    pmpcfg2 = 0x3a2,
    pmpcfg3 = 0x3a3,
    pmpaddr0 = 0x3b0,
    pmpaddr1 = 0x3b1,
    pmpaddr2 = 0x3b2,
    pmpaddr3 = 0x3b3,
    pmpaddr4 = 0x3b4,
    pmpaddr5 = 0x3b5,
    pmpaddr6 = 0x3b6,
    pmpaddr7 = 0x3b7,
    pmpaddr8 = 0x3b8,
    pmpaddr9 = 0x3b9,
    pmpaddr10 = 0x3ba,
    pmpaddr11 = 0x3bb,
    pmpaddr12 = 0x3bc,
    pmpaddr13 = 0x3bd,
    pmpaddr14 = 0x3be,
    pmpaddr15 = 0x3bf,

    /// Which of the four pmpcfg registers this is, or null for an address register.
    pub fn group(self: Protection) ?usize {
        const raw = @intFromEnum(self);
        if (raw >= @intFromEnum(Protection.pmpaddr0)) return null;
        return raw & 0xf;
    }

    /// Which entry's address register this is.
    pub fn entry(self: Protection) usize {
        return @intFromEnum(self) & 0xf;
    }
};

/// What a CSR number names: a hart register or a protection-unit one.
pub const Target = union(enum) { hart: Number, protection: Protection };

/// Whether an access may reach a CSR under the rules of section 2.1, and what it names.
pub fn allowed(number: u12, privilege: Privilege, writing: bool, implementation: Implementation) ?Target {
    if (writing and number >> 10 == 0b11) return null;
    if (@intFromEnum(privilege) < @as(u2, @truncate(number >> 8))) return null;
    if (std.enums.fromInt(Protection, number)) |unit| return .{ .protection = unit };
    const hart = std.enums.fromInt(Number, number) orelse return null;
    if (!implementation.interrupt_csrs and (hart == .mie or hart == .mip)) return null;
    if (!implementation.float and (hart == .fflags or hart == .frm or hart == .fcsr)) return null;
    return .{ .hart = hart };
}

/// Whether the number is fflags, frm or fcsr, which mstatus.FS gates, section 3.1.6.7.
pub fn floating(number: Number) bool {
    return number == .fflags or number == .frm or number == .fcsr;
}

/// The name a disassembler prints for a CSR number, or null where none is implemented.
pub fn nameOf(number: u12) ?[]const u8 {
    if (std.enums.fromInt(Number, number)) |n| return @tagName(n);
    return @tagName(std.enums.fromInt(Protection, number) orelse return null);
}
