//! The RISC-V handler table the generated decode tree binds to. Re-exports the hart state, outcome
//! and class types, the access and CSR modules and the handler files, then names one handler per
//! row (`MNEMONIC_index`) and one target function per branching row under `target`. Also holds the
//! register and rounding-mode name tables and the helpers every handler shares: `write`, which
//! drops x0, `primed`, `sext` and `writeCsr`.
const std = @import("std");
const instruction = @import("../../riscv/isa/instruction.zig");
/// Memory access helpers the handlers read and write through.
pub const access = @import("../../riscv/isa/access.zig");
/// The CSR file, numbers and access rules.
pub const csr = @import("../../riscv/isa/csr.zig");

/// The hart state every handler operates on.
pub const State = @import("../../riscv/isa/state.zig").State;
/// Bit set of the decode groups a hart implements, one bit per group.
pub const Groups = @import("../../riscv/isa/decode.zig").Groups;
/// What a handler answers with.
pub const Outcome = instruction.Outcome;
/// The cycle class a row is charged by.
pub const Class = instruction.Class;

/// One tree leaf's answer: outcome and class. The default is what a code no row of the group set
/// matches answers: an illegal instruction, section 1.5.
pub const Done = packed struct(u16) {
    outcome: Outcome = .illegal,
    class: Class = .data_processing,
    _: u4 = 0,

    /// An answer with the given outcome and class.
    pub fn by(outcome: Outcome, comptime class: Class) Done {
        return .{ .outcome = outcome, .class = class };
    }
};

/// Integer arithmetic and logic handlers.
pub const alu = @import("alu.zig");
/// Load and store handlers.
pub const mem = @import("mem.zig");
/// Multiply and divide handlers.
pub const mul = @import("mul.zig");
/// Branch and jump handlers and their target functions.
pub const branch = @import("branch.zig");
/// FENCE, ECALL, EBREAK, CSR access, MRET and WFI handlers.
pub const system = @import("system.zig");
/// LR.W, SC.W and AMO handlers.
pub const atomic = @import("atomic.zig");
/// Single-precision floating-point handlers.
pub const fp = @import("fp.zig");

