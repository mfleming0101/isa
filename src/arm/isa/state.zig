//! Architectural state of one Arm M-profile core: general registers, both stack
//! pointers, LR, PC, xPSR, CONTROL, the mask registers, the floating-point registers,
//! the authentication keys and the stack limits, with the flag and CONTROL bit masks
//! and helpers for register access, condition evaluation, IT state and flag setting.
//! xPSR defaults to the EPSR T bit, since a core out of reset is in T32 state, A2.3.1.
/// Register and status state of an Arm core.
pub const State = struct {
    r: [13]u32 = @splat(0),
    msp: u32 = 0,
    psp: u32 = 0,
    lr: u32 = 0,
    pc: u32 = 0,
    xpsr: u32 = flag_t,
    control: u32 = 0,
    primask: bool = false,
    basepri: u8 = 0,
    faultmask: bool = false,
    secure: bool = false,
    lockup: bool = false,
    exclusive: ?u32 = null,
    fp: [32]u32 = @splat(0),
    fpscr: u32 = 0,
    pac_key: [8]u32 = @splat(0),
    vpr: u32 = 0,
    msplim: u32 = 0,
    psplim: u32 = 0,

    /// xPSR N flag bit.
    pub const flag_n: u32 = 1 << 31;
    /// xPSR Z flag bit.
    pub const flag_z: u32 = 1 << 30;
    /// xPSR C flag bit.
    pub const flag_c: u32 = 1 << 29;
    /// xPSR V flag bit.
    pub const flag_v: u32 = 1 << 28;
    /// xPSR Q saturation flag bit.
    pub const flag_q: u32 = 1 << 27;
    /// xPSR GE flag bits.
    pub const flag_ge: u32 = 0xf << 16;
    /// EPSR T bit, set in Thumb state.
    pub const flag_t: u32 = 1 << 24;
    /// EPSR B bit, set after an indirect branch under BTI.
    pub const flag_b: u32 = 1 << 21;
    /// CONTROL.nPRIV: thread mode is unprivileged.
    pub const control_npriv: u32 = 1 << 0;
    /// CONTROL.SPSEL: thread mode uses PSP.
    pub const control_spsel: u32 = 1 << 1;
    /// CONTROL.FPCA: floating-point context active.
    pub const control_fpca: u32 = 1 << 2;
    /// CONTROL.SFPA: Secure floating-point active.
    pub const control_sfpa: u32 = 1 << 3;
    /// CONTROL.BTI_EN: privileged branch target identification enabled.
    pub const control_bti_en: u32 = 1 << 4;
    /// CONTROL.UBTI_EN: unprivileged branch target identification enabled.
    pub const control_ubti_en: u32 = 1 << 5;
    /// CONTROL.PAC_EN: privileged pointer authentication enabled.
    pub const control_pac_en: u32 = 1 << 6;
    /// CONTROL.UPAC_EN: unprivileged pointer authentication enabled.
    pub const control_upac_en: u32 = 1 << 7;
    /// Mask of the IPSR exception number in xPSR.
    pub const ipsr_mask: u32 = 0x1ff;
    /// Mask of the ITSTATE bits in xPSR.
    pub const it_mask: u32 = 0x0600_fc00;

    /// Registers banked between security states.
    pub const Banked = struct {
        msp: u32 = 0,
        psp: u32 = 0,
        control: u32 = 0,
        primask: bool = false,
        basepri: u8 = 0,
        faultmask: bool = false,
        pac_key: [8]u32 = @splat(0),
        msplim: u32 = 0,
        psplim: u32 = 0,
    };

    /// Whether the core is in handler mode, IPSR nonzero.
    pub fn handler(self: *const State) bool {
        return self.xpsr & ipsr_mask != 0;
    }

    /// The four-word pointer authentication key of the current privilege.
    pub fn pacKey(self: *const State) *const [4]u32 {
        return self.pac_key[if (self.privileged()) 0 else 4..][0..4];
    }

    /// Whether execution is privileged: handler mode or CONTROL.nPRIV clear.
    pub fn privileged(self: *const State) bool {
        return self.handler() or self.control & control_npriv == 0;
    }

    /// Whether FAULTMASK is clear and the active exception is neither NMI nor HardFault.
    pub fn maskable(self: *const State) bool {
        return !self.faultmask and self.xpsr & ipsr_mask != 2 and self.xpsr & ipsr_mask != 3;
    }

    /// The current stack pointer, PSP or MSP as CONTROL.SPSEL selects.
    pub fn sp(self: *const State) u32 {
        return if (self.control & control_spsel != 0) self.psp else self.msp;
    }

    /// Writes PC from an address, taking the T bit from bit 0.
    pub fn branchTo(self: *State, address: u32) void {
        self.xpsr = (self.xpsr & ~flag_t) | ((address & 1) << 24);
        self.pc = address & ~@as(u32, 1);
    }

    /// Reads register i: sp, lr and pc plus four for 13 to 15.
    pub fn get(self: *const State, i: u4) u32 {
        return switch (i) {
            13 => self.sp(),
            14 => self.lr,
            15 => self.pc +% 4,
            else => self.r[i],
        };
    }

    /// Writes register i, routing 13 to the selected stack pointer.
    pub fn set(self: *State, i: u4, value: u32) void {
        switch (i) {
            13 => self.setSp(value),
            14 => self.lr = value,
            15 => self.pc = value,
            else => self.r[i] = value,
        }
    }

    /// Writes the selected stack pointer with bits 1 and 0 cleared.
    pub fn setSp(self: *State, value: u32) void {
        const aligned = value & ~@as(u32, 3);
        if (self.control & control_spsel != 0) self.psp = aligned else self.msp = aligned;
    }

    /// Evaluates a four-bit condition code against the N, Z, C and V flags.
    pub fn condition(self: *const State, cond: u4) bool {
        const n = self.xpsr & flag_n != 0;
        const z = self.xpsr & flag_z != 0;
        const c = self.xpsr & flag_c != 0;
        const v = self.xpsr & flag_v != 0;
        const result = switch (@as(u3, @truncate(cond >> 1))) {
            0 => z,
            1 => c,
            2 => n,
            3 => v,
            4 => c and !z,
            5 => n == v,
            6 => n == v and !z,
            7 => true,
        };
        return if (cond & 1 == 1 and cond != 15) !result else result;
    }

    /// Whether an IT block is in progress.
    pub fn inIt(self: *const State) bool {
        return self.xpsr & it_mask != 0;
    }

    /// Whether the current IT block condition holds.
    pub fn itPasses(self: *const State) bool {
        return self.condition(@truncate(self.xpsr >> 12));
    }

    /// The eight-bit ITSTATE assembled from its two xPSR fields.
    pub fn itState(self: *const State) u8 {
        return @truncate(((self.xpsr >> 8) & 0xfc) | ((self.xpsr >> 25) & 3));
    }

    /// Writes an eight-bit ITSTATE into its two xPSR fields.
    pub fn setItState(self: *State, it: u8) void {
        self.xpsr = (self.xpsr & ~it_mask) | (@as(u32, it & 0xfc) << 8) | (@as(u32, it & 3) << 25);
    }

    /// Advances ITSTATE past one instruction, ending the block when exhausted.
    pub fn itAdvance(self: *State) void {
        const it = self.itState();
        self.setItState(if (it & 7 == 0) 0 else (it & 0xe0) | ((it & 0x0f) << 1));
    }

    /// Sets N and Z from a result, leaving C and V.
    pub fn setNZ(self: *State, result: u32) void {
        const z: u32 = if (result == 0) flag_z else 0;
        self.xpsr = (self.xpsr & ~(flag_n | flag_z)) | (result & flag_n) | z;
    }

    /// Sets N and Z from a result and C from carry.
    pub fn setNZC(self: *State, result: u32, carry: bool) void {
        const c: u32 = if (carry) flag_c else 0;
        self.xpsr = (self.xpsr & ~flag_c) | c;
        self.setNZ(result);
    }

    /// Sets N and Z from a result, C from carry and V from overflow.
    pub fn setNZCV(self: *State, result: u32, carry: bool, overflow: bool) void {
        const c: u32 = if (carry) flag_c else 0;
        const v: u32 = if (overflow) flag_v else 0;
        self.xpsr &= ~(flag_c | flag_v);
        self.xpsr |= c | v;
        self.setNZ(result);
    }
};