/// Handler for RV32I LUI: load upper immediate.
pub const LUI_318 = alu.lui;
/// Handler for RV32I AUIPC: add upper immediate to pc.
pub const AUIPC_319 = alu.auipc;
/// Handler for RV32I JAL: jump and link.
pub const JAL_320 = branch.jal;
/// Handler for RV32I JALR: jump and link register.
pub const JALR_321 = branch.jalr;
/// Handler for RV32I BEQ: branch if equal.
pub const BEQ_322 = branch.Branch(.eq).call;
/// Handler for RV32I BNE: branch if not equal.
pub const BNE_323 = branch.Branch(.ne).call;
/// Handler for RV32I BLT: branch if less than, signed.
pub const BLT_324 = branch.Branch(.lt).call;
/// Handler for RV32I BGE: branch if greater or equal, signed.
pub const BGE_325 = branch.Branch(.ge).call;
/// Handler for RV32I BLTU: branch if less than, unsigned.
pub const BLTU_326 = branch.Branch(.ltu).call;
/// Handler for RV32I BGEU: branch if greater or equal, unsigned.
pub const BGEU_327 = branch.Branch(.geu).call;
/// Handler for RV32I LB: load byte, sign-extended.
pub const LB_328 = mem.Load(8, true).call;
/// Handler for RV32I LH: load halfword, sign-extended.
pub const LH_329 = mem.Load(16, true).call;
/// Handler for RV32I LW: load word.
pub const LW_330 = mem.Load(32, false).call;
/// Handler for RV32I LBU: load byte, zero-extended.
pub const LBU_331 = mem.Load(8, false).call;
/// Handler for RV32I LHU: load halfword, zero-extended.
pub const LHU_332 = mem.Load(16, false).call;
/// Handler for RV32I SB: store byte.
pub const SB_333 = mem.Store(8).call;
/// Handler for RV32I SH: store halfword.
pub const SH_334 = mem.Store(16).call;
/// Handler for RV32I SW: store word.
pub const SW_335 = mem.Store(32).call;
/// Handler for RV32I ADDI: add immediate.
pub const ADDI_336 = alu.Imm(.add).call;
/// Handler for RV32I SLTI: set if less than immediate, signed.
pub const SLTI_337 = alu.Imm(.slt).call;
/// Handler for RV32I SLTIU: set if less than immediate, unsigned.
pub const SLTIU_338 = alu.Imm(.sltu).call;
/// Handler for RV32I XORI: exclusive-or immediate.
pub const XORI_339 = alu.Imm(.xor).call;
/// Handler for RV32I ORI: or immediate.
pub const ORI_340 = alu.Imm(.@"or").call;
/// Handler for RV32I ANDI: and immediate.
pub const ANDI_341 = alu.Imm(.@"and").call;
/// Handler for RV32I SLLI: shift left logical immediate.
pub const SLLI_342 = alu.Shamt(.sll).call;
/// Handler for RV32I SRLI: shift right logical immediate.
pub const SRLI_343 = alu.Shamt(.srl).call;
/// Handler for RV32I SRAI: shift right arithmetic immediate.
pub const SRAI_344 = alu.Shamt(.sra).call;
/// Handler for RV32I ADD: add.
pub const ADD_345 = alu.Reg(.add).call;
/// Handler for RV32I SUB: subtract.
pub const SUB_346 = alu.Reg(.sub).call;
/// Handler for RV32I SLL: shift left logical.
pub const SLL_347 = alu.Reg(.sll).call;
/// Handler for RV32I SLT: set if less than, signed.
pub const SLT_348 = alu.Reg(.slt).call;
/// Handler for RV32I SLTU: set if less than, unsigned.
pub const SLTU_349 = alu.Reg(.sltu).call;
/// Handler for RV32I XOR: exclusive-or.
pub const XOR_350 = alu.Reg(.xor).call;
/// Handler for RV32I SRL: shift right logical.
pub const SRL_351 = alu.Reg(.srl).call;
/// Handler for RV32I SRA: shift right arithmetic.
pub const SRA_352 = alu.Reg(.sra).call;
/// Handler for RV32I OR: or.
pub const OR_353 = alu.Reg(.@"or").call;
/// Handler for RV32I AND: and.
pub const AND_354 = alu.Reg(.@"and").call;
/// Handler for RV32I FENCE: memory ordering, a no-op here.
pub const FENCE_355 = system.fence;
/// Handler for RV32I ECALL: environment call.
pub const ECALL_356 = system.ecall;
/// Handler for RV32I EBREAK: breakpoint.
pub const EBREAK_357 = system.ebreak;

/// Handler for RV32M MUL: lower word of the product.
pub const MUL_358 = mul.mul;
/// Handler for RV32M MULH: upper word of the signed product.
pub const MULH_359 = mul.mulh;
/// Handler for RV32M MULHSU: upper word of the signed-by-unsigned product.
pub const MULHSU_360 = mul.mulhsu;
/// Handler for RV32M MULHU: upper word of the unsigned product.
pub const MULHU_361 = mul.mulhu;
/// Handler for RV32M DIV: signed divide.
pub const DIV_362 = mul.div;
/// Handler for RV32M DIVU: unsigned divide.
pub const DIVU_363 = mul.divu;
/// Handler for RV32M REM: signed remainder.
pub const REM_364 = mul.rem;
/// Handler for RV32M REMU: unsigned remainder.
pub const REMU_365 = mul.remu;

/// Handler for RV32C C.ADDI4SPN: add scaled immediate to sp into rd′.
pub const @"C.ADDI4SPN_366" = alu.addi4spn;
/// Handler for RV32C C.LW: load word.
pub const @"C.LW_367" = mem.clw;
/// Handler for RV32C C.SW: store word.
pub const @"C.SW_368" = mem.csw;
/// Handler for RV32C C.ADDI: add immediate in place.
pub const @"C.ADDI_369" = alu.addi;
/// Handler for RV32C C.NOP: no operation.
pub const @"C.NOP_370" = alu.nop;
/// Handler for RV32C C.JAL: jump and link.
pub const @"C.JAL_371" = branch.Jump(true).call;
/// Handler for RV32C C.LI: load immediate.
pub const @"C.LI_372" = alu.li;
/// Handler for RV32C C.LUI: load upper immediate.
pub const @"C.LUI_373" = alu.clui;
/// Handler for RV32C C.ADDI16SP: add scaled immediate to sp.
pub const @"C.ADDI16SP_374" = alu.addi16sp;
/// Handler for RV32C C.SRLI: shift right logical immediate.
pub const @"C.SRLI_375" = alu.CShift(.srl).call;
/// Handler for RV32C C.SRAI: shift right arithmetic immediate.
pub const @"C.SRAI_376" = alu.CShift(.sra).call;
/// Handler for RV32C C.ANDI: and immediate.
pub const @"C.ANDI_377" = alu.andi;
/// Handler for RV32C C.SUB: subtract.
pub const @"C.SUB_378" = alu.CReg(.sub).call;
/// Handler for RV32C C.XOR: exclusive-or.
pub const @"C.XOR_379" = alu.CReg(.xor).call;
/// Handler for RV32C C.OR: or.
pub const @"C.OR_380" = alu.CReg(.@"or").call;
/// Handler for RV32C C.AND: and.
pub const @"C.AND_381" = alu.CReg(.@"and").call;
/// Handler for RV32C C.J: jump.
pub const @"C.J_382" = branch.Jump(false).call;
/// Handler for RV32C C.BEQZ: branch if zero.
pub const @"C.BEQZ_383" = branch.Compare(true).call;
/// Handler for RV32C C.BNEZ: branch if not zero.
pub const @"C.BNEZ_384" = branch.Compare(false).call;
/// Handler for RV32C C.SLLI: shift left logical immediate.
pub const @"C.SLLI_385" = alu.slli;
/// Handler for RV32C C.LWSP: load word from the stack.
pub const @"C.LWSP_386" = mem.lwsp;
/// Handler for RV32C C.MV: move.
pub const @"C.MV_387" = alu.mv;
/// Handler for RV32C C.JR: jump register.
pub const @"C.JR_388" = branch.jr;
/// Handler for RV32C C.ADD: add.
pub const @"C.ADD_389" = alu.addTo;
/// Handler for RV32C C.JALR: jump and link register.
pub const @"C.JALR_390" = branch.jalrC;
/// Handler for RV32C C.EBREAK: breakpoint.
pub const @"C.EBREAK_391" = system.ebreak;
/// Handler for RV32C C.SWSP: store word to the stack.
pub const @"C.SWSP_392" = mem.swsp;

/// Handler for RV32A LR.W: load reserved.
pub const @"LR.W_1481" = atomic.lr;
/// Handler for RV32A SC.W: store conditional.
pub const @"SC.W_1482" = atomic.sc;
/// Handler for RV32A AMOSWAP.W: atomic swap.
pub const @"AMOSWAP.W_1483" = atomic.Amo(.swap).call;
/// Handler for RV32A AMOADD.W: atomic add.
pub const @"AMOADD.W_1484" = atomic.Amo(.add).call;
/// Handler for RV32A AMOXOR.W: atomic exclusive-or.
pub const @"AMOXOR.W_1485" = atomic.Amo(.xor).call;
/// Handler for RV32A AMOAND.W: atomic and.
pub const @"AMOAND.W_1486" = atomic.Amo(.@"and").call;
/// Handler for RV32A AMOOR.W: atomic or.
pub const @"AMOOR.W_1487" = atomic.Amo(.@"or").call;
/// Handler for RV32A AMOMIN.W: atomic signed minimum.
pub const @"AMOMIN.W_1488" = atomic.Amo(.min).call;
/// Handler for RV32A AMOMAX.W: atomic signed maximum.
pub const @"AMOMAX.W_1489" = atomic.Amo(.max).call;
/// Handler for RV32A AMOMINU.W: atomic unsigned minimum.
pub const @"AMOMINU.W_1490" = atomic.Amo(.minu).call;
/// Handler for RV32A AMOMAXU.W: atomic unsigned maximum.
pub const @"AMOMAXU.W_1491" = atomic.Amo(.maxu).call;

/// Handler for Zicsr CSRRW: CSR read and write.
pub const CSRRW_1492 = system.Access(.swap, false).call;
/// Handler for Zicsr CSRRS: CSR read and set bits.
pub const CSRRS_1493 = system.Access(.set, false).call;
/// Handler for Zicsr CSRRC: CSR read and clear bits.
pub const CSRRC_1494 = system.Access(.clear, false).call;
/// Handler for Zicsr CSRRWI: CSR read and write immediate.
pub const CSRRWI_1495 = system.Access(.swap, true).call;
/// Handler for Zicsr CSRRSI: CSR read and set bits immediate.
pub const CSRRSI_1496 = system.Access(.set, true).call;
/// Handler for Zicsr CSRRCI: CSR read and clear bits immediate.
pub const CSRRCI_1497 = system.Access(.clear, true).call;
/// Handler for privileged MRET: return from a machine-mode trap.
pub const MRET_1498 = system.mret;
/// Handler for privileged WFI: wait for interrupt.
pub const WFI_1499 = system.wfi;

/// Handler for RV32F FLW: load single.
pub const FLW_1500 = fp.load;
/// Handler for RV32F FSW: store single.
pub const FSW_1501 = fp.store;
/// Handler for RV32F FMADD.S: fused multiply-add.
pub const @"FMADD.S_1502" = fp.Fused(false, false).call;
/// Handler for RV32F FMSUB.S: fused multiply-subtract.
pub const @"FMSUB.S_1503" = fp.Fused(false, true).call;
/// Handler for RV32F FNMSUB.S: fused negated multiply-subtract.
pub const @"FNMSUB.S_1504" = fp.Fused(true, false).call;
/// Handler for RV32F FNMADD.S: fused negated multiply-add.
pub const @"FNMADD.S_1505" = fp.Fused(true, true).call;
/// Handler for RV32F FADD.S: add.
pub const @"FADD.S_1506" = fp.Arith(.add).call;
/// Handler for RV32F FSUB.S: subtract.
pub const @"FSUB.S_1507" = fp.Arith(.sub).call;
/// Handler for RV32F FMUL.S: multiply.
pub const @"FMUL.S_1508" = fp.Arith(.mul).call;
/// Handler for RV32F FDIV.S: divide.
pub const @"FDIV.S_1509" = fp.Arith(.div).call;
/// Handler for RV32F FSQRT.S: square root.
pub const @"FSQRT.S_1510" = fp.sqrt;
/// Handler for RV32F FSGNJ.S: sign inject.
pub const @"FSGNJ.S_1511" = fp.Sgnj(.copy).call;
/// Handler for RV32F FSGNJN.S: sign inject negated.
pub const @"FSGNJN.S_1512" = fp.Sgnj(.negate).call;
/// Handler for RV32F FSGNJX.S: sign inject exclusive-or.
pub const @"FSGNJX.S_1513" = fp.Sgnj(.exclusive).call;
/// Handler for RV32F FMIN.S: minimum.
pub const @"FMIN.S_1514" = fp.MinMax(false).call;
/// Handler for RV32F FMAX.S: maximum.
pub const @"FMAX.S_1515" = fp.MinMax(true).call;
/// Handler for RV32F FCVT.W.S: convert single to signed word.
pub const @"FCVT.W.S_1516" = fp.ToInt(true).call;
/// Handler for RV32F FCVT.WU.S: convert single to unsigned word.
pub const @"FCVT.WU.S_1517" = fp.ToInt(false).call;
/// Handler for RV32F FMV.X.W: move single bits to integer register.
pub const @"FMV.X.W_1518" = fp.moveOut;
/// Handler for RV32F FEQ.S: compare equal.
pub const @"FEQ.S_1519" = fp.Compare(.eq).call;
/// Handler for RV32F FLT.S: compare less than.
pub const @"FLT.S_1520" = fp.Compare(.lt).call;
/// Handler for RV32F FLE.S: compare less or equal.
pub const @"FLE.S_1521" = fp.Compare(.le).call;
/// Handler for RV32F FCLASS.S: classify.
pub const @"FCLASS.S_1522" = fp.class;
/// Handler for RV32F FCVT.S.W: convert signed word to single.
pub const @"FCVT.S.W_1523" = fp.FromInt(true).call;
/// Handler for RV32F FCVT.S.WU: convert unsigned word to single.
pub const @"FCVT.S.WU_1524" = fp.FromInt(false).call;
/// Handler for RV32F FMV.W.X: move integer bits to single register.
pub const @"FMV.W.X_1525" = fp.moveIn;
/// Handler for RV32C with F C.FLW: load single.
pub const @"C.FLW_1526" = fp.clw;
/// Handler for RV32C with F C.FSW: store single.
pub const @"C.FSW_1527" = fp.csw;
/// Handler for RV32C with F C.FLWSP: load single from the stack.
pub const @"C.FLWSP_1528" = fp.lwsp;
/// Handler for RV32C with F C.FSWSP: store single to the stack.
pub const @"C.FSWSP_1529" = fp.swsp;

/// Branch and jump target functions the renderer prints, one per branching row.
pub const target = struct {
    /// Target of RV32I JAL.
    pub const JAL_320 = branch.targetJ;
    /// Target of RV32I BEQ.
    pub const BEQ_322 = branch.targetB;
    /// Target of RV32I BNE.
    pub const BNE_323 = branch.targetB;
    /// Target of RV32I BLT.
    pub const BLT_324 = branch.targetB;
    /// Target of RV32I BGE.
    pub const BGE_325 = branch.targetB;
    /// Target of RV32I BLTU.
    pub const BLTU_326 = branch.targetB;
    /// Target of RV32I BGEU.
    pub const BGEU_327 = branch.targetB;
    /// Target of RV32C C.JAL.
    pub const @"C.JAL_371" = branch.targetCJ;
    /// Target of RV32C C.J.
    pub const @"C.J_382" = branch.targetCJ;
    /// Target of RV32C C.BEQZ.
    pub const @"C.BEQZ_383" = branch.targetCB;
    /// Target of RV32C C.BNEZ.
    pub const @"C.BNEZ_384" = branch.targetCB;
};

/// The integer registers by calling-convention name.
pub const abi = [32][]const u8{
    "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

/// The single-precision registers by calling-convention name, chapter 26.
pub const fpabi = [32][]const u8{
    "ft0", "ft1", "ft2",  "ft3",  "ft4", "ft5", "ft6",  "ft7",
    "fs0", "fs1", "fa0",  "fa1",  "fa2", "fa3", "fa4",  "fa5",
    "fa6", "fa7", "fs2",  "fs3",  "fs4", "fs5", "fs6",  "fs7",
    "fs8", "fs9", "fs10", "fs11", "ft8", "ft9", "ft10", "ft11",
};

/// The rounding modes by mnemonic, section 20.2 table 25; reserved encodings print their number.
pub const rounding = [8][]const u8{ "rne", "rtz", "rdn", "rup", "rmm", "5", "6", "dyn" };

/// Writes an integer register, discarding a write to x0, section 2.1.
pub fn write(s: *State, d: u32, value: u32) void {
    if (d != 0) s.x[d] = value;
}

/// Prints a CSR's name, or its number where the part implements none there.
pub fn writeCsr(w: *std.Io.Writer, number: u32) std.Io.Writer.Error!void {
    if (csr.nameOf(@intCast(number))) |name| return w.writeAll(name);
    return w.print("0x{x:0>3}", .{number});
}

/// Maps a three-bit compressed register field to x8 through x15.
pub fn primed(i: u32) u32 {
    return i + 8;
}

/// Sign-extends a value from the given width.
pub fn sext(width: u5, value: u32) u32 {
    const shift: u5 = @intCast(32 - @as(u6, width));
    return @bitCast(@as(i32, @bitCast(value << shift)) >> shift);
}
