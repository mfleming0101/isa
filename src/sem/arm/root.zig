//! Row handlers for the Arm T32 semantics, one `pub` per encoding row of the spec tables, named
//! for the row's mnemonic and the manual's encoding label. Each is an alias into alu, mem, branch,
//! system, dsp, fp or mve, instantiated with the row's comptime shape; `target` holds the branch
//! destination functions the disassembler prints. The generated decode tree calls these by
//! name with the row's fields, and the small helpers at the bottom are what the handler
//! modules share: state access, IT tracking and the host read and write entry points.
const state = @import("../../arm/isa/state.zig");
/// The Arm instruction model: Outcome, Class, Cost and Failure.
pub const instruction = @import("../../arm/isa/instruction.zig");
/// Memory access layer the handlers read and write through, DDI0403 E2.1.125 alignment rules.
pub const access = @import("../../arm/isa/access.zig");
/// Pointer authentication and BTI support the hint, SMMLA/SMMLS and branch rows call into.
pub const pac = @import("../../arm/isa/pac.zig");
/// Scalar floating-point row handlers: single, double and half precision plus the system registers.
pub const fp = @import("fp.zig");
const mve = @import("mve.zig");

/// The one core state every handler mutates: registers, xpsr, control, fp and vpr.
pub const State = state.State;
/// Bit set of the decode groups a core implements, one bit per group.
pub const Groups = @import("../../arm/isa/decode.zig").Groups;
/// What a handler answers with: next, branched, a fault, or something the host finishes.
pub const Outcome = instruction.Outcome;
/// Cost class of a row, which the generated tree prices each leaf by.
pub const Class = instruction.Class;
/// Errors a memory access can raise: DataFault, Unaligned, Violation, Secure.
pub const Failure = instruction.Failure;

/// One generated-tree leaf's answer: the outcome and the row's cost class. The default is what a
/// code no row of the group set matches answers: UNDEFINED, A5.3.
pub const Done = packed struct(u16) {
    outcome: Outcome = .undefined,
    class: Class = .data_processing,
    _: u4 = 0,

    /// Builds a Done from a handler's outcome and the row's comptime class.
    pub fn by(outcome: Outcome, comptime class: Class) Done {
        return .{ .outcome = outcome, .class = class };
    }
};

/// Integer data-processing row handlers: arithmetic, logic, shifts, extends, multiplies, bitfields.
pub const alu = @import("alu.zig");
/// Load, store, block-transfer and exclusive-monitor row handlers.
pub const mem = @import("mem.zig");
/// Branch, IT, low-overhead-loop row handlers and their disassembly target functions.
pub const branch = @import("branch.zig");
/// SVC, hints, CPS, MSR/MRS, SG, TT and CLRM row handlers.
pub const system = @import("system.zig");
/// DSP extension row handlers: SIMD, saturating, halfword and dual multiplies, packing.
pub const dsp = @import("dsp.zig");

/// ThumbExpandImm without the carry, A6.3.2, as disassembly prints it.
pub const expandImm = alu.expandImm;
/// Expands an MVE cmode/imm8 pair into the two 32-bit words it replicates.
pub const expandedWord = mve.lib.expandedWord;

/// APSR.N bit mask, bit 31 of xpsr.
pub const flag_n = State.flag_n;
/// APSR.Z bit mask, bit 30 of xpsr.
pub const flag_z = State.flag_z;
/// APSR.C bit mask, bit 29 of xpsr.
pub const flag_c = State.flag_c;
/// APSR.V bit mask, bit 28 of xpsr.
pub const flag_v = State.flag_v;
/// APSR.Q sticky saturation bit mask, bit 27 of xpsr.
pub const flag_q = State.flag_q;
/// EPSR.T Thumb state bit mask, bit 24 of xpsr.
pub const flag_t = State.flag_t;
/// Mask of the IPSR exception number, the low nine bits of xpsr.
pub const ipsr_mask = State.ipsr_mask;
/// MOVS `movs Rd, #imm`: Rd = imm8, N and Z set outside an IT block.
pub const MOV_imm_T1 = alu.movs;
/// ADDS `adds Rd, Rn, #imm`: Rd = Rn + imm3, flags set outside an IT block.
pub const ADD_imm_T1 = alu.adds;
/// B `b label`, A7.7.12: unconditional, 11-bit halfword offset from pc+4.
pub const B_T2 = branch.b;
/// STR `str Rt, [Rn, #imm*4]`, A6.7.42ff: word store, offset scaled by the width, low registers only.
pub const STR_imm_T1 = mem.NarrowImm(32, false, false).call;
/// LDR `ldr Rt, [Rn, #imm*4]`, A6.7.42ff: word load, offset scaled by the width, low registers only.
pub const LDR_imm_T1 = mem.NarrowImm(32, false, true).call;
/// STR `str Rt, [sp, #imm*4]`: word store at sp plus imm8*4.
pub const STR_imm_T2 = mem.strSp;
/// LDR `ldr Rt, [sp, #imm*4]`: word load from sp plus imm8*4.
pub const LDR_imm_T2 = mem.ldrSp;
/// LDR `ldr Rt, [pc, #imm*4]`: word load from the word-aligned pc plus imm8*4, A5.1.2.
pub const LDR_lit_T1 = mem.ldrLit;
/// LSLS `lsls Rd, Rm, #imm`, A2.2.1 Shift_C: shift by zero leaves C alone; flags outside IT.
pub const LSL_imm_T1 = alu.lsls;
/// SUBS `subs Rd, Rn, #imm`: Rd = Rn - imm3, flags set outside an IT block.
pub const SUB_imm_T1 = alu.subs;
/// CMP `cmp Rn, #imm`: flags from Rn - imm8, nothing written.
pub const CMP_imm_T1 = alu.cmp;
/// ADDS `adds Rd, #imm`, A6.7.3: Rd = Rd + imm8, flags set outside an IT block.
pub const ADD_imm_T2 = alu.Arith8(false).call;
/// SUBS `subs Rd, #imm`, A6.7.66: Rd = Rd - imm8, flags set outside an IT block.
pub const SUB_imm_T2 = alu.Arith8(true).call;
/// CMP `cmp Rn, Rm`, low registers: flags from Rn - Rm, nothing written.
pub const CMP_reg_T1 = alu.cmpReg;
/// ADD `add Rd, Rm`, A6.7.4: any register pair, Rd = Rd + Rm; writing r15 branches.
pub const ADD_reg_T2 = alu.addHigh;
/// MOV `mov Rd, Rm`, A6.7.53: any register pair, no flags; writing r15 branches.
pub const MOV_reg_T1 = alu.movHigh;
/// BX `bx Rm`, A7.7.20: interworking branch to Rm; magic addresses are exception or function returns.
pub const BX_T1 = branch.bx;
/// NOP `nop`, A7.7.88: the one row defined to do nothing.
pub const NOP_T1 = nop;
/// BEQ `beq label`, A7.7.12: taken when Z set, 8-bit halfword offset, A7.3.
pub const BEQ_T1 = branch.Narrow(.eq).call;
/// BNE `bne label`, A7.7.12: taken when Z clear, 8-bit halfword offset, A7.3.
pub const BNE_T1 = branch.Narrow(.ne).call;
/// CBZ `cbz Rn, label`, A7.7.21: forward branch when Rn is zero, 6-bit halfword offset.
pub const CBZ_T1 = branch.cbz;
/// BL `bl label`, A7.7.18: lr = return address with T set, 24-bit halfword offset.
pub const BL_T1 = branch.bl;
/// MOVW `movw Rd, #imm16`: Rd = zero-extended 16-bit immediate from four split fields.
pub const MOVW_imm_T3 = alu.movw;
/// MOVT `movt Rd, #imm16`: replaces Rd's top halfword with the 16-bit immediate.
pub const MOVT_T1 = alu.movt;
/// ORR `orr{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn OR const, S sets flags; Rn=15 is MOV.
pub const ORR_imm_T1 = alu.Imm(.orr).call;
/// SUB `sub{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn - const, S sets flags; Rd=15 is CMP.
pub const SUB_imm_T3 = alu.Imm(.sub).call;
/// ADD `add{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn + shifted Rm, S sets flags, Rd=15 discards.
pub const ADD_reg_T3 = alu.Reg(.add).call;
/// PUSH `push {list}`, A7.7.99: lowest register lowest; sp moves only after every word, B1.5.10.
pub const PUSH_T1 = mem.push;
/// STMDB `stmdb Rn{!}, {list}`, A7.7.159: stores the list below Rn, writeback per W; PUSH.W is the sp form.
pub const STMDB_T1 = mem.stmdb;
/// RSB `rsb{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn reverse - shifted Rm, S sets flags, Rd=15 discards.
pub const RSB_reg_T1 = alu.Reg(.rsb).call;
/// BCS `bcs label`, A7.7.12: taken when C set, 8-bit halfword offset, A7.3.
pub const BCS_T1 = branch.Narrow(.cs).call;
/// BCC `bcc label`, A7.7.12: taken when C clear, 8-bit halfword offset, A7.3.
pub const BCC_T1 = branch.Narrow(.cc).call;
/// BMI `bmi label`, A7.7.12: taken when N set, 8-bit halfword offset, A7.3.
pub const BMI_T1 = branch.Narrow(.mi).call;
/// BPL `bpl label`, A7.7.12: taken when N clear, 8-bit halfword offset, A7.3.
pub const BPL_T1 = branch.Narrow(.pl).call;
/// BHI `bhi label`, A7.7.12: taken when C set and Z clear, 8-bit halfword offset, A7.3.
pub const BHI_T1 = branch.Narrow(.hi).call;
/// BLS `bls label`, A7.7.12: taken when C clear or Z set, 8-bit halfword offset, A7.3.
pub const BLS_T1 = branch.Narrow(.ls).call;
/// BGE `bge label`, A7.7.12: taken when N equals V, 8-bit halfword offset, A7.3.
pub const BGE_T1 = branch.Narrow(.ge).call;
/// BLT `blt label`, A7.7.12: taken when N differs from V, 8-bit halfword offset, A7.3.
pub const BLT_T1 = branch.Narrow(.lt).call;
/// BGT `bgt label`, A7.7.12: taken when Z clear and N equals V, 8-bit halfword offset, A7.3.
pub const BGT_T1 = branch.Narrow(.gt).call;
/// BLE `ble label`, A7.7.12: taken when Z set or N differs from V, 8-bit halfword offset, A7.3.
pub const BLE_T1 = branch.Narrow(.le).call;
/// BEQ.W `beq.w label`, A7.7.12: taken when Z set, 20-bit halfword offset, A7.3.
pub const BEQ_T3 = branch.Wide(.eq).call;
/// BNE.W `bne.w label`, A7.7.12: taken when Z clear, 20-bit halfword offset, A7.3.
pub const BNE_T3 = branch.Wide(.ne).call;
/// BCS.W `bcs.w label`, A7.7.12: taken when C set, 20-bit halfword offset, A7.3.
pub const BCS_T3 = branch.Wide(.cs).call;
/// BCC.W `bcc.w label`, A7.7.12: taken when C clear, 20-bit halfword offset, A7.3.
pub const BCC_T3 = branch.Wide(.cc).call;
/// BMI.W `bmi.w label`, A7.7.12: taken when N set, 20-bit halfword offset, A7.3.
pub const BMI_T3 = branch.Wide(.mi).call;
/// BHI.W `bhi.w label`, A7.7.12: taken when C set and Z clear, 20-bit halfword offset, A7.3.
pub const BHI_T3 = branch.Wide(.hi).call;
/// BGE.W `bge.w label`, A7.7.12: taken when N equals V, 20-bit halfword offset, A7.3.
pub const BGE_T3 = branch.Wide(.ge).call;
/// BLT.W `blt.w label`, A7.7.12: taken when N differs from V, 20-bit halfword offset, A7.3.
pub const BLT_T3 = branch.Wide(.lt).call;
/// BGT.W `bgt.w label`, A7.7.12: taken when Z clear and N equals V, 20-bit halfword offset, A7.3.
pub const BGT_T3 = branch.Wide(.gt).call;
/// BLE.W `ble.w label`, A7.7.12: taken when Z set or N differs from V, 20-bit halfword offset, A7.3.
pub const BLE_T3 = branch.Wide(.le).call;
/// B.W `b.w label`, A7.7.12: unconditional with BL's 24-bit offset and no link.
pub const B_T4 = branch.bw;
/// BLX `blx Rm`, A7.7.19: lr = pc+2 with T set, then interworking branch to Rm.
pub const BLX_reg_T1 = branch.blx;
/// CBNZ `cbnz Rn, label`, A7.7.21: forward branch when Rn is nonzero, 6-bit halfword offset.
pub const CBNZ_T1 = branch.cbnz;
/// TBB `tbb [Rn, Rm]`, A7.7.185: reads a byte at Rn+Rm, branches forward by twice it.
pub const TBB_T1 = branch.Table(false).call;
/// TBH `tbh [Rn, Rm, lsl #1]`, A7.7.185: reads a halfword at Rn+Rm*2, branches forward by twice it.
pub const TBH_T1 = branch.Table(true).call;
/// ADCS `adcs Rd, Rm`, A2.2.1: Rd = Rd + C Rm, flags set outside an IT block.
pub const ADC_reg_T1 = alu.Accum(.adc).call;
/// SBCS `sbcs Rd, Rm`, A2.2.1: Rd = Rd - borrow Rm, flags set outside an IT block.
pub const SBC_reg_T1 = alu.Accum(.sbc).call;
/// ANDS `ands Rd, Rm`, A7.7.9ff: Rd = Rd AND Rm, N and Z set, C untouched, outside IT.
pub const AND_reg_T1 = alu.Logic(.@"and").call;
/// EORS `eors Rd, Rm`, A7.7.9ff: Rd = Rd XOR Rm, N and Z set, C untouched, outside IT.
pub const EOR_reg_T1 = alu.Logic(.eor).call;
/// ORRS `orrs Rd, Rm`, A7.7.9ff: Rd = Rd OR Rm, N and Z set, C untouched, outside IT.
pub const ORR_reg_T1 = alu.Logic(.orr).call;
/// BICS `bics Rd, Rm`, A7.7.9ff: Rd = Rd AND NOT Rm, N and Z set, C untouched, outside IT.
pub const BIC_reg_T1 = alu.Logic(.bic).call;
/// MVNS `mvns Rd, Rm`, A7.7.9ff: Rd = Rd NOT Rm, N and Z set, C untouched, outside IT.
pub const MVN_reg_T1 = alu.Logic(.mvn).call;
/// TST `tst Rn, Rm`, A7.7.188: N and Z from Rn AND Rm, nothing written.
pub const TST_reg_T1 = alu.tst;
/// RSBS `rsbs Rd, Rn, #0`, A7.7.119: Rd = 0 - Rn, flags set outside an IT block.
pub const RSB_imm_T1 = alu.rsbs;
/// CMP `cmp Rn, Rm`, A7.7.28: four-bit fields, either may be r15; flags only.
pub const CMP_reg_T2 = alu.cmpHigh;
/// MULS `muls Rd, Rn, Rd`: Rd = low word of Rn * Rd, N and Z set outside IT.
pub const MUL_T1 = alu.muls;
/// ADDS `adds Rd, Rn, Rm`, A2.2.1: Rd = Rn + Rm, flags set outside an IT block.
pub const ADD_reg_T1 = alu.Three(.add).call;
/// SUBS `subs Rd, Rn, Rm`, A2.2.1: Rd = Rn - Rm, flags set outside an IT block.
pub const SUB_reg_T1 = alu.Three(.sub).call;
/// LSRS `lsrs Rd, Rm, #imm`: logical right shift, encoded 0 means 32; C is the last bit out.
pub const LSR_imm_T1 = alu.ShiftImm(.lsr).call;
/// ASRS `asrs Rd, Rm, #imm`: arithmetic right shift, encoded 0 means 32; C is the last bit out.
pub const ASR_imm_T1 = alu.ShiftImm(.asr).call;
/// LSLS `lsls Rd, Rm`, A7.7.68: logical left shift of Rd by Rm's low byte, flags outside IT.
pub const LSL_reg_T1 = alu.ShiftReg(.lsl).call;
/// LSRS `lsrs Rd, Rm`, A7.7.68: logical right shift of Rd by Rm's low byte, flags outside IT.
pub const LSR_reg_T1 = alu.ShiftReg(.lsr).call;
/// ASRS `asrs Rd, Rm`, A7.7.68: arithmetic right shift of Rd by Rm's low byte, flags outside IT.
pub const ASR_reg_T1 = alu.ShiftReg(.asr).call;
/// ADD `add Rd, sp, #imm*4`, A7.7.5: Rd = sp + imm8*4, no flags.
pub const ADD_sp_imm_T1 = alu.addSpImm8;
/// ADD `add sp, #imm*4`, A7.7.5: sp += imm7*4, no flags.
pub const ADD_sp_imm_T2 = alu.SpAdjust(false).call;
/// SUB `sub sp, #imm*4`, A7.7.5: sp -= imm7*4, no flags.
pub const SUB_sp_imm_T1 = alu.SpAdjust(true).call;
/// SXTH `sxth Rd, Rm`: Rd = Rm's low 16-bit sign-extended.
pub const SXTH_T1 = alu.Extend(16, true).call;
/// UXTH `uxth Rd, Rm`: Rd = Rm's low 16-bit zero-extended.
pub const UXTH_T1 = alu.Extend(16, false).call;
/// UXTB `uxtb Rd, Rm`: Rd = Rm's low 8-bit zero-extended.
pub const UXTB_T1 = alu.Extend(8, false).call;
/// REV `rev Rd, Rm`, A7.7.113ff: reverses the four bytes of Rm into Rd.
pub const REV_T1 = alu.Shuffle(.rev).call;
/// CLZ `clz Rd, Rm`: Rd = count of leading zero bits in Rm, 32 for zero.
pub const CLZ_T1 = alu.clz;
/// ADC `adc{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn + C const, S sets flags.
pub const ADC_imm_T1 = alu.Imm(.adc).call;
/// ADD `add{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn + const, S sets flags; Rd=15 is CMN.
pub const ADD_imm_T3 = alu.Imm(.add).call;
/// AND `and{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn AND const, S sets flags; Rd=15 is TST.
pub const AND_imm_T1 = alu.Imm(.@"and").call;
/// BIC `bic{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn AND NOT const, S sets flags.
pub const BIC_imm_T1 = alu.Imm(.bic).call;
/// EOR `eor{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn XOR const, S sets flags; Rd=15 is TEQ.
pub const EOR_imm_T1 = alu.Imm(.eor).call;
/// ORN `orn{s} Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn OR NOT const, S sets flags; Rn=15 is MVN.
pub const ORN_imm_T1 = alu.Imm(.orn).call;
/// RSB `rsb{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn reverse - const, S sets flags.
pub const RSB_imm_T2 = alu.Imm(.rsb).call;
/// SBC `sbc{s}.w Rd, Rn, #const`, A6.3.2 expanded constant: Rd = Rn - borrow const, S sets flags.
pub const SBC_imm_T1 = alu.Imm(.sbc).call;
/// ADC `adc{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn + C shifted Rm, S sets flags, Rd=15 discards.
pub const ADC_reg_T2 = alu.Reg(.adc).call;
/// AND `and{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn AND shifted Rm, S sets flags, Rd=15 discards.
pub const AND_reg_T2 = alu.Reg(.@"and").call;
/// BIC `bic{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn AND NOT shifted Rm, S sets flags, Rd=15 discards.
pub const BIC_reg_T2 = alu.Reg(.bic).call;
/// EOR `eor{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn XOR shifted Rm, S sets flags, Rd=15 discards.
pub const EOR_reg_T2 = alu.Reg(.eor).call;
/// ORN `orn{s} Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn OR NOT shifted Rm, S sets flags, Rd=15 discards.
pub const ORN_reg_T1 = alu.Reg(.orn).call;
/// SBC `sbc{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn - borrow shifted Rm, S sets flags, Rd=15 discards.
pub const SBC_reg_T2 = alu.Reg(.sbc).call;
/// SUB `sub{s}.w Rd, Rn, Rm{, shift}`, A6.3.11: Rd = Rn - shifted Rm, S sets flags, Rd=15 discards.
pub const SUB_reg_T2 = alu.Reg(.sub).call;
/// ORR.W `orr.w Rd, Rn, Rm{, shift}`, A6.7.61: Rd = Rn OR shifted Rm, no flags; Rn=15 is MOV.
pub const ORR_reg_T2_s0 = alu.OrrReg(false, 1, 0).call;
/// ORRS.W `orrs.w Rd, Rn, Rm{, shift}`, A6.7.61: Rd = Rn OR shifted Rm, flags set; Rn=15 is MOV.
pub const ORR_reg_T2_s1 = alu.OrrReg(true, 1, 0).call;
/// ORRS.W `orrs.w Rd, Rn, Rm{, shift}`, A6.7.61: Rd = Rn OR shifted Rm, flags set, Rm r8-r11.
pub const ORR_reg_T2_s1_r8 = alu.OrrReg(true, 1, 8).call;
/// ORRS.W `orrs.w Rd, Rn, Rm{, shift}`, A6.7.61: Rd = Rn OR shifted Rm, flags set, Rm r12/r14.
pub const ORR_reg_T2_s1_r12 = alu.OrrReg(true, 2, 12).call;
/// ADDW `addw Rd, Rn, #imm`, A7.7.3: plain 12-bit immediate, no shifter, no flags.
pub const ADDW_imm_T4 = alu.Wide12(false).call;
/// SUBW `subw Rd, Rn, #imm`, A7.7.174: plain 12-bit immediate, no shifter, no flags.
pub const SUBW_imm_T4 = alu.Wide12(true).call;
/// ASR `asr{s}.w Rd, Rn, Rm`, A7.7.68: Rd = Rn arithmetic right by Rm's low byte, S sets flags.
pub const ASR_reg_T2 = alu.ShiftWide(.asr).call;
/// LSL `lsl{s}.w Rd, Rn, Rm`, A7.7.68: Rd = Rn logical left by Rm's low byte, S sets flags.
pub const LSL_reg_T2 = alu.ShiftWide(.lsl).call;
/// LSR `lsr{s}.w Rd, Rn, Rm`, A7.7.68: Rd = Rn logical right by Rm's low byte, S sets flags.
pub const LSR_reg_T2 = alu.ShiftWide(.lsr).call;
/// SXTH.W `sxth.w Rd, Rm{, shift}`, A7.7.171: rotates Rm, then sign-extends the low 16-bit.
pub const SXTH_T2 = alu.ExtendWide(16, true).call;
/// UXTH.W `uxth.w Rd, Rm{, shift}`, A7.7.171: rotates Rm, then zero-extends the low 16-bit.
pub const UXTH_T2 = alu.ExtendWide(16, false).call;
/// SXTB.W `sxtb.w Rd, Rm{, shift}`, A7.7.171: rotates Rm, then sign-extends the low 8-bit.
pub const SXTB_T2 = alu.ExtendWide(8, true).call;
/// UXTB.W `uxtb.w Rd, Rm{, shift}`, A7.7.171: rotates Rm, then zero-extends the low 8-bit.
pub const UXTB_T2 = alu.ExtendWide(8, false).call;

/// STRB `strb Rt, [Rn, #imm]`, A6.7.42ff: byte store, offset scaled by the width, low registers only.
pub const STRB_imm_T1 = mem.NarrowImm(8, false, false).call;
/// LDRB `ldrb Rt, [Rn, #imm]`, A6.7.42ff: byte load, offset scaled by the width, low registers only.
pub const LDRB_imm_T1 = mem.NarrowImm(8, false, true).call;
/// STRH `strh Rt, [Rn, #imm*2]`, A6.7.42ff: halfword store, offset scaled by the width, low registers only.
pub const STRH_imm_T1 = mem.NarrowImm(16, false, false).call;
/// LDRH `ldrh Rt, [Rn, #imm*2]`, A6.7.42ff: halfword load, offset scaled by the width, low registers only.
pub const LDRH_imm_T1 = mem.NarrowImm(16, false, true).call;
/// STR `str Rt, [Rn, Rm]`: word store at Rn+Rm, low registers only.
pub const STR_reg_T1 = mem.NarrowReg(32, false, false).call;
/// STRH `strh Rt, [Rn, Rm]`: halfword store at Rn+Rm, low registers only.
pub const STRH_reg_T1 = mem.NarrowReg(16, false, false).call;
/// STRB `strb Rt, [Rn, Rm]`: byte store at Rn+Rm, low registers only.
pub const STRB_reg_T1 = mem.NarrowReg(8, false, false).call;
/// LDRSB `ldrsb Rt, [Rn, Rm]`: byte load sign-extended at Rn+Rm, low registers only.
pub const LDRSB_reg_T1 = mem.NarrowReg(8, true, true).call;
/// LDR `ldr Rt, [Rn, Rm]`: word load at Rn+Rm, low registers only.
pub const LDR_reg_T1 = mem.NarrowReg(32, false, true).call;
/// LDRB `ldrb Rt, [Rn, Rm]`: byte load at Rn+Rm, low registers only.
pub const LDRB_reg_T1 = mem.NarrowReg(8, false, true).call;
/// LDRSH `ldrsh Rt, [Rn, Rm]`: halfword load sign-extended at Rn+Rm, low registers only.
pub const LDRSH_reg_T1 = mem.NarrowReg(16, true, true).call;
/// LDR.W `ldr.w Rt, [Rn, #imm]`: word load, 12-bit offset; Rt=15 branches or preloads.
pub const LDR_imm_T3 = mem.WideLoad(32, false, 0, false).call;
/// LDRB.W `ldrb.w Rt, [Rn, #imm]`: byte load, 12-bit offset; Rt=15 branches or preloads.
pub const LDRB_imm_T2 = mem.WideLoad(8, false, 0, false).call;
/// LDRH.W `ldrh.w Rt, [Rn, #imm]`: halfword load, 12-bit offset; Rt=15 branches or preloads.
pub const LDRH_imm_T2 = mem.WideLoad(16, false, 0, false).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #imm]`: byte load sign-extended, 12-bit offset; Rt=15 branches or preloads.
pub const LDRSB_imm_T1 = mem.WideLoad(8, true, 0, false).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #imm]`: halfword load sign-extended, 12-bit offset; Rt=15 branches or preloads.
pub const LDRSH_imm_T1 = mem.WideLoad(16, true, 0, false).call;
/// STR.W `str.w Rt, [Rn, #imm]`, A7.7.161: word store, 12-bit offset; a base of r15 is UNDEFINED.
pub const STR_imm_T3 = mem.WideStore(32, false).call;
/// STRB.W `strb.w Rt, [Rn, #imm]`, A7.7.161: byte store, 12-bit offset; a base of r15 is UNDEFINED.
pub const STRB_imm_T2 = mem.WideStore(8, false).call;
/// STRH.W `strh.w Rt, [Rn, #imm]`, A7.7.161: halfword store, 12-bit offset; a base of r15 is UNDEFINED.
pub const STRH_imm_T2 = mem.WideStore(16, false).call;
/// LDR.W `ldr.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed word load, U adds, writeback.
pub const LDR_imm_T4_wb = mem.Indexed(32, false, true, 0).call;
/// LDR.W `ldr.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed word load, U adds, writeback, Rn r8-r11.
pub const LDR_imm_T4_wb_r8 = mem.Indexed(32, false, true, 8).call;
/// LDRB.W `ldrb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load, U adds, writeback.
pub const LDRB_imm_T3_wb = mem.Indexed(8, false, true, 0).call;
/// LDRB.W `ldrb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load, U adds, writeback, Rn r8-r11.
pub const LDRB_imm_T3_wb_r8 = mem.Indexed(8, false, true, 8).call;
/// LDRB.W `ldrb.w Rt, [lr, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load, U adds, writeback, Rn=lr.
pub const LDRB_imm_T3_wb_lr = mem.IndexedAt(8, false, true, 14).call;
/// STR.W `str.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed word store, U adds, writeback.
pub const STR_imm_T4_wb = mem.Indexed(32, false, false, 0).call;
/// STRB.W `strb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte store, U adds, writeback.
pub const STRB_imm_T3_wb = mem.Indexed(8, false, false, 0).call;
/// LDR.W `ldr.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, word load at Rn minus imm, no writeback.
pub const LDR_imm_T4_neg = mem.Negative(32, false, true, 0).call;
/// LDRB.W `ldrb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, byte load at Rn minus imm, no writeback.
pub const LDRB_imm_T3_neg = mem.Negative(8, false, true, 0).call;
/// STRB.W `strb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, byte store at Rn minus imm, no writeback.
pub const STRB_imm_T3_neg = mem.Negative(8, false, false, 0).call;
/// LDR.W `ldr.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: word load at Rn + Rm lsl 0-3.
pub const LDR_reg_T2 = mem.OffsetReg(32, false, true, 0).call;
/// LDR.W `ldr.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: word load at Rn + Rm lsl 0-3, Rn r8-r11.
pub const LDR_reg_T2_r8 = mem.OffsetReg(32, false, true, 8).call;
/// LDR.W `ldr.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: word load at Rn + Rm lsl 0-3, Rn r12-r13.
pub const LDR_reg_T2_r12 = mem.OffsetReg(32, false, true, 12).call;
/// LDR.W `ldr.w Rt, [lr, Rm{, lsl #n}]`, A7.7.43: word load at Rn + Rm lsl 0-3, Rn=lr.
pub const LDR_reg_T2_lr = mem.OffsetRegAt(32, false, true, 14).call;
/// LDRB.W `ldrb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: byte load at Rn + Rm lsl 0-3.
pub const LDRB_reg_T2 = mem.OffsetReg(8, false, true, 0).call;
/// LDRB.W `ldrb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: byte load at Rn + Rm lsl 0-3, Rn r8-r11.
pub const LDRB_reg_T2_r8 = mem.OffsetReg(8, false, true, 8).call;
/// LDRB.W `ldrb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: byte load at Rn + Rm lsl 0-3, Rn r12-r13.
pub const LDRB_reg_T2_r12 = mem.OffsetReg(8, false, true, 12).call;
/// LDRB.W `ldrb.w Rt, [lr, Rm{, lsl #n}]`, A7.7.43: byte load at Rn + Rm lsl 0-3, Rn=lr.
pub const LDRB_reg_T2_lr = mem.OffsetRegAt(8, false, true, 14).call;
/// LDRH.W `ldrh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: halfword load at Rn + Rm lsl 0-3.
pub const LDRH_reg_T2 = mem.OffsetReg(16, false, true, 0).call;
/// LDRH.W `ldrh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: halfword load at Rn + Rm lsl 0-3, Rn r8-r11.
pub const LDRH_reg_T2_r8 = mem.OffsetReg(16, false, true, 8).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended byte load at Rn + Rm lsl 0-3.
pub const LDRSB_reg_T2 = mem.OffsetReg(8, true, true, 0).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended halfword load at Rn + Rm lsl 0-3.
pub const LDRSH_reg_T2 = mem.OffsetReg(16, true, true, 0).call;
/// STR.W `str.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: word store at Rn + Rm lsl 0-3.
pub const STR_reg_T2 = mem.OffsetReg(32, false, false, 0).call;
/// STRB.W `strb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: byte store at Rn + Rm lsl 0-3.
pub const STRB_reg_T2 = mem.OffsetReg(8, false, false, 0).call;
/// STRH.W `strh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: halfword store at Rn + Rm lsl 0-3.
pub const STRH_reg_T2 = mem.OffsetReg(16, false, false, 0).call;
/// STRH.W `strh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword store, U adds, writeback.
pub const STRH_imm_T3_wb = mem.Indexed(16, false, false, 0).call;

/// STM `stm Rn!, {list}`, A7.7.156: stores the list upward from Rn, strictly aligned, writeback.
pub const STM_T1 = mem.stm;
/// LDM `ldm Rn{!}, {list}`, A7.7.40: loads the list upward from Rn; writeback unless Rn is listed.
pub const LDM_T1 = mem.ldm;
/// POP `pop {list}` with pc, A7.7.99: last word branches, sp bits 1:0 cleared, no landing pad.
pub const POP_T1_pc = mem.popPc;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list, B1.5.10 all-or-nothing, writeback per W, Rn r12-r13.
pub const LDM_T2_r12 = mem.Block(true, false, 12).call;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list including pc, B1.5.10 all-or-nothing, writeback per W, Rn r12-r13.
pub const LDM_T2_pc_r12 = mem.Block(true, true, 12).call;
/// STM.W `stm.w Rn{!}, {list}`, A7.7.41: stores the list upward from Rn, writeback per W.
pub const STM_T2 = mem.Block(false, false, 0).call;
/// LDRD `ldrd Rt, Rt2, [Rn, #imm*4]{!}`, A7.7.49: two words at Rn plus imm8*4, strictly aligned, writeback per W.
pub const LDRD_imm_T1_pos = mem.DoubleUp(true).call;
/// STRD `strd Rt, Rt2, [Rn, #±imm*4]{!}`, A7.7.166: two words at Rn plus or minus imm8*4, writeback per W.
pub const STRD_imm_T1_pre = mem.DoubleSigned(false).call;

/// MLA `mla Rd, Rn, Rm, Ra`, A7.7.74: Rd = low word of Rn*Rm + Ra; Ra=15 reads as zero (MUL).
pub const MLA_T1 = alu.Multiply(false).call;
/// MLS `mls Rd, Rn, Rm, Ra`, A7.7.75: Rd = low word of Ra - Rn*Rm; Ra=15 reads as zero (MUL).
pub const MLS_T1 = alu.Multiply(true).call;
/// SMULL `smull RdLo, RdHi, Rn, Rm`, A7.7.149ff: writes RdHi:RdLo with the signed 64-bit product Rn*Rm.
pub const SMULL_T1 = alu.Long(true, false).call;
/// UMULL `umull RdLo, RdHi, Rn, Rm`, A7.7.149ff: writes RdHi:RdLo with the unsigned 64-bit product Rn*Rm.
pub const UMULL_T1 = alu.Long(false, false).call;
/// SMLAL `smlal RdLo, RdHi, Rn, Rm`, A7.7.149ff: adds the 64-bit RdHi:RdLo the signed 64-bit product Rn*Rm.
pub const SMLAL_T1 = alu.Long(true, true).call;
/// UMLAL `umlal RdLo, RdHi, Rn, Rm`, A7.7.149ff: adds the 64-bit RdHi:RdLo the unsigned 64-bit product Rn*Rm.
pub const UMLAL_T1 = alu.Long(false, true).call;
/// BFI `bfi Rd, Rn, #imm, #width`, A7.7.14: inserts Rn's low bits at lsb for width; Rn=15 is BFC.
pub const BFI_T1 = alu.bfi;
/// UBFX `ubfx Rd, Rn, #imm, #width`, A7.7.191: extracts width bits from lsb, zero-extended into Rd.
pub const UBFX_T1 = alu.Bfx(false).call;
/// SSAT `ssat Rd, #width, Rn{, lsl #n}`, A7.7.128: logical shift then signed clamp to sat bits, Q on clamp.
pub const SSAT_T1_lsl = alu.Sat(true, false).call;
/// SDIV `sdiv Rd, Rn, Rm`, A7.7.126: signed Rn / Rm; zero divisor gives 0 or traps per CCR.DIV_0_TRP.
pub const SDIV_T1 = alu.Div(true).call;
/// UDIV `udiv Rd, Rn, Rm`, A7.7.195: unsigned Rn / Rm; zero divisor gives 0 or traps per CCR.DIV_0_TRP.
pub const UDIV_T1 = alu.Div(false).call;
/// BKPT `bkpt #imm`: answers .breakpoint so the host can stop.
pub const BKPT_T1 = alu.bkpt;
/// MRS `mrs Rd, spec_reg`, A7.7.83: reads a special register; unknown or unprivileged names read zero.
pub const MRS_T1 = system.mrs;
/// MSR `msr spec_reg, Rn`, A7.7.84: writes a special register; mask picks APSR halves, privilege gates the rest.
pub const MSR_T1 = system.msr;

/// IT `itxyz cond`, A7.7.38: opens an IT block, mask 1xxx with its x bits from the operand.
pub const IT_T1_m1 = branch.It(0b1000).call;
/// IT `itxyz cond`, A7.7.38: opens an IT block, mask 01xx with its x bits from the operand.
pub const IT_T1_m01 = branch.It(0b0100).call;

/// LDR.W `ldr.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed word load, U adds, writeback, Rn r12-r13.
pub const LDR_imm_T4_wb_r12 = mem.Indexed(32, false, true, 12).call;
/// LDR.W `ldr.w Rt, [lr, #±imm]{!}`, A7.7.42: pre- or post-indexed word load, U adds, writeback, Rn=lr.
pub const LDR_imm_T4_wb_lr = mem.IndexedAt(32, false, true, 14).call;
/// LDR.W `ldr.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, word load at Rn minus imm, no writeback, Rn r8-r11.
pub const LDR_imm_T4_neg_r8 = mem.Negative(32, false, true, 8).call;
/// LDR.W `ldr.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, word load at Rn minus imm, no writeback, Rn r12-r13.
pub const LDR_imm_T4_neg_r12 = mem.Negative(32, false, true, 12).call;
/// LDR.W `ldr.w Rt, [lr, #-imm]`: P=1 U=0 W=0, word load at Rn minus imm, no writeback, Rn=lr.
pub const LDR_imm_T4_neg_lr = mem.NegativeAt(32, false, true, 14).call;
/// LDRB.W `ldrb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load, U adds, writeback, Rn r12-r13.
pub const LDRB_imm_T3_wb_r12 = mem.Indexed(8, false, true, 12).call;
/// LDRB.W `ldrb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, byte load at Rn minus imm, no writeback, Rn r8-r11.
pub const LDRB_imm_T3_neg_r8 = mem.Negative(8, false, true, 8).call;
/// LDRB.W `ldrb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, byte load at Rn minus imm, no writeback, Rn r12-r13.
pub const LDRB_imm_T3_neg_r12 = mem.Negative(8, false, true, 12).call;
/// LDRB.W `ldrb.w Rt, [lr, #-imm]`: P=1 U=0 W=0, byte load at Rn minus imm, no writeback, Rn=lr.
pub const LDRB_imm_T3_neg_lr = mem.NegativeAt(8, false, true, 14).call;
/// LDRH.W `ldrh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: halfword load at Rn + Rm lsl 0-3, Rn r12-r13.
pub const LDRH_reg_T2_r12 = mem.OffsetReg(16, false, true, 12).call;
/// LDRH.W `ldrh.w Rt, [lr, Rm{, lsl #n}]`, A7.7.43: halfword load at Rn + Rm lsl 0-3, Rn=lr.
pub const LDRH_reg_T2_lr = mem.OffsetRegAt(16, false, true, 14).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended byte load at Rn + Rm lsl 0-3, Rn r8-r11.
pub const LDRSB_reg_T2_r8 = mem.OffsetReg(8, true, true, 8).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended byte load at Rn + Rm lsl 0-3, Rn r12-r13.
pub const LDRSB_reg_T2_r12 = mem.OffsetReg(8, true, true, 12).call;
/// LDRSB.W `ldrsb.w Rt, [lr, Rm{, lsl #n}]`, A7.7.43: sign-extended byte load at Rn + Rm lsl 0-3, Rn=lr.
pub const LDRSB_reg_T2_lr = mem.OffsetRegAt(8, true, true, 14).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended halfword load at Rn + Rm lsl 0-3, Rn r8-r11.
pub const LDRSH_reg_T2_r8 = mem.OffsetReg(16, true, true, 8).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, Rm{, lsl #n}]`, A7.7.43: sign-extended halfword load at Rn + Rm lsl 0-3, Rn r12-r13.
pub const LDRSH_reg_T2_r12 = mem.OffsetReg(16, true, true, 12).call;
/// LDRSH.W `ldrsh.w Rt, [lr, Rm{, lsl #n}]`, A7.7.43: sign-extended halfword load at Rn + Rm lsl 0-3, Rn=lr.
pub const LDRSH_reg_T2_lr = mem.OffsetRegAt(16, true, true, 14).call;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list, B1.5.10 all-or-nothing, writeback per W.
pub const LDM_T2 = mem.Block(true, false, 0).call;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list, B1.5.10 all-or-nothing, writeback per W, Rn r8-r11.
pub const LDM_T2_r8 = mem.Block(true, false, 8).call;
/// LDM.W `ldm.w lr{!}, {list}`, A7.7.41: loads the list, B1.5.10 all-or-nothing, writeback per W, Rn=lr.
pub const LDM_T2_lr = mem.BlockAt(true, false, 14).call;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list including pc, B1.5.10 all-or-nothing, writeback per W.
pub const LDM_T2_pc = mem.Block(true, true, 0).call;
/// LDM.W `ldm.w Rn{!}, {list}`, A7.7.41: loads the list including pc, B1.5.10 all-or-nothing, writeback per W, Rn r8-r11.
pub const LDM_T2_pc_r8 = mem.Block(true, true, 8).call;
/// LDM.W `ldm.w lr{!}, {list}`, A7.7.41: loads the list including pc, B1.5.10 all-or-nothing, writeback per W, Rn=lr.
pub const LDM_T2_pc_lr = mem.BlockAt(true, true, 14).call;
/// LDRH.W `ldrh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load, U adds, writeback.
pub const LDRH_imm_T3_wb = mem.Indexed(16, false, true, 0).call;
/// LDRH.W `ldrh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load, U adds, writeback, Rn r8-r11.
pub const LDRH_imm_T3_wb_r8 = mem.Indexed(16, false, true, 8).call;
/// LDRH.W `ldrh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load, U adds, writeback, Rn r12-r13.
pub const LDRH_imm_T3_wb_r12 = mem.Indexed(16, false, true, 12).call;
/// LDRH.W `ldrh.w Rt, [lr, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load, U adds, writeback, Rn=lr.
pub const LDRH_imm_T3_wb_lr = mem.IndexedAt(16, false, true, 14).call;
/// LDRH.W `ldrh.w Rt, [pc, #-imm]`, A7.7.44: halfword load at a 12-bit offset below the word-aligned pc.
pub const LDRH_lit_T1 = mem.Literal(16, false).call;
/// LDRH.W `ldrh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, halfword load at Rn minus imm, no writeback.
pub const LDRH_imm_T3_neg = mem.Negative(16, false, true, 0).call;
/// LDRH.W `ldrh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, halfword load at Rn minus imm, no writeback, Rn r8-r11.
pub const LDRH_imm_T3_neg_r8 = mem.Negative(16, false, true, 8).call;
/// LDRH.W `ldrh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, halfword load at Rn minus imm, no writeback, Rn r12-r13.
pub const LDRH_imm_T3_neg_r12 = mem.Negative(16, false, true, 12).call;
/// LDRH.W `ldrh.w Rt, [lr, #-imm]`: P=1 U=0 W=0, halfword load at Rn minus imm, no writeback, Rn=lr.
pub const LDRH_imm_T3_neg_lr = mem.NegativeAt(16, false, true, 14).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load sign-extended, U adds, writeback.
pub const LDRSB_imm_T2_wb = mem.Indexed(8, true, true, 0).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load sign-extended, U adds, writeback, Rn r8-r11.
pub const LDRSB_imm_T2_wb_r8 = mem.Indexed(8, true, true, 8).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load sign-extended, U adds, writeback, Rn r12-r13.
pub const LDRSB_imm_T2_wb_r12 = mem.Indexed(8, true, true, 12).call;
/// LDRSB.W `ldrsb.w Rt, [lr, #±imm]{!}`, A7.7.42: pre- or post-indexed byte load sign-extended, U adds, writeback, Rn=lr.
pub const LDRSB_imm_T2_wb_lr = mem.IndexedAt(8, true, true, 14).call;
/// LDRSB.W `ldrsb.w Rt, [pc, #-imm]`, A7.7.44: byte load sign-extended at a 12-bit offset below the word-aligned pc.
pub const LDRSB_lit_T1 = mem.Literal(8, true).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended byte load at Rn minus imm, no writeback.
pub const LDRSB_imm_T2_neg = mem.Negative(8, true, true, 0).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended byte load at Rn minus imm, no writeback, Rn r8-r11.
pub const LDRSB_imm_T2_neg_r8 = mem.Negative(8, true, true, 8).call;
/// LDRSB.W `ldrsb.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended byte load at Rn minus imm, no writeback, Rn r12-r13.
pub const LDRSB_imm_T2_neg_r12 = mem.Negative(8, true, true, 12).call;
/// LDRSB.W `ldrsb.w Rt, [lr, #-imm]`: P=1 U=0 W=0, sign-extended byte load at Rn minus imm, no writeback, Rn=lr.
pub const LDRSB_imm_T2_neg_lr = mem.NegativeAt(8, true, true, 14).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load sign-extended, U adds, writeback.
pub const LDRSH_imm_T2_wb = mem.Indexed(16, true, true, 0).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load sign-extended, U adds, writeback, Rn r8-r11.
pub const LDRSH_imm_T2_wb_r8 = mem.Indexed(16, true, true, 8).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load sign-extended, U adds, writeback, Rn r12-r13.
pub const LDRSH_imm_T2_wb_r12 = mem.Indexed(16, true, true, 12).call;
/// LDRSH.W `ldrsh.w Rt, [lr, #±imm]{!}`, A7.7.42: pre- or post-indexed halfword load sign-extended, U adds, writeback, Rn=lr.
pub const LDRSH_imm_T2_wb_lr = mem.IndexedAt(16, true, true, 14).call;
/// LDRSH.W `ldrsh.w Rt, [pc, #-imm]`, A7.7.44: halfword load sign-extended at a 12-bit offset below the word-aligned pc.
pub const LDRSH_lit_T1 = mem.Literal(16, true).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended halfword load at Rn minus imm, no writeback.
pub const LDRSH_imm_T2_neg = mem.Negative(16, true, true, 0).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended halfword load at Rn minus imm, no writeback, Rn r8-r11.
pub const LDRSH_imm_T2_neg_r8 = mem.Negative(16, true, true, 8).call;
/// LDRSH.W `ldrsh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, sign-extended halfword load at Rn minus imm, no writeback, Rn r12-r13.
pub const LDRSH_imm_T2_neg_r12 = mem.Negative(16, true, true, 12).call;
/// LDRSH.W `ldrsh.w Rt, [lr, #-imm]`: P=1 U=0 W=0, sign-extended halfword load at Rn minus imm, no writeback, Rn=lr.
pub const LDRSH_imm_T2_neg_lr = mem.NegativeAt(16, true, true, 14).call;
/// LDRB.W `ldrb.w Rt, [pc, #-imm]`, A7.7.44: byte load at a 12-bit offset below the word-aligned pc.
pub const LDRB_lit_T1 = mem.Literal(8, false).call;
/// LDR.W `ldr.w Rt, [pc, #-imm]`, A7.7.44: word load at a 12-bit offset below the word-aligned pc.
pub const LDR_lit_T2 = mem.Literal(32, false).call;

/// LDRH `ldrh Rt, [Rn, Rm]`: halfword load at Rn+Rm, low registers only.
pub const LDRH_reg_T1 = mem.NarrowReg(16, false, true).call;
/// POP `pop {list}`, A7.7.99: loads the list from the stack upward, sp lands above it.
pub const POP_T1 = mem.pop;
/// RORS `rors Rd, Rm`, A7.7.68: rotate right shift of Rd by Rm's low byte, flags outside IT.
pub const ROR_reg_T1 = alu.ShiftReg(.ror).call;
/// CMN `cmn Rn, Rm`, A7.7.26: flags from Rn + Rm, nothing written.
pub const CMN_reg_T1 = alu.cmnReg;
/// ADR `adr Rd, #imm*4`, A7.7.7: Rd = word-aligned pc plus imm8*4, addressing the literal pool.
pub const ADR_T1 = alu.adr;
/// SXTB `sxtb Rd, Rm`: Rd = Rm's low 8-bit sign-extended.
pub const SXTB_T1 = alu.Extend(8, true).call;
/// REV16 `rev16 Rd, Rm`, A7.7.113ff: reverses bytes within each halfword of Rm into Rd.
pub const REV16_T1 = alu.Shuffle(.rev16).call;
/// REVSH `revsh Rd, Rm`, A7.7.113ff: reverses the low two bytes then sign-extends of Rm into Rd.
pub const REVSH_T1 = alu.Shuffle(.revsh).call;
/// YIELD `yield`: a scheduling hint, nothing to yield to here.
pub const YIELD_T1 = nop;
/// WFE `wfe`, A7.7.74: halts until an event or pending exception, B1.5.18; host waits.
pub const WFE_T1 = system.wfe;
/// WFI `wfi`, A7.7.75: halts until an exception the controller would deliver, B1.5.19.
pub const WFI_T1 = system.wfi;
/// SEV `sev`, A7.7.129: sets the event register so the next WFE retires, B1.5.18.
pub const SEV_T1 = system.sev;
/// Unallocated hint 1011111101010000: executes as NOP.
pub const UNALLOCATED_hint_T1_5 = nop;
/// Unallocated hint 10111111011a0000: its option field ignored, executes as NOP.
pub const UNALLOCATED_hint_T1_6 = barrier;
/// Unallocated hint 101111111aaa0000: its option field ignored, executes as NOP.
pub const UNALLOCATED_hint_T1_8 = barrier;
/// BVS `bvs label`, A7.7.12: taken when V set, 8-bit halfword offset, A7.3.
pub const BVS_T1 = branch.Narrow(.vs).call;
/// BVC `bvc label`, A7.7.12: taken when V clear, 8-bit halfword offset, A7.3.
pub const BVC_T1 = branch.Narrow(.vc).call;
/// SVC `svc #imm`, A7.7.175: reports the supervisor call for the host to take.
pub const SVC_T1 = system.svc;
/// IT `itxyz cond`, A7.7.38: opens an IT block, mask 001x with its x bits from the operand.
pub const IT_T1_m001 = branch.It(0b0010).call;
/// IT `itxyz cond`, A7.7.38: opens an IT block with the mask 0001 fixed by the encoding.
pub const IT_T1_m0001 = branch.ItAlone(0b0001).call;

/// DSB `dsb`, A7.7.32: nothing to order on a one-access-at-a-time core.
pub const DSB_T1 = barrier;
/// DMB `dmb`, A7.7.32: nothing to order on a one-access-at-a-time core.
pub const DMB_T1 = barrier;
/// ISB `isb`, A7.7.32: nothing to order on a one-access-at-a-time core.
pub const ISB_T1 = barrier;
/// UDF.W `udf.w #imm16`, A7.7.194: permanently undefined, answers .undefined.
pub const UDF_T2 = alu.udf;
/// BPL.W `bpl.w label`, A7.7.12: taken when N clear, 20-bit halfword offset, A7.3.
pub const BPL_T3 = branch.Wide(.pl).call;
/// BVS.W `bvs.w label`, A7.7.12: taken when V set, 20-bit halfword offset, A7.3.
pub const BVS_T3 = branch.Wide(.vs).call;
/// BVC.W `bvc.w label`, A7.7.12: taken when V clear, 20-bit halfword offset, A7.3.
pub const BVC_T3 = branch.Wide(.vc).call;
/// BLS.W `bls.w label`, A7.7.12: taken when C clear or Z set, 20-bit halfword offset, A7.3.
pub const BLS_T3 = branch.Wide(.ls).call;
/// ROR `ror{s}.w Rd, Rn, Rm`, A7.7.68: Rd = Rn rotate right by Rm's low byte, S sets flags.
pub const ROR_reg_T2 = alu.ShiftWide(.ror).call;
/// SBFX `sbfx Rd, Rn, #imm, #width`, A7.7.127: extracts width bits from lsb, sign-extended into Rd.
pub const SBFX_T1 = alu.Bfx(true).call;
/// LDMDB `ldmdb Rn{!}, {list}`, A7.7.42: loads the list from below Rn, writeback leaves Rn at the bottom.
pub const LDMDB_T1 = mem.BlockDown(false).call;
/// LDMDB `ldmdb Rn{!}, {list}` with pc, A7.7.42: loads the list from below Rn, writeback leaves Rn at the bottom.
pub const LDMDB_T1_pc = mem.BlockDown(true).call;
/// STRH.W `strh.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, halfword store at Rn minus imm, no writeback.
pub const STRH_imm_T3_neg = mem.Negative(16, false, false, 0).call;
/// STR.W `str.w Rt, [Rn, #-imm]`: P=1 U=0 W=0, word store at Rn minus imm, no writeback.
pub const STR_imm_T4_neg = mem.Negative(32, false, false, 0).call;
/// Wide hint row, h selects: WFE.W, WFI.W, SEV.W and the PACBTI hints; others do nothing.
pub const HINT_T2 = system.hint;
pub const DBG_T1 = barrier;
pub const RESERVED_hint_T2_10 = barrier;
pub const RESERVED_hint_T2_110 = barrier;
pub const RESERVED_hint_T2_1110 = barrier;
/// REV.W `rev.w Rd, Rm`, A7.7.113ff: reverses the four bytes of Rm into Rd.
pub const REV_T2 = alu.ShuffleWide(.rev).call;
/// REV16.W `rev16.w Rd, Rm`, A7.7.113ff: reverses bytes within each halfword of Rm into Rd.
pub const REV16_T2 = alu.ShuffleWide(.rev16).call;
/// RBIT `rbit Rd, Rm`, A7.7.113ff: reverses all 32 bits of Rm into Rd.
pub const RBIT_T1 = alu.ShuffleWide(.rbit).call;
/// REVSH.W `revsh.w Rd, Rm`, A7.7.113ff: reverses the low two bytes then sign-extends of Rm into Rd.
pub const REVSH_T2 = alu.ShuffleWide(.revsh).call;
/// SSAT `ssat Rd, #width, Rn, asr #imm`, A7.7.128: arithmetic shift then signed clamp, Q on clamp; shift 0 is SSAT16.
pub const SSAT_T1_asr = alu.Sat(true, true).call;
/// USAT `usat Rd, #sat, Rn{, lsl #n}`, A7.7.190: logical shift then unsigned clamp to sat bits, Q on clamp.
pub const USAT_T1_lsl = alu.Sat(false, false).call;
/// USAT `usat Rd, #sat, Rn, asr #imm`, A7.7.190: arithmetic shift then unsigned clamp, Q on clamp; shift 0 is USAT16.
pub const USAT_T1_asr = alu.Sat(false, true).call;

/// LDRD `ldrd Rt, Rt2, [Rn, #-imm*4]`, A7.7.49: two words below Rn, no writeback.
pub const LDRD_imm_T1_neg = mem.DoubleDown(0, false).call;
/// LDRD `ldrd Rt, Rt2, [Rn, #-imm*4]!`, A7.7.49: two words below Rn, writeback fixed on.
pub const LDRD_imm_T1_neg_wb = mem.DoubleDown(0, true).call;
/// LDRD `ldrd Rt, Rt2, [Rn, #-imm*4]!`, A7.7.49: two words below Rn, writeback fixed on, Rn r8-r11.
pub const LDRD_imm_T1_neg_wb_r8 = mem.DoubleDown(8, true).call;
/// LDRD `ldrd Rt, Rt2, [Rn, #-imm*4]!`, A7.7.49: two words below Rn, writeback fixed on, Rn r12-r13.
pub const LDRD_imm_T1_neg_wb_r12 = mem.DoubleDown(12, true).call;
/// LDRD `ldrd Rt, Rt2, [lr, #-imm*4]!`, A7.7.49: two words below lr, writeback fixed on, Rn=lr.
pub const LDRD_imm_T1_neg_wb_lr = mem.DoubleDownAt(14).call;
/// LDRD `ldrd Rt, Rt2, [Rn], #±imm*4`, A7.7.49: loads two words at Rn, then Rn moves by the signed offset.
pub const LDRD_imm_T1_post = mem.DoublePost(true).call;
/// STRD `strd Rt, Rt2, [Rn], #±imm*4`, A7.7.49: stores two words at Rn, then Rn moves by the signed offset.
pub const STRD_imm_T1_post = mem.DoublePost(false).call;

/// LDREX `ldrex Rt, [Rn, #imm*4]`, A7.7.52: strictly aligned word load that tags the monitor with the address.
pub const LDREX_T1 = mem.LoadExclusiveImm(32).call;
/// STREX `strex Rd, Rt, [Rn, #imm*4]`, A7.7.167: word store where monitor matches, Rd = 0 on success.
pub const STREX_T1 = mem.StoreExclusiveImm(32, 0).call;
/// STREX `strex Rd, Rt, [Rn, #imm*4]`, A7.7.167: word store where monitor matches, Rd = 0 on success, Rt r8-r11.
pub const STREX_T1_r8 = mem.StoreExclusiveImm(32, 8).call;
/// STREX `strex Rd, Rt, [Rn, #imm*4]`, A7.7.167: word store where monitor matches, Rd = 0 on success, Rt r12-r13.
pub const STREX_T1_r12 = mem.StoreExclusiveImm(32, 12).call;
/// STREX `strex Rd, lr, [Rn, #imm*4]`, A7.7.167: word store where monitor matches, Rd = 0 on success, Rt=lr.
pub const STREX_T1_lr = mem.StoreExclusiveImmAt(32, 14).call;
/// LDREXB `ldrexb Rt, [Rn]`, A7.7.52: strictly aligned byte load that tags the monitor with Rn.
pub const LDREXB_T1 = mem.LoadExclusivePlain(8).call;
/// LDREXH `ldrexh Rt, [Rn]`, A7.7.52: strictly aligned halfword load that tags the monitor with Rn.
pub const LDREXH_T1 = mem.LoadExclusivePlain(16).call;
/// STREXB `strexb Rd, Rt, [Rn]`, A7.7.167: byte store if the monitor holds Rn, Rd = 0 on success, monitor cleared.
pub const STREXB_T1 = mem.StoreExclusivePlain(8).call;
/// STREXH `strexh Rd, Rt, [Rn]`, A7.7.167: halfword store if the monitor holds Rn, Rd = 0 on success, monitor cleared.
pub const STREXH_T1 = mem.StoreExclusivePlain(16).call;
/// CLREX `clrex`, A7.7.30: returns the exclusive monitor to open access.
pub const CLREX_T1 = mem.clrex;
/// BXNS `bxns Rm`: branch to Rm, leaving Secure state when its low bit is clear.
pub const BXNS_T1 = branch.bxns;
/// BLXNS `blxns Rm`: call into Non-secure code, stacking the Secure return on the way.
pub const BLXNS_T1 = branch.blxns;
/// SG `sg`: secure gateway; entering from Non-secure switches state and clears lr bit 0.
pub const SG_T1 = system.sg;
/// TT: security and MPU attributes of Rn's address, written to Rd.
pub const TT_T1 = system.Tt(false, false).call;
/// TTT: attributes of Rn's address as seen unprivileged, written to Rd.
pub const TTT_T1 = system.Tt(false, true).call;
/// TTA: Non-secure view of Rn's address, Secure only, written to Rd.
pub const TTA_T1 = system.Tt(true, false).call;
/// TTAT: unprivileged Non-secure view of Rn's address, Secure only, written to Rd.
pub const TTAT_T1 = system.Tt(true, true).call;
/// LDA `lda Rt, [Rn]`: load-acquire, a strictly aligned word load on this single-access core.
pub const LDA_T1 = mem.Acquire(32).call;
/// LDAB `ldab Rt, [Rn]`: load-acquire, a strictly aligned byte load on this single-access core.
pub const LDAB_T1 = mem.Acquire(8).call;
/// LDAH `ldah Rt, [Rn]`: load-acquire, a strictly aligned halfword load on this single-access core.
pub const LDAH_T1 = mem.Acquire(16).call;
/// STL `stl Rt, [Rn]`: store-release, a strictly aligned word store on this single-access core.
pub const STL_T1 = mem.Release(32).call;
/// STLB `stlb Rt, [Rn]`: store-release, a strictly aligned byte store on this single-access core.
pub const STLB_T1 = mem.Release(8).call;
/// STLH `stlh Rt, [Rn]`: store-release, a strictly aligned halfword store on this single-access core.
pub const STLH_T1 = mem.Release(16).call;
/// LDAEX `ldaex Rt, [Rn]`, A7.7.52: strictly aligned word load that tags the monitor with Rn.
pub const LDAEX_T1 = mem.LoadExclusivePlain(32).call;
/// LDAEXB `ldaexb Rt, [Rn]`, A7.7.52: strictly aligned byte load that tags the monitor with Rn.
pub const LDAEXB_T1 = mem.LoadExclusivePlain(8).call;
/// LDAEXH `ldaexh Rt, [Rn]`, A7.7.52: strictly aligned halfword load that tags the monitor with Rn.
pub const LDAEXH_T1 = mem.LoadExclusivePlain(16).call;
/// STLEX `stlex Rd, Rt, [Rn]`, A7.7.167: word store if the monitor holds Rn, Rd = 0 on success, monitor cleared.
pub const STLEX_T1 = mem.StoreExclusivePlain(32).call;
/// STLEXB `stlexb Rd, Rt, [Rn]`, A7.7.167: byte store if the monitor holds Rn, Rd = 0 on success, monitor cleared.
pub const STLEXB_T1 = mem.StoreExclusivePlain(8).call;
/// STLEXH `stlexh Rd, Rt, [Rn]`, A7.7.167: halfword store if the monitor holds Rn, Rd = 0 on success, monitor cleared.
pub const STLEXH_T1 = mem.StoreExclusivePlain(16).call;
/// WLS `wls lr, Rn, label`: lr = Rn; branches past the loop when Rn is zero.
pub const WLS_T1 = branch.whileLoopStart;
/// DLS `dls lr, Rn`: lr = Rn to start a low-overhead loop, no branch.
pub const DLS_T2 = branch.doLoopStart;
/// LE `le lr, label`: decrements lr and branches back while it stays above one.
pub const LE_T1 = branch.loopEnd;
/// LE `le label`: unconditional low-overhead loop-back branch, lr untouched.
pub const LE_T2 = branch.loopForever;
/// CLRM `clrm {list}`: zeroes the listed registers, lr on its bit, APSR on the A bit.
pub const CLRM_T1 = system.clrm;
/// CSEL/CSINC/CSINV/CSNEG `Rd, Rn|zr, Rm, cond`: Rd = Rn if cond, else Rm, Rm+1, ~Rm or -Rm.
pub const CSEL_T1_r0 = alu.Conditional(1, 0).call;
/// CSEL/CSINC/CSINV/CSNEG `Rd, Rn|zr, Rm, cond`: Rd = Rn if cond, else Rm, Rm+1, ~Rm or -Rm, Rm r8-r11.
pub const CSEL_T1_r8 = alu.Conditional(1, 8).call;
/// CSEL/CSINC/CSINV/CSNEG `Rd, Rn|zr, Rm, cond`: Rd = Rn if cond, else Rm, Rm+1, ~Rm or -Rm, Rm r12/r14.
pub const CSEL_T1_r12 = alu.Conditional(2, 12).call;
/// CSEL/CSINC/CSINV/CSNEG `Rd, Rn|zr, zr, cond`: Rd = Rn if cond, else 0, 1, ~0 or 0.
pub const CSEL_T1_zr = alu.conditionalZero;
/// BF/BFX/BFL/BFLX, 3-bit b field: branch-future hint, executed as a no-op.
pub const BF_T1_b3 = branch.branchFutureWide;
/// BF/BFX/BFL/BFLX, 2-bit b field: branch-future hint, executed as a no-op.
pub const BF_T1_b2 = branch.branchFutureWide;
/// BF/BFX/BFL/BFLX, 1-bit b field: branch-future hint, executed as a no-op.
pub const BF_T1_b1 = branch.branchFutureWide;
/// BF/BFCSEL, no b field: branch-future hint, executed as a no-op.
pub const BF_T1_b0 = branch.branchFuture;

/// STRBT `strbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte store, 8-bit offset, Rn=15 undefined.
pub const STRBT_T1 = mem.WideStore(8, true).call;
/// STRHT `strht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword store, 8-bit offset, Rn=15 undefined.
pub const STRHT_T1 = mem.WideStore(16, true).call;
/// STRT `strt Rt, [Rn, #imm]`, A7.7.54: unprivileged word store, 8-bit offset, Rn=15 undefined.
pub const STRT_T1 = mem.WideStore(32, true).call;
/// LDRBT `ldrbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load, 8-bit offset.
pub const LDRBT_T1 = mem.WideLoad(8, false, 0, true).call;
/// LDRBT `ldrbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load, 8-bit offset, Rn r8-r11.
pub const LDRBT_T1_r8 = mem.WideLoad(8, false, 8, true).call;
/// LDRBT `ldrbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load, 8-bit offset, Rn r12-r13.
pub const LDRBT_T1_r12 = mem.WideLoad(8, false, 12, true).call;
/// LDRBT `ldrbt Rt, [lr, #imm]`, A7.7.54: unprivileged byte load, 8-bit offset, Rn=lr.
pub const LDRBT_T1_lr = mem.WideLoadAt(8, false, 14, true).call;
/// LDRHT `ldrht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load, 8-bit offset.
pub const LDRHT_T1 = mem.WideLoad(16, false, 0, true).call;
/// LDRHT `ldrht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load, 8-bit offset, Rn r8-r11.
pub const LDRHT_T1_r8 = mem.WideLoad(16, false, 8, true).call;
/// LDRHT `ldrht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load, 8-bit offset, Rn r12-r13.
pub const LDRHT_T1_r12 = mem.WideLoad(16, false, 12, true).call;
/// LDRHT `ldrht Rt, [lr, #imm]`, A7.7.54: unprivileged halfword load, 8-bit offset, Rn=lr.
pub const LDRHT_T1_lr = mem.WideLoadAt(16, false, 14, true).call;
/// LDRT `ldrt Rt, [Rn, #imm]`, A7.7.54: unprivileged word load, 8-bit offset.
pub const LDRT_T1 = mem.WideLoad(32, false, 0, true).call;
/// LDRT `ldrt Rt, [Rn, #imm]`, A7.7.54: unprivileged word load, 8-bit offset, Rn r8-r11.
pub const LDRT_T1_r8 = mem.WideLoad(32, false, 8, true).call;
/// LDRT `ldrt Rt, [Rn, #imm]`, A7.7.54: unprivileged word load, 8-bit offset, Rn r12-r13.
pub const LDRT_T1_r12 = mem.WideLoad(32, false, 12, true).call;
/// LDRT `ldrt Rt, [lr, #imm]`, A7.7.54: unprivileged word load, 8-bit offset, Rn=lr.
pub const LDRT_T1_lr = mem.WideLoadAt(32, false, 14, true).call;
/// LDRSBT `ldrsbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load sign-extended, 8-bit offset.
pub const LDRSBT_T1 = mem.WideLoad(8, true, 0, true).call;
/// LDRSBT `ldrsbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load sign-extended, 8-bit offset, Rn r8-r11.
pub const LDRSBT_T1_r8 = mem.WideLoad(8, true, 8, true).call;
/// LDRSBT `ldrsbt Rt, [Rn, #imm]`, A7.7.54: unprivileged byte load sign-extended, 8-bit offset, Rn r12-r13.
pub const LDRSBT_T1_r12 = mem.WideLoad(8, true, 12, true).call;
/// LDRSBT `ldrsbt Rt, [lr, #imm]`, A7.7.54: unprivileged byte load sign-extended, 8-bit offset, Rn=lr.
pub const LDRSBT_T1_lr = mem.WideLoadAt(8, true, 14, true).call;
/// LDRSHT `ldrsht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load sign-extended, 8-bit offset.
pub const LDRSHT_T1 = mem.WideLoad(16, true, 0, true).call;
/// LDRSHT `ldrsht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load sign-extended, 8-bit offset, Rn r8-r11.
pub const LDRSHT_T1_r8 = mem.WideLoad(16, true, 8, true).call;
/// LDRSHT `ldrsht Rt, [Rn, #imm]`, A7.7.54: unprivileged halfword load sign-extended, 8-bit offset, Rn r12-r13.
pub const LDRSHT_T1_r12 = mem.WideLoad(16, true, 12, true).call;
/// LDRSHT `ldrsht Rt, [lr, #imm]`, A7.7.54: unprivileged halfword load sign-extended, 8-bit offset, Rn=lr.
pub const LDRSHT_T1_lr = mem.WideLoadAt(16, true, 14, true).call;

/// CPSIE `cpsie i`, A7.7.29: clears PRIMASK, reported to the host, B1.5.16.
pub const CPSIE_T1_i = system.Cps(false, true, false).call;
/// CPSID `cpsid i`, A7.7.29: sets PRIMASK, reported to the host, B1.5.16.
pub const CPSID_T1_i = system.Cps(true, true, false).call;
/// CPSIE `cpsie f`, A7.7.29: clears FAULTMASK, reported to the host, B1.5.16.
pub const CPSIE_T1_f = system.Cps(false, false, true).call;
/// CPSID `cpsid f`, A7.7.29: sets FAULTMASK, reported to the host, B1.5.16.
pub const CPSID_T1_f = system.Cps(true, false, true).call;
/// CPSIE `cpsie if`, A7.7.29: clears PRIMASK and FAULTMASK, reported to the host, B1.5.16.
pub const CPSIE_T1_if = system.Cps(false, true, true).call;
/// CPSID `cpsid if`, A7.7.29: sets PRIMASK and FAULTMASK, reported to the host, B1.5.16.
pub const CPSID_T1_if = system.Cps(true, true, true).call;

/// VADD.F32 `vadd.f32 Sd, Sn, Sm`: adds single-precision Sn and Sm into Sd under FPSCR.
pub const @"VADD.F32_T1" = fp.Binary(.add, f32).call;
/// VSUB.F32 `vsub.f32 Sd, Sn, Sm`: subtracts single-precision Sn and Sm into Sd under FPSCR.
pub const @"VSUB.F32_T1" = fp.Binary(.sub, f32).call;
/// VMUL.F32 `vmul.f32 Sd, Sn, Sm`: multiplies single-precision Sn and Sm into Sd under FPSCR.
pub const @"VMUL.F32_T1" = fp.Binary(.mul, f32).call;
/// VNMUL.F32 `vnmul.f32 Sd, Sn, Sm`: negates the product of single-precision Sn and Sm into Sd under FPSCR.
pub const @"VNMUL.F32_T2" = fp.Binary(.nmul, f32).call;
/// VDIV.F32 `vdiv.f32 Sd, Sn, Sm`: divides single-precision Sn and Sm into Sd under FPSCR.
pub const @"VDIV.F32_T1" = fp.Binary(.div, f32).call;
/// VMLA.F32 `vmla.f32 Sd, Sn, Sm`: single-precision Sd += Sn*Sm.
pub const @"VMLA.F32_T1" = fp.Fused(.mla, f32).call;
/// VMLS.F32 `vmls.f32 Sd, Sn, Sm`: single-precision Sd -= Sn*Sm.
pub const @"VMLS.F32_T1" = fp.Fused(.mls, f32).call;
/// VNMLS.F32 `vnmls.f32 Sd, Sn, Sm`: single-precision Sd = Sn*Sm - Sd.
pub const @"VNMLS.F32_T1" = fp.Fused(.nmls, f32).call;
/// VNMLA.F32 `vnmla.f32 Sd, Sn, Sm`: single-precision Sd = -(Sn*Sm) - Sd.
pub const @"VNMLA.F32_T1" = fp.Fused(.nmla, f32).call;
/// VFMA.F32 `vfma.f32 Sd, Sn, Sm`: single-precision fused Sd += Sn*Sm.
pub const @"VFMA.F32_T1" = fp.Fused(.fma, f32).call;
/// VFMS.F32 `vfms.f32 Sd, Sn, Sm`: single-precision fused Sd -= Sn*Sm.
pub const @"VFMS.F32_T1" = fp.Fused(.fms, f32).call;
/// VFNMS.F32 `vfnms.f32 Sd, Sn, Sm`: single-precision fused Sd = Sn*Sm - Sd.
pub const @"VFNMS.F32_T1" = fp.Fused(.fnms, f32).call;
/// VFNMA.F32 `vfnma.f32 Sd, Sn, Sm`: single-precision fused Sd = -(Sn*Sm) - Sd.
pub const @"VFNMA.F32_T1" = fp.Fused(.fnma, f32).call;
/// VMOV.F32 `vmov.f32 Sd, Sm`: copies the single-precision Sm into Sd.
pub const @"VMOV.F32_reg_T1" = fp.Unary(.move, f32).call;
/// VABS.F32 `vabs.f32 Sd, Sm`: clears the sign of the single-precision Sm into Sd.
pub const @"VABS.F32_T1" = fp.Unary(.abs, f32).call;
/// VNEG.F32 `vneg.f32 Sd, Sm`: flips the sign of the single-precision Sm into Sd.
pub const @"VNEG.F32_T1" = fp.Unary(.negate, f32).call;
/// VSQRT.F32 `vsqrt.f32 Sd, Sm`: takes the square root of the single-precision Sm into Sd.
pub const @"VSQRT.F32_T1" = fp.Unary(.root, f32).call;
/// VCVT.F32.U32 `vcvt.f32.u32 Sd, Sm`: single-precision unsigned int to float.
pub const @"VCVT.F32.U32_int_T1" = fp.Convert(.from_unsigned, f32).call;
/// VCVT.F32.S32 `vcvt.f32.s32 Sd, Sm`: single-precision signed int to float.
pub const @"VCVT.F32.S32_int_T1" = fp.Convert(.from_signed, f32).call;
/// VCVTR.U32.F32 `vcvtr.u32.f32 Sd, Sm`: single-precision float to unsigned int, FPSCR rounding.
pub const @"VCVTR.U32.F32_int_T1" = fp.Convert(.to_unsigned_round, f32).call;
/// VCVT.U32.F32 `vcvt.u32.f32 Sd, Sm`: single-precision float to unsigned int, toward zero.
pub const @"VCVT.U32.F32_int_T1" = fp.Convert(.to_unsigned, f32).call;
/// VCVTR.S32.F32 `vcvtr.s32.f32 Sd, Sm`: single-precision float to signed int, FPSCR rounding.
pub const @"VCVTR.S32.F32_int_T1" = fp.Convert(.to_signed_round, f32).call;
/// VCVT.S32.F32 `vcvt.s32.f32 Sd, Sm`: single-precision float to signed int, toward zero.
pub const @"VCVT.S32.F32_int_T1" = fp.Convert(.to_signed, f32).call;
/// VCVTB.F32.F16 `vcvtb.f32.f16 Sd, Sm`: single-precision low half to single.
pub const @"VCVTB.F32.F16_T1" = fp.Convert(.from_half_low, f32).call;
/// VCVTT.F32.F16 `vcvtt.f32.f16 Sd, Sm`: single-precision high half to single.
pub const @"VCVTT.F32.F16_T1" = fp.Convert(.from_half_high, f32).call;
/// VCVTB.F16.F32 `vcvtb.f16.f32 Sd, Sm`: single-precision single to half in the low half.
pub const @"VCVTB.F16.F32_T1" = fp.Convert(.to_half_low, f32).call;
/// VCVTT.F16.F32 `vcvtt.f16.f32 Sd, Sm`: single-precision single to half in the high half.
pub const @"VCVTT.F16.F32_T1" = fp.Convert(.to_half_high, f32).call;
/// VCVT.F32.S16 `vcvt.f32.s16 Sd, Sd, #fbits`: signed 16-bit fixed-point to single float, fbits binary places, in place.
pub const @"VCVT.F32.S16_fix_T1" = fp.Fixed(false, true, 16, f32).call;
/// VCVT.F32.S32 `vcvt.f32.s32 Sd, Sd, #fbits`: signed 32-bit fixed-point to single float, fbits binary places, in place.
pub const @"VCVT.F32.S32_fix_T1" = fp.Fixed(false, true, 32, f32).call;
/// VCVT.F32.U16 `vcvt.f32.u16 Sd, Sd, #fbits`: unsigned 16-bit fixed-point to single float, fbits binary places, in place.
pub const @"VCVT.F32.U16_fix_T1" = fp.Fixed(false, false, 16, f32).call;
/// VCVT.F32.U32 `vcvt.f32.u32 Sd, Sd, #fbits`: unsigned 32-bit fixed-point to single float, fbits binary places, in place.
pub const @"VCVT.F32.U32_fix_T1" = fp.Fixed(false, false, 32, f32).call;
/// VCVT.S16.F32 `vcvt.s16.f32 Sd, Sd, #fbits`: single float to signed 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S16.F32_fix_T1" = fp.Fixed(true, true, 16, f32).call;
/// VCVT.S32.F32 `vcvt.s32.f32 Sd, Sd, #fbits`: single float to signed 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S32.F32_fix_T1" = fp.Fixed(true, true, 32, f32).call;
/// VCVT.U16.F32 `vcvt.u16.f32 Sd, Sd, #fbits`: single float to unsigned 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U16.F32_fix_T1" = fp.Fixed(true, false, 16, f32).call;
/// VCVT.U32.F32 `vcvt.u32.f32 Sd, Sd, #fbits`: single float to unsigned 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U32.F32_fix_T1" = fp.Fixed(true, false, 32, f32).call;
/// VCMP.F32 `vcmp.f32 Sd, Sm`: single-precision compare into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F32_T1" = fp.Compare(false, f32).call;
/// VCMPE.F32 `vcmpe.f32 Sd, Sm`: single-precision compare into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F32_T1" = fp.Compare(true, f32).call;
/// VCMP.F32 `vcmp.f32 Sd, #0.0`: single-precision compare with zero into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F32_T2" = fp.CompareZero(false, f32).call;
/// VCMPE.F32 `vcmpe.f32 Sd, #0.0`: single-precision compare with zero into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F32_T2" = fp.CompareZero(true, f32).call;
/// VMOV.F32 `vmov.f32 Sd, #imm`: Sd = the 8-bit modified-immediate constant as single-precision.
pub const @"VMOV.F32_imm_T1" = fp.MoveImmediate(f32).call;
/// VMOV.32 `vmov.32 Dd[x], Rt`: word x of Dd = Rt.
pub const @"VMOV.32_core_scalar_T1" = fp.Lane(false).call;
/// VMOV.32 `vmov.32 Rt, Dd[x]`: Rt = word x of Dd.
pub const @"VMOV.32_scalar_core_T1" = fp.Lane(true).call;
/// VMOV `vmov Sn, Rt`: Sn = Rt's bits, single form.
pub const VMOV_core_sp_T1_op0 = fp.MoveCore(false, f32).call;
/// VMOV `vmov Rt, Sn`: Rt = Sn's bits, single form.
pub const VMOV_core_sp_T1_op1 = fp.MoveCore(true, f32).call;
/// VMOV `vmov Sm, Sm1, Rt, Rt2`: two consecutive single registers = Rt, Rt2.
pub const VMOV_cores_sp_T1_op0 = fp.MovePair(false).call;
/// VMOV `vmov Rt, Rt2, Sm, Sm1`: Rt, Rt2 = two consecutive single registers.
pub const VMOV_cores_sp_T1_op1 = fp.MovePair(true).call;
/// VMOV `vmov Dm, Rt, Rt2`: Dm's low and high words = Rt, Rt2.
pub const VMOV_cores_dp_T1_op0 = fp.MoveDouble(false).call;
/// VMOV `vmov Rt, Rt2, Dm`: Rt, Rt2 = Dm's low and high words.
pub const VMOV_cores_dp_T1_op1 = fp.MoveDouble(true).call;
/// VLDR `vldr Sd, [Rn, #±imm*4]`: word load into Sd at Rn plus or minus the scaled offset.
pub const VLDR_T2 = fp.LoadStore(true, f32).call;
/// VSTR `vstr Sd, [Rn, #±imm*4]`: word store of Sd at Rn plus or minus the scaled offset.
pub const VSTR_T2 = fp.LoadStore(false, f32).call;
/// VLDMIA `vldmia Rn{!}, {Slist}`: loads consecutive single registers upward from Rn, writeback per W.
pub const VLDMIA_T2 = fp.Block(true, 0).call;
/// VLDMIA `vldmia Rn{!}, {Slist}`: loads consecutive single registers upward from Rn, writeback per W, Rn r8-r11.
pub const VLDMIA_T2_r8 = fp.Block(true, 8).call;
/// VLDMIA `vldmia Rn{!}, {Slist}`: loads consecutive single registers upward from Rn, writeback per W, Rn r12-r13.
pub const VLDMIA_T2_r12 = fp.Block(true, 12).call;
/// VLDMIA `vldmia lr{!}, {Slist}`: loads consecutive single registers upward from Rn, writeback per W, Rn=lr.
pub const VLDMIA_T2_lr = fp.BlockTop(true).call;
/// VSTMIA `vstmia Rn{!}, {Slist}`: stores consecutive single registers upward from Rn, writeback per W.
pub const VSTMIA_T2 = fp.Block(false, 0).call;
/// VLDMDB `vldmdb Rn!, {Slist}`: loads consecutive single registers below Rn, Rn written back.
pub const VLDMDB_T2 = fp.BlockBack(true).call;
/// VSTMDB `vstmdb Rn!, {Slist}`: stores consecutive single registers below Rn, Rn written back.
pub const VSTMDB_T2 = fp.BlockBack(false).call;
/// VLDR `vldr Dd, [Rn, #±imm*4]`: two-word load into Dd at Rn plus or minus imm8*4.
pub const VLDR_T1 = fp.LoadStoreDouble(true).call;
/// VSTR `vstr Dd, [Rn, #±imm*4]`: two-word store of Dd at Rn plus or minus imm8*4.
pub const VSTR_T1 = fp.LoadStoreDouble(false).call;
/// VLDMIA `vldmia Rn{!}, {Dlist}`: loads consecutive double registers upward from Rn, writeback per W.
pub const VLDMIA_T1 = fp.BlockDouble(true, 0).call;
/// VLDMIA `vldmia Rn{!}, {Dlist}`: loads consecutive double registers upward from Rn, writeback per W, Rn r8-r11.
pub const VLDMIA_T1_r8 = fp.BlockDouble(true, 8).call;
/// VLDMIA `vldmia Rn{!}, {Dlist}`: loads consecutive double registers upward from Rn, writeback per W, Rn r12-r13.
pub const VLDMIA_T1_r12 = fp.BlockDouble(true, 12).call;
/// VLDMIA `vldmia lr{!}, {Dlist}`: loads consecutive double registers upward from Rn, writeback per W, Rn=lr.
pub const VLDMIA_T1_lr = fp.BlockDoubleTop(true).call;
/// VSTMIA `vstmia Rn{!}, {Dlist}`: stores consecutive double registers upward from Rn, writeback per W.
pub const VSTMIA_T1 = fp.BlockDouble(false, 0).call;
/// VLDMDB `vldmdb Rn!, {Dlist}`: loads consecutive double registers below Rn, Rn written back.
pub const VLDMDB_T1 = fp.BlockDoubleBack(true).call;
/// VSTMDB `vstmdb Rn!, {Dlist}`: stores consecutive double registers below Rn, Rn written back.
pub const VSTMDB_T1 = fp.BlockDoubleBack(false).call;
/// VMRS `vmrs Rt|APSR_nzcv, fpscr`: Rt = FPSCR, or APSR NZCV from it when Rt is 15.
pub const VMRS_T1_fpscr = fp.Status(true).call;
/// VMSR `vmsr fpscr, Rt`: FPSCR = Rt, masked to the bits this core implements.
pub const VMSR_T1_fpscr = fp.Status(false).call;

/// UMAAL `umaal RdLo, RdHi, Rn, Rm`: RdHi:RdLo = Rn*Rm + RdLo + RdHi, all unsigned.
pub const UMAAL_T1 = dsp.umaal;
/// SADD8 `sadd8 Rd, Rn, Rm`: four byte adds in parallel, signed, GE flags set.
pub const SADD8_T1 = dsp.Simd(.add8, .signed).call;
/// SADD16 `sadd16 Rd, Rn, Rm`: two halfword adds in parallel, signed, GE flags set.
pub const SADD16_T1 = dsp.Simd(.add16, .signed).call;
/// SSUB8 `ssub8 Rd, Rn, Rm`: four byte subtracts in parallel, signed, GE flags set.
pub const SSUB8_T1 = dsp.Simd(.sub8, .signed).call;
/// SSUB16 `ssub16 Rd, Rn, Rm`: two halfword subtracts in parallel, signed, GE flags set.
pub const SSUB16_T1 = dsp.Simd(.sub16, .signed).call;
/// SASX `sasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, signed, GE flags set.
pub const SASX_T1 = dsp.Simd(.asx, .signed).call;
/// SSAX `ssax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, signed, GE flags set.
pub const SSAX_T1 = dsp.Simd(.sax, .signed).call;
/// QADD8 `qadd8 Rd, Rn, Rm`: four byte adds in parallel, signed saturating.
pub const QADD8_T1 = dsp.Simd(.add8, .saturating).call;
/// QADD16 `qadd16 Rd, Rn, Rm`: two halfword adds in parallel, signed saturating.
pub const QADD16_T1 = dsp.Simd(.add16, .saturating).call;
/// QSUB8 `qsub8 Rd, Rn, Rm`: four byte subtracts in parallel, signed saturating.
pub const QSUB8_T1 = dsp.Simd(.sub8, .saturating).call;
/// QSUB16 `qsub16 Rd, Rn, Rm`: two halfword subtracts in parallel, signed saturating.
pub const QSUB16_T1 = dsp.Simd(.sub16, .saturating).call;
/// QASX `qasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, signed saturating.
pub const QASX_T1 = dsp.Simd(.asx, .saturating).call;
/// QSAX `qsax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, signed saturating.
pub const QSAX_T1 = dsp.Simd(.sax, .saturating).call;
/// SHADD8 `shadd8 Rd, Rn, Rm`: four byte adds in parallel, signed halved.
pub const SHADD8_T1 = dsp.Simd(.add8, .halving).call;
/// SHADD16 `shadd16 Rd, Rn, Rm`: two halfword adds in parallel, signed halved.
pub const SHADD16_T1 = dsp.Simd(.add16, .halving).call;
/// SHSUB8 `shsub8 Rd, Rn, Rm`: four byte subtracts in parallel, signed halved.
pub const SHSUB8_T1 = dsp.Simd(.sub8, .halving).call;
/// SHSUB16 `shsub16 Rd, Rn, Rm`: two halfword subtracts in parallel, signed halved.
pub const SHSUB16_T1 = dsp.Simd(.sub16, .halving).call;
/// SHASX `shasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, signed halved.
pub const SHASX_T1 = dsp.Simd(.asx, .halving).call;
/// SHSAX `shsax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, signed halved.
pub const SHSAX_T1 = dsp.Simd(.sax, .halving).call;
/// UADD8 `uadd8 Rd, Rn, Rm`: four byte adds in parallel, unsigned, GE flags set.
pub const UADD8_T1 = dsp.Simd(.add8, .unsigned).call;
/// UADD16 `uadd16 Rd, Rn, Rm`: two halfword adds in parallel, unsigned, GE flags set.
pub const UADD16_T1 = dsp.Simd(.add16, .unsigned).call;
/// USUB8 `usub8 Rd, Rn, Rm`: four byte subtracts in parallel, unsigned, GE flags set.
pub const USUB8_T1 = dsp.Simd(.sub8, .unsigned).call;
/// USUB16 `usub16 Rd, Rn, Rm`: two halfword subtracts in parallel, unsigned, GE flags set.
pub const USUB16_T1 = dsp.Simd(.sub16, .unsigned).call;
/// UASX `uasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, unsigned, GE flags set.
pub const UASX_T1 = dsp.Simd(.asx, .unsigned).call;
/// USAX `usax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, unsigned, GE flags set.
pub const USAX_T1 = dsp.Simd(.sax, .unsigned).call;
/// UQADD8 `uqadd8 Rd, Rn, Rm`: four byte adds in parallel, unsigned saturating.
pub const UQADD8_T1 = dsp.Simd(.add8, .unsigned_saturating).call;
/// UQADD16 `uqadd16 Rd, Rn, Rm`: two halfword adds in parallel, unsigned saturating.
pub const UQADD16_T1 = dsp.Simd(.add16, .unsigned_saturating).call;
/// UQSUB8 `uqsub8 Rd, Rn, Rm`: four byte subtracts in parallel, unsigned saturating.
pub const UQSUB8_T1 = dsp.Simd(.sub8, .unsigned_saturating).call;
/// UQSUB16 `uqsub16 Rd, Rn, Rm`: two halfword subtracts in parallel, unsigned saturating.
pub const UQSUB16_T1 = dsp.Simd(.sub16, .unsigned_saturating).call;
/// UQASX `uqasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, unsigned saturating.
pub const UQASX_T1 = dsp.Simd(.asx, .unsigned_saturating).call;
/// UQSAX `uqsax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, unsigned saturating.
pub const UQSAX_T1 = dsp.Simd(.sax, .unsigned_saturating).call;
/// UHADD8 `uhadd8 Rd, Rn, Rm`: four byte adds in parallel, unsigned halved.
pub const UHADD8_T1 = dsp.Simd(.add8, .unsigned_halving).call;
/// UHADD16 `uhadd16 Rd, Rn, Rm`: two halfword adds in parallel, unsigned halved.
pub const UHADD16_T1 = dsp.Simd(.add16, .unsigned_halving).call;
/// UHSUB8 `uhsub8 Rd, Rn, Rm`: four byte subtracts in parallel, unsigned halved.
pub const UHSUB8_T1 = dsp.Simd(.sub8, .unsigned_halving).call;
/// UHSUB16 `uhsub16 Rd, Rn, Rm`: two halfword subtracts in parallel, unsigned halved.
pub const UHSUB16_T1 = dsp.Simd(.sub16, .unsigned_halving).call;
/// UHASX `uhasx Rd, Rn, Rm`: halfword add then subtract, exchanged in parallel, unsigned halved.
pub const UHASX_T1 = dsp.Simd(.asx, .unsigned_halving).call;
/// UHSAX `uhsax Rd, Rn, Rm`: halfword subtract then add, exchanged in parallel, unsigned halved.
pub const UHSAX_T1 = dsp.Simd(.sax, .unsigned_halving).call;
/// SEL `sel Rd, Rn, Rm`: each byte of Rd from Rn or Rm by the matching GE flag.
pub const SEL_T1 = dsp.sel;
/// SMLABB `smlabb Rd, Rn, Rm, Ra`: Rd = Ra + Rn[15:0] * Rm[15:0] signed halves, Q on overflow.
pub const SMLABB_T1 = dsp.HalfMultiply(false, false).call;
/// SMLABT `smlabt Rd, Rn, Rm, Ra`: Rd = Ra + Rn[15:0] * Rm[31:16] signed halves, Q on overflow.
pub const SMLABT_T1 = dsp.HalfMultiply(false, true).call;
/// SMLATB `smlatb Rd, Rn, Rm, Ra`: Rd = Ra + Rn[31:16] * Rm[15:0] signed halves, Q on overflow.
pub const SMLATB_T1 = dsp.HalfMultiply(true, false).call;
/// SMLATT `smlatt Rd, Rn, Rm, Ra`: Rd = Ra + Rn[31:16] * Rm[31:16] signed halves, Q on overflow.
pub const SMLATT_T1 = dsp.HalfMultiply(true, true).call;
/// SMLAWB `smlawb Rd, Rn, Rm, Ra`: Rd = high word of Rn times Rm's bottom half, plus Ra.
pub const SMLAWB_T1 = dsp.WideHalfMultiply(false).call;
/// SMLAWT `smlawt Rd, Rn, Rm, Ra`: Rd = high word of Rn times Rm's top half, plus Ra.
pub const SMLAWT_T1 = dsp.WideHalfMultiply(true).call;
/// SMLAD `smlad Rd, Rn, Rm, Ra`: Rd = Ra + sum of the halfword products, Q on overflow.
pub const SMLAD_T1 = dsp.DualMultiply(false, false).call;
/// SMLADX `smladx Rd, Rn, Rm, Ra`: Rd = Ra + sum of the halfword products, Rm swapped, Q on overflow.
pub const SMLADX_T1 = dsp.DualMultiply(false, true).call;
/// SMLSD `smlsd Rd, Rn, Rm, Ra`: Rd = Ra + difference of the halfword products, Q on overflow.
pub const SMLSD_T1 = dsp.DualMultiply(true, false).call;
/// SMLSDX `smlsdx Rd, Rn, Rm, Ra`: Rd = Ra + difference of the halfword products, Rm swapped, Q on overflow.
pub const SMLSDX_T1 = dsp.DualMultiply(true, true).call;
/// SMMLA `smmla Rd, Rn, Rm, Ra`: Rd = high word of Ra:0 + Rn*Rm; Rd=15 is AUTG under PACBTI.
pub const SMMLA_T1 = dsp.Authenticating(false, false).call;
/// SMMLAR `smmlar Rd, Rn, Rm, Ra`: Rd = high word of Ra:0 + Rn*Rm, rounded; Rd=15 is AUTG under PACBTI.
pub const SMMLAR_T1 = dsp.Authenticating(false, true).call;
/// SMMLS `smmls Rd, Rn, Rm, Ra`: Rd = high word of Ra:0 - Rn*Rm; Ra=15 is PACG under PACBTI.
pub const SMMLS_T1 = dsp.signing;
/// SMMLSR `smmlsr Rd, Rn, Rm, Ra`: Rd = high word of Ra:0 - Rn*Rm, rounded.
pub const SMMLSR_T1 = dsp.TopMultiply(true, true).call;
/// USADA8 `usada8 Rd, Rn, Rm, Ra`: Rd = Ra plus the four byte absolute differences; Ra=15 is USAD8.
pub const USADA8_T1 = dsp.absoluteDifference;
/// SMLALBB `smlalbb RdLo, RdHi, Rn, Rm`: RdHi:RdLo += Rn[15:0] * Rm[15:0], signed halves.
pub const SMLALBB_T1 = dsp.LongHalfMultiply(false, false).call;
/// SMLALBT `smlalbt RdLo, RdHi, Rn, Rm`: RdHi:RdLo += Rn[15:0] * Rm[31:16], signed halves.
pub const SMLALBT_T1 = dsp.LongHalfMultiply(false, true).call;
/// SMLALTB `smlaltb RdLo, RdHi, Rn, Rm`: RdHi:RdLo += Rn[31:16] * Rm[15:0], signed halves.
pub const SMLALTB_T1 = dsp.LongHalfMultiply(true, false).call;
/// SMLALTT `smlaltt RdLo, RdHi, Rn, Rm`: RdHi:RdLo += Rn[31:16] * Rm[31:16], signed halves.
pub const SMLALTT_T1 = dsp.LongHalfMultiply(true, true).call;
/// SMLALD `smlald RdLo, RdHi, Rn, Rm`: RdHi:RdLo += the sum of the two halfword products.
pub const SMLALD_T1 = dsp.LongDualMultiply(false, false).call;
/// SMLALDX `smlaldx RdLo, RdHi, Rn, Rm`: RdHi:RdLo += the sum of the two halfword products, Rm halves swapped.
pub const SMLALDX_T1 = dsp.LongDualMultiply(false, true).call;
/// SMLSLD `smlsld RdLo, RdHi, Rn, Rm`: RdHi:RdLo += the difference of the two halfword products.
pub const SMLSLD_T1 = dsp.LongDualMultiply(true, false).call;
/// SMLSLDX `smlsldx RdLo, RdHi, Rn, Rm`: RdHi:RdLo += the difference of the two halfword products, Rm halves swapped.
pub const SMLSLDX_T1 = dsp.LongDualMultiply(true, true).call;
/// QADD `qadd Rd, Rm, Rn`: Rd = Rm plus Rn, signed saturating, Q on saturation.
pub const QADD_T1 = dsp.Saturating(false, false).call;
/// QDADD `qdadd Rd, Rm, Rn`: Rd = Rm plus doubled Rn, signed saturating, Q on saturation.
pub const QDADD_T1 = dsp.Saturating(false, true).call;
/// QSUB `qsub Rd, Rm, Rn`: Rd = Rm minus Rn, signed saturating, Q on saturation.
pub const QSUB_T1 = dsp.Saturating(true, false).call;
/// QDSUB `qdsub Rd, Rm, Rn`: Rd = Rm minus doubled Rn, signed saturating, Q on saturation.
pub const QDSUB_T1 = dsp.Saturating(true, true).call;
/// PKHBT `pkhbt Rd, Rn, Rm{, lsl #n}`: Rd = Rn's low halfword under the top halfword of Rm shifted left.
pub const PKHBT_T1 = dsp.Pack(false).call;
/// PKHTB `pkhtb Rd, Rn, Rm{, asr #n}`: Rd = Rn's top halfword over the low halfword of Rm shifted right.
pub const PKHTB_T1 = dsp.Pack(true).call;
/// SXTAB16 `sxtab16 Rd, Rn, Rm{, shift}`: two sign-extended bytes of rotated Rm added to Rn's halfwords.
pub const SXTAB16_T1 = dsp.ExtendAdd16(true).call;
/// UXTAB16 `uxtab16 Rd, Rn, Rm{, shift}`: two zero-extended bytes of rotated Rm added to Rn's halfwords.
pub const UXTAB16_T1 = dsp.ExtendAdd16(false).call;
/// SXTAH `sxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit sign-extended.
pub const SXTAH_T1 = dsp.ExtendAdd(16, true, 0).call;
/// SXTAH `sxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit sign-extended, Rn r8-r11.
pub const SXTAH_T1_r8 = dsp.ExtendAdd(16, true, 8).call;
/// SXTAH `sxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit sign-extended, Rn r12-r13.
pub const SXTAH_T1_r12 = dsp.ExtendAdd(16, true, 12).call;
/// SXTAH `sxtah Rd, lr, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit sign-extended, Rn=lr.
pub const SXTAH_T1_lr = dsp.ExtendAdd(16, true, 14).fixed;
/// UXTAH `uxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit zero-extended.
pub const UXTAH_T1 = dsp.ExtendAdd(16, false, 0).call;
/// UXTAH `uxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit zero-extended, Rn r8-r11.
pub const UXTAH_T1_r8 = dsp.ExtendAdd(16, false, 8).call;
/// UXTAH `uxtah Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit zero-extended, Rn r12-r13.
pub const UXTAH_T1_r12 = dsp.ExtendAdd(16, false, 12).call;
/// UXTAH `uxtah Rd, lr, Rm{, shift}`: Rd = Rn plus rotated Rm's low 16-bit zero-extended, Rn=lr.
pub const UXTAH_T1_lr = dsp.ExtendAdd(16, false, 14).fixed;
/// SXTAB `sxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit sign-extended.
pub const SXTAB_T1 = dsp.ExtendAdd(8, true, 0).call;
/// SXTAB `sxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit sign-extended, Rn r8-r11.
pub const SXTAB_T1_r8 = dsp.ExtendAdd(8, true, 8).call;
/// SXTAB `sxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit sign-extended, Rn r12-r13.
pub const SXTAB_T1_r12 = dsp.ExtendAdd(8, true, 12).call;
/// SXTAB `sxtab Rd, lr, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit sign-extended, Rn=lr.
pub const SXTAB_T1_lr = dsp.ExtendAdd(8, true, 14).fixed;
/// UXTAB `uxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit zero-extended.
pub const UXTAB_T1 = dsp.ExtendAdd(8, false, 0).call;
/// UXTAB `uxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit zero-extended, Rn r8-r11.
pub const UXTAB_T1_r8 = dsp.ExtendAdd(8, false, 8).call;
/// UXTAB `uxtab Rd, Rn, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit zero-extended, Rn r12-r13.
pub const UXTAB_T1_r12 = dsp.ExtendAdd(8, false, 12).call;
/// UXTAB `uxtab Rd, lr, Rm{, shift}`: Rd = Rn plus rotated Rm's low 8-bit zero-extended, Rn=lr.
pub const UXTAB_T1_lr = dsp.ExtendAdd(8, false, 14).fixed;
/// VADD.F64 `vadd.f64 Dd, Dn, Dm`: adds double-precision Dn and Dm into Dd under FPSCR.
pub const @"VADD.F64_T1" = fp.BinaryDouble(.add).call;
/// VSUB.F64 `vsub.f64 Dd, Dn, Dm`: subtracts double-precision Dn and Dm into Dd under FPSCR.
pub const @"VSUB.F64_T1" = fp.BinaryDouble(.sub).call;
/// VMUL.F64 `vmul.f64 Dd, Dn, Dm`: multiplies double-precision Dn and Dm into Dd under FPSCR.
pub const @"VMUL.F64_T1" = fp.BinaryDouble(.mul).call;
/// VNMUL.F64 `vnmul.f64 Dd, Dn, Dm`: negates the product of double-precision Dn and Dm into Dd under FPSCR.
pub const @"VNMUL.F64_T2" = fp.BinaryDouble(.nmul).call;
/// VDIV.F64 `vdiv.f64 Dd, Dn, Dm`: divides double-precision Dn and Dm into Dd under FPSCR.
pub const @"VDIV.F64_T1" = fp.BinaryDouble(.div).call;
/// VMOV.F64 `vmov.f64 Dd, Dm`: copies the double-precision Dm into Dd.
pub const @"VMOV.F64_reg_T1" = fp.UnaryDouble(.move).call;
/// VABS.F64 `vabs.f64 Dd, Dm`: clears the sign of the double-precision Dm into Dd.
pub const @"VABS.F64_T1" = fp.UnaryDouble(.abs).call;
/// VNEG.F64 `vneg.f64 Dd, Dm`: flips the sign of the double-precision Dm into Dd.
pub const @"VNEG.F64_T1" = fp.UnaryDouble(.negate).call;
/// VSQRT.F64 `vsqrt.f64 Dd, Dm`: takes the square root of the double-precision Dm into Dd.
pub const @"VSQRT.F64_T1" = fp.UnaryDouble(.root).call;
/// VMOV.F64 `vmov.f64 Dd, #imm`: Dd = the 8-bit modified-immediate constant as double.
pub const @"VMOV.F64_imm_T1" = fp.moveImmediateDouble;
/// VMLA.F64 `vmla.f64 Dd, Dn, Dm`: double-precision Dd += Dn*Dm.
pub const @"VMLA.F64_T1" = fp.FusedDouble(.mla).call;
/// VMLS.F64 `vmls.f64 Dd, Dn, Dm`: double-precision Dd -= Dn*Dm.
pub const @"VMLS.F64_T1" = fp.FusedDouble(.mls).call;
/// VNMLS.F64 `vnmls.f64 Dd, Dn, Dm`: double-precision Dd = Dn*Dm - Dd.
pub const @"VNMLS.F64_T1" = fp.FusedDouble(.nmls).call;
/// VNMLA.F64 `vnmla.f64 Dd, Dn, Dm`: double-precision Dd = -(Dn*Dm) - Dd.
pub const @"VNMLA.F64_T1" = fp.FusedDouble(.nmla).call;
/// VFMA.F64 `vfma.f64 Dd, Dn, Dm`: double-precision fused Dd += Dn*Dm.
pub const @"VFMA.F64_T1" = fp.FusedDouble(.fma).call;
/// VFMS.F64 `vfms.f64 Dd, Dn, Dm`: double-precision fused Dd -= Dn*Dm.
pub const @"VFMS.F64_T1" = fp.FusedDouble(.fms).call;
/// VFNMS.F64 `vfnms.f64 Dd, Dn, Dm`: double-precision fused Dd = Dn*Dm - Dd.
pub const @"VFNMS.F64_T1" = fp.FusedDouble(.fnms).call;
/// VFNMA.F64 `vfnma.f64 Dd, Dn, Dm`: double-precision fused Dd = -(Dn*Dm) - Dd.
pub const @"VFNMA.F64_T1" = fp.FusedDouble(.fnma).call;
/// VCMP.F64 `vcmp.f64 Dd, Dm`: double-precision compare into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F64_T1" = fp.CompareDouble(false).call;
/// VCMPE.F64 `vcmpe.f64 Dd, Dm`: double-precision compare into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F64_T1" = fp.CompareDouble(true).call;
/// VCMP.F64 `vcmp.f64 Dd, #0.0`: double compare with zero into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F64_T2" = fp.CompareZeroDouble(false).call;
/// VCMPE.F64 `vcmpe.f64 Dd, #0.0`: double compare with zero into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F64_T2" = fp.CompareZeroDouble(true).call;
/// VCVT.F64.U32 `vcvt.f64.u32 Dd, Sm`: unsigned int to double.
pub const @"VCVT.F64.U32_int_T1" = fp.WidenToDouble(.from_unsigned).call;
/// VCVT.F64.S32 `vcvt.f64.s32 Dd, Sm`: signed int to double.
pub const @"VCVT.F64.S32_int_T1" = fp.WidenToDouble(.from_signed).call;
/// VCVTR.U32.F64 `vcvtr.u32.f64 Sd, Dm`: double to unsigned int, FPSCR rounding.
pub const @"VCVTR.U32.F64_int_T1" = fp.NarrowFromDouble(.to_unsigned_round).call;
/// VCVT.U32.F64 `vcvt.u32.f64 Sd, Dm`: double to unsigned int, toward zero.
pub const @"VCVT.U32.F64_int_T1" = fp.NarrowFromDouble(.to_unsigned).call;
/// VCVTR.S32.F64 `vcvtr.s32.f64 Sd, Dm`: double to signed int, FPSCR rounding.
pub const @"VCVTR.S32.F64_int_T1" = fp.NarrowFromDouble(.to_signed_round).call;
/// VCVT.S32.F64 `vcvt.s32.f64 Sd, Dm`: double to signed int, toward zero.
pub const @"VCVT.S32.F64_int_T1" = fp.NarrowFromDouble(.to_signed).call;
/// VCVTB.F64.F16 `vcvtb.f64.f16 Dd, Sm`: low half to double.
pub const @"VCVTB.F64.F16_T1" = fp.WidenToDouble(.from_half_low).call;
/// VCVTT.F64.F16 `vcvtt.f64.f16 Dd, Sm`: high half to double.
pub const @"VCVTT.F64.F16_T1" = fp.WidenToDouble(.from_half_high).call;
/// VCVTB.F16.F64 `vcvtb.f16.f64 Sd, Dm`: double to half in the low half.
pub const @"VCVTB.F16.F64_T1" = fp.NarrowFromDouble(.to_half_low).call;
/// VCVTT.F16.F64 `vcvtt.f16.f64 Sd, Dm`: double to half in the high half.
pub const @"VCVTT.F16.F64_T1" = fp.NarrowFromDouble(.to_half_high).call;
/// VCVT.F64.F32 `vcvt.f64.f32 Dd, Sm`: widens single Sm to double Dd.
pub const @"VCVT.F64.F32_dp_T1" = fp.widenDouble;
/// VCVT.F32.F64 `vcvt.f32.f64 Sd, Dm`: narrows double Dm to single Sd under FPSCR rounding.
pub const @"VCVT.F32.F64_dp_T1" = fp.narrowDouble;
/// VCVT.F64.S16 `vcvt.f64.s16 Dd, Dd, #fbits`: signed 16-bit fixed-point to double, fbits binary places, in place.
pub const @"VCVT.F64.S16_fix_T1" = fp.FixedDouble(false, true, 16).call;
/// VCVT.F64.S32 `vcvt.f64.s32 Dd, Dd, #fbits`: signed 32-bit fixed-point to double, fbits binary places, in place.
pub const @"VCVT.F64.S32_fix_T1" = fp.FixedDouble(false, true, 32).call;
/// VCVT.F64.U16 `vcvt.f64.u16 Dd, Dd, #fbits`: unsigned 16-bit fixed-point to double, fbits binary places, in place.
pub const @"VCVT.F64.U16_fix_T1" = fp.FixedDouble(false, false, 16).call;
/// VCVT.F64.U32 `vcvt.f64.u32 Dd, Dd, #fbits`: unsigned 32-bit fixed-point to double, fbits binary places, in place.
pub const @"VCVT.F64.U32_fix_T1" = fp.FixedDouble(false, false, 32).call;
/// VCVT.S16.F64 `vcvt.s16.f64 Dd, Dd, #fbits`: double to signed 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S16.F64_fix_T1" = fp.FixedDouble(true, true, 16).call;
/// VCVT.S32.F64 `vcvt.s32.f64 Dd, Dd, #fbits`: double to signed 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S32.F64_fix_T1" = fp.FixedDouble(true, true, 32).call;
/// VCVT.U16.F64 `vcvt.u16.f64 Dd, Dd, #fbits`: double to unsigned 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U16.F64_fix_T1" = fp.FixedDouble(true, false, 16).call;
/// VCVT.U32.F64 `vcvt.u32.f64 Dd, Dd, #fbits`: double to unsigned 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U32.F64_fix_T1" = fp.FixedDouble(true, false, 32).call;
/// VMAXNM.F64 `vmaxnm.f64 Dd, Dn, Dm`: IEEE maxNum of doubles Dn and Dm into Dd.
pub const @"VMAXNM.F64_T1" = fp.ExtremumDouble(true).call;
/// VMINNM.F64 `vminnm.f64 Dd, Dn, Dm`: IEEE minNum of doubles Dn and Dm into Dd.
pub const @"VMINNM.F64_T1" = fp.ExtremumDouble(false).call;
/// VRINTA.F64 `vrinta.f64 Dd, Dm`: rounds double Dm to an integral value, ties away from zero.
pub const @"VRINTA.F64_T1" = fp.RoundDouble(.away).call;
/// VRINTN.F64 `vrintn.f64 Dd, Dm`: rounds double Dm to an integral value, ties to even.
pub const @"VRINTN.F64_T1" = fp.RoundDouble(.even).call;
/// VRINTP.F64 `vrintp.f64 Dd, Dm`: rounds double Dm to an integral value, toward +inf.
pub const @"VRINTP.F64_T1" = fp.RoundDouble(.plus).call;
/// VRINTM.F64 `vrintm.f64 Dd, Dm`: rounds double Dm to an integral value, toward -inf.
pub const @"VRINTM.F64_T1" = fp.RoundDouble(.minus).call;
/// VRINTZ.F64 `vrintz.f64 Dd, Dm`: rounds double Dm to an integral value, toward zero.
pub const @"VRINTZ.F64_T1" = fp.RoundDouble(.zero).call;
/// VRINTR.F64 `vrintr.f64 Dd, Dm`: rounds double Dm to an integral value, FPSCR rounding mode.
pub const @"VRINTR.F64_T1" = fp.RoundDouble(.current).call;
/// VRINTX.F64 `vrintx.f64 Dd, Dm`: rounds double Dm to an integral value, FPSCR mode, inexact raised.
pub const @"VRINTX.F64_T1" = fp.RoundDouble(.exact).call;
/// VCVTA.S32.F64 `vcvta.s32.f64 Sd, Dm`: double Dm to signed int, ties away from zero.
pub const @"VCVTA.S32.F64_T1" = fp.FixDouble(.away, true).call;
/// VCVTA.U32.F64 `vcvta.u32.f64 Sd, Dm`: double Dm to unsigned int, ties away from zero.
pub const @"VCVTA.U32.F64_T1" = fp.FixDouble(.away, false).call;
/// VCVTN.S32.F64 `vcvtn.s32.f64 Sd, Dm`: double Dm to signed int, ties to even.
pub const @"VCVTN.S32.F64_T1" = fp.FixDouble(.even, true).call;
/// VCVTN.U32.F64 `vcvtn.u32.f64 Sd, Dm`: double Dm to unsigned int, ties to even.
pub const @"VCVTN.U32.F64_T1" = fp.FixDouble(.even, false).call;
/// VCVTP.S32.F64 `vcvtp.s32.f64 Sd, Dm`: double Dm to signed int, toward +inf.
pub const @"VCVTP.S32.F64_T1" = fp.FixDouble(.plus, true).call;
/// VCVTP.U32.F64 `vcvtp.u32.f64 Sd, Dm`: double Dm to unsigned int, toward +inf.
pub const @"VCVTP.U32.F64_T1" = fp.FixDouble(.plus, false).call;
/// VCVTM.S32.F64 `vcvtm.s32.f64 Sd, Dm`: double Dm to signed int, toward -inf.
pub const @"VCVTM.S32.F64_T1" = fp.FixDouble(.minus, true).call;
/// VCVTM.U32.F64 `vcvtm.u32.f64 Sd, Dm`: double Dm to unsigned int, toward -inf.
pub const @"VCVTM.U32.F64_T1" = fp.FixDouble(.minus, false).call;
/// VSELEQ.F64 `vseleq.f64 Dd, Dn, Dm`: Dd = Dn when EQ holds, else Dm, no flags read from FPSCR.
pub const @"VSELEQ.F64_T1" = fp.SelectDouble(0).call;
/// VSELVS.F64 `vselvs.f64 Dd, Dn, Dm`: Dd = Dn when VS holds, else Dm, no flags read from FPSCR.
pub const @"VSELVS.F64_T1" = fp.SelectDouble(6).call;
/// VSELGE.F64 `vselge.f64 Dd, Dn, Dm`: Dd = Dn when GE holds, else Dm, no flags read from FPSCR.
pub const @"VSELGE.F64_T1" = fp.SelectDouble(10).call;
/// VSELGT.F64 `vselgt.f64 Dd, Dn, Dm`: Dd = Dn when GT holds, else Dm, no flags read from FPSCR.
pub const @"VSELGT.F64_T1" = fp.SelectDouble(12).call;
/// VADD.F16 `vadd.f16 Sd, Sn, Sm`: adds half-precision Sn and Sm into Sd under FPSCR.
pub const @"VADD.F16_T2" = fp.Binary(.add, f16).call;
/// VSUB.F16 `vsub.f16 Sd, Sn, Sm`: subtracts half-precision Sn and Sm into Sd under FPSCR.
pub const @"VSUB.F16_T2" = fp.Binary(.sub, f16).call;
/// VMUL.F16 `vmul.f16 Sd, Sn, Sm`: multiplies half-precision Sn and Sm into Sd under FPSCR.
pub const @"VMUL.F16_T2" = fp.Binary(.mul, f16).call;
/// VNMUL.F16 `vnmul.f16 Sd, Sn, Sm`: negates the product of half-precision Sn and Sm into Sd under FPSCR.
pub const @"VNMUL.F16_T2" = fp.Binary(.nmul, f16).call;
/// VDIV.F16 `vdiv.f16 Sd, Sn, Sm`: divides half-precision Sn and Sm into Sd under FPSCR.
pub const @"VDIV.F16_T1" = fp.Binary(.div, f16).call;
/// VMLA.F16 `vmla.f16 Sd, Sn, Sm`: half-precision Sd += Sn*Sm.
pub const @"VMLA.F16_T2" = fp.Fused(.mla, f16).call;
/// VMLS.F16 `vmls.f16 Sd, Sn, Sm`: half-precision Sd -= Sn*Sm.
pub const @"VMLS.F16_T2" = fp.Fused(.mls, f16).call;
/// VNMLS.F16 `vnmls.f16 Sd, Sn, Sm`: half-precision Sd = Sn*Sm - Sd.
pub const @"VNMLS.F16_T1" = fp.Fused(.nmls, f16).call;
/// VNMLA.F16 `vnmla.f16 Sd, Sn, Sm`: half-precision Sd = -(Sn*Sm) - Sd.
pub const @"VNMLA.F16_T1" = fp.Fused(.nmla, f16).call;
/// VFMA.F16 `vfma.f16 Sd, Sn, Sm`: half-precision fused Sd += Sn*Sm.
pub const @"VFMA.F16_T2" = fp.Fused(.fma, f16).call;
/// VFMS.F16 `vfms.f16 Sd, Sn, Sm`: half-precision fused Sd -= Sn*Sm.
pub const @"VFMS.F16_T2" = fp.Fused(.fms, f16).call;
/// VFNMS.F16 `vfnms.f16 Sd, Sn, Sm`: half-precision fused Sd = Sn*Sm - Sd.
pub const @"VFNMS.F16_T1" = fp.Fused(.fnms, f16).call;
/// VFNMA.F16 `vfnma.f16 Sd, Sn, Sm`: half-precision fused Sd = -(Sn*Sm) - Sd.
pub const @"VFNMA.F16_T1" = fp.Fused(.fnma, f16).call;
/// VABS.F16 `vabs.f16 Sd, Sm`: clears the sign of the half-precision Sm into Sd.
pub const @"VABS.F16_T2" = fp.Unary(.abs, f16).call;
/// VNEG.F16 `vneg.f16 Sd, Sm`: flips the sign of the half-precision Sm into Sd.
pub const @"VNEG.F16_T2" = fp.Unary(.negate, f16).call;
/// VSQRT.F16 `vsqrt.f16 Sd, Sm`: takes the square root of the half-precision Sm into Sd.
pub const @"VSQRT.F16_T1" = fp.Unary(.root, f16).call;
/// VCMP.F16 `vcmp.f16 Sd, Sm`: half-precision compare into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F16_T1" = fp.Compare(false, f16).call;
/// VCMPE.F16 `vcmpe.f16 Sd, Sm`: half-precision compare into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F16_T1" = fp.Compare(true, f16).call;
/// VCMP.F16 `vcmp.f16 Sd, #0.0`: half-precision compare with zero into FPSCR NZCV, quiet NaNs pass.
pub const @"VCMP.F16_T2" = fp.CompareZero(false, f16).call;
/// VCMPE.F16 `vcmpe.f16 Sd, #0.0`: half-precision compare with zero into FPSCR NZCV, signalling on any NaN.
pub const @"VCMPE.F16_T2" = fp.CompareZero(true, f16).call;
/// VMOV.F16 `vmov.f16 Sd, #imm`: Sd = the 8-bit modified-immediate constant as half-precision.
pub const @"VMOV.F16_imm_T2" = fp.MoveImmediate(f16).call;
/// VCVT.F16.U32 `vcvt.f16.u32 Sd, Sm`: half-precision unsigned int to float.
pub const @"VCVT.F16.U32_int_T1" = fp.Convert(.from_unsigned, f16).call;
/// VCVT.F16.S32 `vcvt.f16.s32 Sd, Sm`: half-precision signed int to float.
pub const @"VCVT.F16.S32_int_T1" = fp.Convert(.from_signed, f16).call;
/// VCVTR.U32.F16 `vcvtr.u32.f16 Sd, Sm`: half-precision float to unsigned int, FPSCR rounding.
pub const @"VCVTR.U32.F16_T1" = fp.Convert(.to_unsigned_round, f16).call;
/// VCVT.U32.F16 `vcvt.u32.f16 Sd, Sm`: half-precision float to unsigned int, toward zero.
pub const @"VCVT.U32.F16_int_T1" = fp.Convert(.to_unsigned, f16).call;
/// VCVTR.S32.F16 `vcvtr.s32.f16 Sd, Sm`: half-precision float to signed int, FPSCR rounding.
pub const @"VCVTR.S32.F16_T1" = fp.Convert(.to_signed_round, f16).call;
/// VCVT.S32.F16 `vcvt.s32.f16 Sd, Sm`: half-precision float to signed int, toward zero.
pub const @"VCVT.S32.F16_int_T1" = fp.Convert(.to_signed, f16).call;
/// VCVT.F16.S16 `vcvt.f16.s16 Sd, Sd, #fbits`: signed 16-bit fixed-point to half float, fbits binary places, in place.
pub const @"VCVT.F16.S16_fix_T1" = fp.Fixed(false, true, 16, f16).call;
/// VCVT.F16.S32 `vcvt.f16.s32 Sd, Sd, #fbits`: signed 32-bit fixed-point to half float, fbits binary places, in place.
pub const @"VCVT.F16.S32_fix_T1" = fp.Fixed(false, true, 32, f16).call;
/// VCVT.F16.U16 `vcvt.f16.u16 Sd, Sd, #fbits`: unsigned 16-bit fixed-point to half float, fbits binary places, in place.
pub const @"VCVT.F16.U16_fix_T1" = fp.Fixed(false, false, 16, f16).call;
/// VCVT.F16.U32 `vcvt.f16.u32 Sd, Sd, #fbits`: unsigned 32-bit fixed-point to half float, fbits binary places, in place.
pub const @"VCVT.F16.U32_fix_T1" = fp.Fixed(false, false, 32, f16).call;
/// VCVT.S16.F16 `vcvt.s16.f16 Sd, Sd, #fbits`: half float to signed 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S16.F16_fix_T1" = fp.Fixed(true, true, 16, f16).call;
/// VCVT.S32.F16 `vcvt.s32.f16 Sd, Sd, #fbits`: half float to signed 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.S32.F16_fix_T1" = fp.Fixed(true, true, 32, f16).call;
/// VCVT.U16.F16 `vcvt.u16.f16 Sd, Sd, #fbits`: half float to unsigned 16-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U16.F16_fix_T1" = fp.Fixed(true, false, 16, f16).call;
/// VCVT.U32.F16 `vcvt.u32.f16 Sd, Sd, #fbits`: half float to unsigned 32-bit fixed-point, fbits binary places, in place.
pub const @"VCVT.U32.F16_fix_T1" = fp.Fixed(true, false, 32, f16).call;
/// VMAXNM.F16 `vmaxnm.f16 Sd, Sn, Sm`: IEEE maxNum of half-precision Sn and Sm into Sd.
pub const @"VMAXNM.F16_T2" = fp.Extremum(true, f16).call;
/// VMINNM.F16 `vminnm.f16 Sd, Sn, Sm`: IEEE minNum of half-precision Sn and Sm into Sd.
pub const @"VMINNM.F16_T2" = fp.Extremum(false, f16).call;
/// VRINTA.F16 `vrinta.f16 Sd, Sm`: rounds half-precision Sm to an integral value, ties away from zero.
pub const @"VRINTA.F16_T1" = fp.Round(.away, f16).call;
/// VRINTN.F16 `vrintn.f16 Sd, Sm`: rounds half-precision Sm to an integral value, ties to even.
pub const @"VRINTN.F16_T1" = fp.Round(.even, f16).call;
/// VRINTP.F16 `vrintp.f16 Sd, Sm`: rounds half-precision Sm to an integral value, toward +inf.
pub const @"VRINTP.F16_T1" = fp.Round(.plus, f16).call;
/// VRINTM.F16 `vrintm.f16 Sd, Sm`: rounds half-precision Sm to an integral value, toward -inf.
pub const @"VRINTM.F16_T1" = fp.Round(.minus, f16).call;
/// VRINTZ.F16 `vrintz.f16 Sd, Sm`: rounds half-precision Sm to an integral value, toward zero.
pub const @"VRINTZ.F16_T1" = fp.Round(.zero, f16).call;
/// VRINTR.F16 `vrintr.f16 Sd, Sm`: rounds half-precision Sm to an integral value, FPSCR rounding mode.
pub const @"VRINTR.F16_T1" = fp.Round(.current, f16).call;
/// VRINTX.F16 `vrintx.f16 Sd, Sm`: rounds half-precision Sm to an integral value, FPSCR mode, inexact raised.
pub const @"VRINTX.F16_T1" = fp.Round(.exact, f16).call;
/// VCVTA.S32.F16 `vcvta.s32.f16 Sd, Sm`: half-precision Sm to signed int, ties away from zero.
pub const @"VCVTA.S32.F16_T1" = fp.Fix(.away, true, f16).call;
/// VCVTA.U32.F16 `vcvta.u32.f16 Sd, Sm`: half-precision Sm to unsigned int, ties away from zero.
pub const @"VCVTA.U32.F16_T1" = fp.Fix(.away, false, f16).call;
/// VCVTN.S32.F16 `vcvtn.s32.f16 Sd, Sm`: half-precision Sm to signed int, ties to even.
pub const @"VCVTN.S32.F16_T1" = fp.Fix(.even, true, f16).call;
/// VCVTN.U32.F16 `vcvtn.u32.f16 Sd, Sm`: half-precision Sm to unsigned int, ties to even.
pub const @"VCVTN.U32.F16_T1" = fp.Fix(.even, false, f16).call;
/// VCVTP.S32.F16 `vcvtp.s32.f16 Sd, Sm`: half-precision Sm to signed int, toward +inf.
pub const @"VCVTP.S32.F16_T1" = fp.Fix(.plus, true, f16).call;
/// VCVTP.U32.F16 `vcvtp.u32.f16 Sd, Sm`: half-precision Sm to unsigned int, toward +inf.
pub const @"VCVTP.U32.F16_T1" = fp.Fix(.plus, false, f16).call;
/// VCVTM.S32.F16 `vcvtm.s32.f16 Sd, Sm`: half-precision Sm to signed int, toward -inf.
pub const @"VCVTM.S32.F16_T1" = fp.Fix(.minus, true, f16).call;
/// VCVTM.U32.F16 `vcvtm.u32.f16 Sd, Sm`: half-precision Sm to unsigned int, toward -inf.
pub const @"VCVTM.U32.F16_T1" = fp.Fix(.minus, false, f16).call;
/// VMOV.F16 `vmov.f16 Sn, Rt`: Sn = Rt's bits, half form.
pub const @"VMOV.F16_gpr_hp_T1_op0" = fp.MoveCore(false, f16).call;
/// VMOV.F16 `vmov.f16 Rt, Sn`: Rt = Sn's bits, half form.
pub const @"VMOV.F16_gpr_hp_T1_op1" = fp.MoveCore(true, f16).call;
/// VINS.F16 `vins.f16 Sd, Sm`: copies Sm's low half into the top half of Sd.
pub const @"VINS.F16_T1" = fp.Halves(true).call;
/// VMOVX.F16 `vmovx.f16 Sd, Sm`: Sd = Sm's top half moved down, upper half zeroed.
pub const @"VMOVX.F16_T1" = fp.Halves(false).call;
/// VLDR.16 `vldr.16 Sd, [Rn, #±imm*2]`: halfword load into Sd at Rn plus or minus the scaled offset.
pub const @"VLDR.16_T3" = fp.LoadStore(true, f16).call;
/// VSTR.16 `vstr.16 Sd, [Rn, #±imm*2]`: halfword store of Sd at Rn plus or minus the scaled offset.
pub const @"VSTR.16_T3" = fp.LoadStore(false, f16).call;
/// VSELEQ.F16 `vseleq.f16 Sd, Sn, Sm`: Sd = Sn when EQ holds, else Sm, half-precision.
pub const @"VSELEQ.F16_T1" = fp.Select(0, f16).call;
/// VSELVS.F16 `vselvs.f16 Sd, Sn, Sm`: Sd = Sn when VS holds, else Sm, half-precision.
pub const @"VSELVS.F16_T1" = fp.Select(6, f16).call;
/// VSELGE.F16 `vselge.f16 Sd, Sn, Sm`: Sd = Sn when GE holds, else Sm, half-precision.
pub const @"VSELGE.F16_T1" = fp.Select(10, f16).call;
/// VSELGT.F16 `vselgt.f16 Sd, Sn, Sm`: Sd = Sn when GT holds, else Sm, half-precision.
pub const @"VSELGT.F16_T1" = fp.Select(12, f16).call;
/// VMAXNM.F32 `vmaxnm.f32 Sd, Sn, Sm`: IEEE maxNum of single-precision Sn and Sm into Sd.
pub const @"VMAXNM.F32_T1" = fp.Extremum(true, f32).call;
/// VMINNM.F32 `vminnm.f32 Sd, Sn, Sm`: IEEE minNum of single-precision Sn and Sm into Sd.
pub const @"VMINNM.F32_T1" = fp.Extremum(false, f32).call;
/// VRINTA.F32 `vrinta.f32 Sd, Sm`: rounds single-precision Sm to an integral value, ties away from zero.
pub const @"VRINTA.F32_T1" = fp.Round(.away, f32).call;
/// VRINTN.F32 `vrintn.f32 Sd, Sm`: rounds single-precision Sm to an integral value, ties to even.
pub const @"VRINTN.F32_T1" = fp.Round(.even, f32).call;
/// VRINTP.F32 `vrintp.f32 Sd, Sm`: rounds single-precision Sm to an integral value, toward +inf.
pub const @"VRINTP.F32_T1" = fp.Round(.plus, f32).call;
/// VRINTM.F32 `vrintm.f32 Sd, Sm`: rounds single-precision Sm to an integral value, toward -inf.
pub const @"VRINTM.F32_T1" = fp.Round(.minus, f32).call;
/// VRINTZ.F32 `vrintz.f32 Sd, Sm`: rounds single-precision Sm to an integral value, toward zero.
pub const @"VRINTZ.F32_T1" = fp.Round(.zero, f32).call;
/// VRINTR.F32 `vrintr.f32 Sd, Sm`: rounds single-precision Sm to an integral value, FPSCR rounding mode.
pub const @"VRINTR.F32_T1" = fp.Round(.current, f32).call;
/// VRINTX.F32 `vrintx.f32 Sd, Sm`: rounds single-precision Sm to an integral value, FPSCR mode, inexact raised.
pub const @"VRINTX.F32_T1" = fp.Round(.exact, f32).call;
/// VCVTA.S32.F32 `vcvta.s32.f32 Sd, Sm`: single-precision Sm to signed int, ties away from zero.
pub const @"VCVTA.S32.F32_T1" = fp.Fix(.away, true, f32).call;
/// VCVTA.U32.F32 `vcvta.u32.f32 Sd, Sm`: single-precision Sm to unsigned int, ties away from zero.
pub const @"VCVTA.U32.F32_T1" = fp.Fix(.away, false, f32).call;
/// VCVTN.S32.F32 `vcvtn.s32.f32 Sd, Sm`: single-precision Sm to signed int, ties to even.
pub const @"VCVTN.S32.F32_T1" = fp.Fix(.even, true, f32).call;
/// VCVTN.U32.F32 `vcvtn.u32.f32 Sd, Sm`: single-precision Sm to unsigned int, ties to even.
pub const @"VCVTN.U32.F32_T1" = fp.Fix(.even, false, f32).call;
/// VCVTP.S32.F32 `vcvtp.s32.f32 Sd, Sm`: single-precision Sm to signed int, toward +inf.
pub const @"VCVTP.S32.F32_T1" = fp.Fix(.plus, true, f32).call;
/// VCVTP.U32.F32 `vcvtp.u32.f32 Sd, Sm`: single-precision Sm to unsigned int, toward +inf.
pub const @"VCVTP.U32.F32_T1" = fp.Fix(.plus, false, f32).call;
/// VCVTM.S32.F32 `vcvtm.s32.f32 Sd, Sm`: single-precision Sm to signed int, toward -inf.
pub const @"VCVTM.S32.F32_T1" = fp.Fix(.minus, true, f32).call;
/// VCVTM.U32.F32 `vcvtm.u32.f32 Sd, Sm`: single-precision Sm to unsigned int, toward -inf.
pub const @"VCVTM.U32.F32_T1" = fp.Fix(.minus, false, f32).call;
/// VSELEQ.F32 `vseleq.f32 Sd, Sn, Sm`: Sd = Sn when EQ holds, else Sm, single-precision.
pub const @"VSELEQ.F32_T1" = fp.Select(0, f32).call;
/// VSELVS.F32 `vselvs.f32 Sd, Sn, Sm`: Sd = Sn when VS holds, else Sm, single-precision.
pub const @"VSELVS.F32_T1" = fp.Select(6, f32).call;
/// VSELGE.F32 `vselge.f32 Sd, Sn, Sm`: Sd = Sn when GE holds, else Sm, single-precision.
pub const @"VSELGE.F32_T1" = fp.Select(10, f32).call;
/// VSELGT.F32 `vselgt.f32 Sd, Sn, Sm`: Sd = Sn when GT holds, else Sm, single-precision.
pub const @"VSELGT.F32_T1" = fp.Select(12, f32).call;
/// VMRS `vmrs Rt, fpscr_nzcvqc`: Rt = NZCVQC, after the floating-point check, C2.4.406.
pub const VMRS_T1_fpscr_nzcvqc = fp.SystemMove(true, .nzcvqc).call;
/// VMSR `vmsr fpscr_nzcvqc, Rt`: NZCVQC = Rt, after the floating-point check, C2.4.406.
pub const VMSR_T1_fpscr_nzcvqc = fp.SystemMove(false, .nzcvqc).call;
/// VMRS `vmrs Rt, fpcxt_ns`: Rt = FPCXT_NS, C2.4.406: preserves a live lazy context, never creates one.
pub const VMRS_T1_fpcxt_ns = fp.SystemMove(true, .fpcxt_ns).call;
/// VMSR `vmsr fpcxt_ns, Rt`: FPCXT_NS = Rt, C2.4.406: preserves a live lazy context, never creates one.
pub const VMSR_T1_fpcxt_ns = fp.SystemMove(false, .fpcxt_ns).call;
/// VMRS `vmrs Rt, fpcxt_s`: Rt = FPCXT_S, C2.4.406: preserves a live lazy context, never creates one.
pub const VMRS_T1_fpcxt_s = fp.SystemMove(true, .fpcxt_s).call;
/// VMSR `vmsr fpcxt_s, Rt`: FPCXT_S = Rt, C2.4.406: preserves a live lazy context, never creates one.
pub const VMSR_T1_fpcxt_s = fp.SystemMove(false, .fpcxt_s).call;
/// VLDR `vldr fpscr, [Rn, #±imm*4]{!}`: loads FPSCR from Rn±imm*4, writeback per W.
pub const VLDR_sysreg_T1_fpscr_pre = fp.SystemFixed(true, .fpscr).call;
/// VSTR `vstr fpscr, [Rn, #±imm*4]{!}`: stores FPSCR at Rn±imm*4, writeback per W.
pub const VSTR_sysreg_T1_fpscr_pre = fp.SystemFixed(false, .fpscr).call;
/// VLDR `vldr fpscr_nzcvqc, [Rn, #±imm*4]{!}`: loads NZCVQC from Rn±imm*4, writeback per W.
pub const VLDR_sysreg_T1_fpscr_nzcvqc_pre = fp.SystemFixed(true, .nzcvqc).call;
/// VSTR `vstr fpscr_nzcvqc, [Rn, #±imm*4]{!}`: stores NZCVQC at Rn±imm*4, writeback per W.
pub const VSTR_sysreg_T1_fpscr_nzcvqc_pre = fp.SystemFixed(false, .nzcvqc).call;
/// VLDR `vldr fpcxt, [Rn, #±imm*4]{!}`: loads FPCXT_NS or FPCXT_S from Rn±imm*4, bank by bit, writeback per W.
pub const VLDR_sysreg_T1_fpcxt_pre = fp.SystemBanked(true).call;
/// VSTR `vstr fpcxt, [Rn, #±imm*4]{!}`: stores FPCXT_NS or FPCXT_S at Rn±imm*4, bank by bit, writeback per W.
pub const VSTR_sysreg_T1_fpcxt_pre = fp.SystemBanked(false).call;
/// VLDR `vldr fpscr, [Rn], #±imm*4`: loads FPSCR from Rn, then Rn moves by the signed imm*4.
pub const VLDR_sysreg_T1_fpscr_post = fp.SystemFixedPost(true, .fpscr).call;
/// VSTR `vstr fpscr, [Rn], #±imm*4`: stores FPSCR at Rn, then Rn moves by the signed imm*4.
pub const VSTR_sysreg_T1_fpscr_post = fp.SystemFixedPost(false, .fpscr).call;
/// VLDR `vldr fpscr_nzcvqc, [Rn], #±imm*4`: loads NZCVQC from Rn, then Rn moves by the signed imm*4.
pub const VLDR_sysreg_T1_fpscr_nzcvqc_post = fp.SystemFixedPost(true, .nzcvqc).call;
/// VSTR `vstr fpscr_nzcvqc, [Rn], #±imm*4`: stores NZCVQC at Rn, then Rn moves by the signed imm*4.
pub const VSTR_sysreg_T1_fpscr_nzcvqc_post = fp.SystemFixedPost(false, .nzcvqc).call;
/// VLDR `vldr fpcxt, [Rn], #±imm*4`: loads FPCXT_NS or FPCXT_S from Rn, then Rn moves by the signed imm*4.
pub const VLDR_sysreg_T1_fpcxt_post = fp.SystemBankedPost(true).call;
/// VSTR `vstr fpcxt, [Rn], #±imm*4`: stores FPCXT_NS or FPCXT_S at Rn, then Rn moves by the signed imm*4.
pub const VSTR_sysreg_T1_fpcxt_post = fp.SystemBankedPost(false).call;
/// VLSTM `vlstm Rn`: saves the Secure FP context at Rn, lazily where the host allows.
pub const VLSTM_T1 = fp.Lazy(false).call;
/// VLLDM `vlldm Rn`: reloads the Secure FP context saved at Rn, or cancels a lazy save.
pub const VLLDM_T1 = fp.Lazy(true).call;
/// VSCCLRM `vscclrm {list}`: zeroes the listed single registers and VPR, Secure only.
pub const VSCCLRM_T2 = fp.Clear(false).call;
/// VSCCLRM `vscclrm {list}`: zeroes the listed double registers and VPR, Secure only.
pub const VSCCLRM_T1 = fp.Clear(true).call;
/// VADD.I8 `vadd.i8 Qd, Qn, Qm`: adds 16x8-bit lanes of Qn and Qm under the predicate.
pub const @"VADD.I8_vec_T1" = mve.Lanewise(.add, 8, true, false).call;
/// VSUB.I8 `vsub.i8 Qd, Qn, Qm`: subtracts 16x8-bit lanes of Qn and Qm under the predicate.
pub const @"VSUB.I8_vec_T1" = mve.Lanewise(.sub, 8, true, false).call;
/// VMUL.I8 `vmul.i8 Qd, Qn, Qm`: multiplies 16x8-bit lanes of Qn and Qm under the predicate.
pub const @"VMUL.I8_vec_T1" = mve.Lanewise(.mul, 8, true, false).call;
/// VADD.I16 `vadd.i16 Qd, Qn, Qm`: adds 8x16-bit lanes of Qn and Qm under the predicate.
pub const @"VADD.I16_vec_T1" = mve.Lanewise(.add, 16, true, false).call;
/// VSUB.I16 `vsub.i16 Qd, Qn, Qm`: subtracts 8x16-bit lanes of Qn and Qm under the predicate.
pub const @"VSUB.I16_vec_T1" = mve.Lanewise(.sub, 16, true, false).call;
/// VMUL.I16 `vmul.i16 Qd, Qn, Qm`: multiplies 8x16-bit lanes of Qn and Qm under the predicate.
pub const @"VMUL.I16_vec_T1" = mve.Lanewise(.mul, 16, true, false).call;
/// VADD.I32 `vadd.i32 Qd, Qn, Qm`: adds 4x32-bit lanes of Qn and Qm under the predicate.
pub const @"VADD.I32_vec_T1" = mve.Lanewise(.add, 32, true, false).call;
/// VSUB.I32 `vsub.i32 Qd, Qn, Qm`: subtracts 4x32-bit lanes of Qn and Qm under the predicate.
pub const @"VSUB.I32_vec_T1" = mve.Lanewise(.sub, 32, true, false).call;
/// VMUL.I32 `vmul.i32 Qd, Qn, Qm`: multiplies 4x32-bit lanes of Qn and Qm under the predicate.
pub const @"VMUL.I32_vec_T1" = mve.Lanewise(.mul, 32, true, false).call;
/// VAND `vand Qd, Qn, Qm`: ANDs 4x32-bit lanes of Qn and Qm under the predicate.
pub const VAND_T1 = mve.Lanewise(.bitand, 32, true, false).call;
/// VBIC `vbic Qd, Qn, Qm`: AND-NOTs 4x32-bit lanes of Qn and Qm under the predicate.
pub const VBIC_reg_T1 = mve.Lanewise(.bic, 32, true, false).call;
/// VORR `vorr Qd, Qn, Qm`: ORs 4x32-bit lanes of Qn and Qm under the predicate.
pub const VORR_T1 = mve.Lanewise(.orr, 32, true, false).call;
/// VORN `vorn Qd, Qn, Qm`: OR-NOTs 4x32-bit lanes of Qn and Qm under the predicate.
pub const VORN_T1 = mve.Lanewise(.orn, 32, true, false).call;
/// VEOR `veor Qd, Qn, Qm`: XORs 4x32-bit lanes of Qn and Qm under the predicate.
pub const VEOR_T1 = mve.Lanewise(.eor, 32, true, false).call;
/// VMIN.S8 `vmin.s8 Qd, Qn, Qm`: takes the minimum of 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMIN.S8_T1" = mve.Lanewise(.min, 8, true, false).call;
/// VMIN.S16 `vmin.s16 Qd, Qn, Qm`: takes the minimum of 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMIN.S16_T1" = mve.Lanewise(.min, 16, true, false).call;
/// VMIN.S32 `vmin.s32 Qd, Qn, Qm`: takes the minimum of 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMIN.S32_T1" = mve.Lanewise(.min, 32, true, false).call;
/// VMIN.U8 `vmin.u8 Qd, Qn, Qm`: takes the minimum of 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMIN.U8_T1" = mve.Lanewise(.min, 8, false, false).call;
/// VMIN.U16 `vmin.u16 Qd, Qn, Qm`: takes the minimum of 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMIN.U16_T1" = mve.Lanewise(.min, 16, false, false).call;
/// VMIN.U32 `vmin.u32 Qd, Qn, Qm`: takes the minimum of 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMIN.U32_T1" = mve.Lanewise(.min, 32, false, false).call;
/// VMAX.S8 `vmax.s8 Qd, Qn, Qm`: takes the maximum of 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMAX.S8_T1" = mve.Lanewise(.max, 8, true, false).call;
/// VMAX.S16 `vmax.s16 Qd, Qn, Qm`: takes the maximum of 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMAX.S16_T1" = mve.Lanewise(.max, 16, true, false).call;
/// VMAX.S32 `vmax.s32 Qd, Qn, Qm`: takes the maximum of 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VMAX.S32_T1" = mve.Lanewise(.max, 32, true, false).call;
/// VMAX.U8 `vmax.u8 Qd, Qn, Qm`: takes the maximum of 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMAX.U8_T1" = mve.Lanewise(.max, 8, false, false).call;
/// VMAX.U16 `vmax.u16 Qd, Qn, Qm`: takes the maximum of 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMAX.U16_T1" = mve.Lanewise(.max, 16, false, false).call;
/// VMAX.U32 `vmax.u32 Qd, Qn, Qm`: takes the maximum of 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VMAX.U32_T1" = mve.Lanewise(.max, 32, false, false).call;
/// VABD.S8 `vabd.s8 Qd, Qn, Qm`: takes the absolute difference of 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VABD.S8_T1" = mve.Lanewise(.abd, 8, true, false).call;
/// VABD.S16 `vabd.s16 Qd, Qn, Qm`: takes the absolute difference of 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VABD.S16_T1" = mve.Lanewise(.abd, 16, true, false).call;
/// VABD.S32 `vabd.s32 Qd, Qn, Qm`: takes the absolute difference of 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VABD.S32_T1" = mve.Lanewise(.abd, 32, true, false).call;
/// VABD.U8 `vabd.u8 Qd, Qn, Qm`: takes the absolute difference of 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VABD.U8_T1" = mve.Lanewise(.abd, 8, false, false).call;
/// VABD.U16 `vabd.u16 Qd, Qn, Qm`: takes the absolute difference of 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VABD.U16_T1" = mve.Lanewise(.abd, 16, false, false).call;
/// VABD.U32 `vabd.u32 Qd, Qn, Qm`: takes the absolute difference of 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VABD.U32_T1" = mve.Lanewise(.abd, 32, false, false).call;
/// VHADD.S8 `vhadd.s8 Qd, Qn, Qm`: halving-adds 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHADD.S8_T1" = mve.Lanewise(.hadd, 8, true, false).call;
/// VHADD.S16 `vhadd.s16 Qd, Qn, Qm`: halving-adds 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHADD.S16_T1" = mve.Lanewise(.hadd, 16, true, false).call;
/// VHADD.S32 `vhadd.s32 Qd, Qn, Qm`: halving-adds 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHADD.S32_T1" = mve.Lanewise(.hadd, 32, true, false).call;
/// VHADD.U8 `vhadd.u8 Qd, Qn, Qm`: halving-adds 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHADD.U8_T1" = mve.Lanewise(.hadd, 8, false, false).call;
/// VHADD.U16 `vhadd.u16 Qd, Qn, Qm`: halving-adds 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHADD.U16_T1" = mve.Lanewise(.hadd, 16, false, false).call;
/// VHADD.U32 `vhadd.u32 Qd, Qn, Qm`: halving-adds 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHADD.U32_T1" = mve.Lanewise(.hadd, 32, false, false).call;
/// VRHADD.S8 `vrhadd.s8 Qd, Qn, Qm`: rounding halving-adds 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VRHADD.S8_T1" = mve.Lanewise(.rhadd, 8, true, false).call;
/// VRHADD.S16 `vrhadd.s16 Qd, Qn, Qm`: rounding halving-adds 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VRHADD.S16_T1" = mve.Lanewise(.rhadd, 16, true, false).call;
/// VRHADD.S32 `vrhadd.s32 Qd, Qn, Qm`: rounding halving-adds 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VRHADD.S32_T1" = mve.Lanewise(.rhadd, 32, true, false).call;
/// VRHADD.U8 `vrhadd.u8 Qd, Qn, Qm`: rounding halving-adds 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VRHADD.U8_T1" = mve.Lanewise(.rhadd, 8, false, false).call;
/// VRHADD.U16 `vrhadd.u16 Qd, Qn, Qm`: rounding halving-adds 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VRHADD.U16_T1" = mve.Lanewise(.rhadd, 16, false, false).call;
/// VRHADD.U32 `vrhadd.u32 Qd, Qn, Qm`: rounding halving-adds 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VRHADD.U32_T1" = mve.Lanewise(.rhadd, 32, false, false).call;
/// VHSUB.S8 `vhsub.s8 Qd, Qn, Qm`: halving-subtracts 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHSUB.S8_T1" = mve.Lanewise(.hsub, 8, true, false).call;
/// VHSUB.S16 `vhsub.s16 Qd, Qn, Qm`: halving-subtracts 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHSUB.S16_T1" = mve.Lanewise(.hsub, 16, true, false).call;
/// VHSUB.S32 `vhsub.s32 Qd, Qn, Qm`: halving-subtracts 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VHSUB.S32_T1" = mve.Lanewise(.hsub, 32, true, false).call;
/// VHSUB.U8 `vhsub.u8 Qd, Qn, Qm`: halving-subtracts 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHSUB.U8_T1" = mve.Lanewise(.hsub, 8, false, false).call;
/// VHSUB.U16 `vhsub.u16 Qd, Qn, Qm`: halving-subtracts 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHSUB.U16_T1" = mve.Lanewise(.hsub, 16, false, false).call;
/// VHSUB.U32 `vhsub.u32 Qd, Qn, Qm`: halving-subtracts 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VHSUB.U32_T1" = mve.Lanewise(.hsub, 32, false, false).call;
/// VQADD.S8 `vqadd.s8 Qd, Qn, Qm`: saturating-adds 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQADD.S8_T1" = mve.Lanewise(.qadd, 8, true, false).call;
/// VQADD.S16 `vqadd.s16 Qd, Qn, Qm`: saturating-adds 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQADD.S16_T1" = mve.Lanewise(.qadd, 16, true, false).call;
/// VQADD.S32 `vqadd.s32 Qd, Qn, Qm`: saturating-adds 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQADD.S32_T1" = mve.Lanewise(.qadd, 32, true, false).call;
/// VQADD.U8 `vqadd.u8 Qd, Qn, Qm`: saturating-adds 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQADD.U8_T1" = mve.Lanewise(.qadd, 8, false, false).call;
/// VQADD.U16 `vqadd.u16 Qd, Qn, Qm`: saturating-adds 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQADD.U16_T1" = mve.Lanewise(.qadd, 16, false, false).call;
/// VQADD.U32 `vqadd.u32 Qd, Qn, Qm`: saturating-adds 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQADD.U32_T1" = mve.Lanewise(.qadd, 32, false, false).call;
/// VQSUB.S8 `vqsub.s8 Qd, Qn, Qm`: saturating-subtracts 16x8-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQSUB.S8_T1" = mve.Lanewise(.qsub, 8, true, false).call;
/// VQSUB.S16 `vqsub.s16 Qd, Qn, Qm`: saturating-subtracts 8x16-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQSUB.S16_T1" = mve.Lanewise(.qsub, 16, true, false).call;
/// VQSUB.S32 `vqsub.s32 Qd, Qn, Qm`: saturating-subtracts 4x32-bit signed lanes of Qn and Qm under the predicate.
pub const @"VQSUB.S32_T1" = mve.Lanewise(.qsub, 32, true, false).call;
/// VQSUB.U8 `vqsub.u8 Qd, Qn, Qm`: saturating-subtracts 16x8-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQSUB.U8_T1" = mve.Lanewise(.qsub, 8, false, false).call;
/// VQSUB.U16 `vqsub.u16 Qd, Qn, Qm`: saturating-subtracts 8x16-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQSUB.U16_T1" = mve.Lanewise(.qsub, 16, false, false).call;
/// VQSUB.U32 `vqsub.u32 Qd, Qn, Qm`: saturating-subtracts 4x32-bit unsigned lanes of Qn and Qm under the predicate.
pub const @"VQSUB.U32_T1" = mve.Lanewise(.qsub, 32, false, false).call;
/// VADD.I8 `vadd.i8 Qd, Qn, Rt`: adds 16x8-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VADD.I8_vec_T2" = mve.Lanewise(.add, 8, true, true).call;
/// VADD.I16 `vadd.i16 Qd, Qn, Rt`: adds 8x16-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VADD.I16_vec_T2" = mve.Lanewise(.add, 16, true, true).call;
/// VADD.I32 `vadd.i32 Qd, Qn, Rt`: adds 4x32-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VADD.I32_vec_T2" = mve.Lanewise(.add, 32, true, true).call;
/// VSUB.I8 `vsub.i8 Qd, Qn, Rt`: subtracts 16x8-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VSUB.I8_vec_T2" = mve.Lanewise(.sub, 8, true, true).call;
/// VSUB.I16 `vsub.i16 Qd, Qn, Rt`: subtracts 8x16-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VSUB.I16_vec_T2" = mve.Lanewise(.sub, 16, true, true).call;
/// VSUB.I32 `vsub.i32 Qd, Qn, Rt`: subtracts 4x32-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VSUB.I32_vec_T2" = mve.Lanewise(.sub, 32, true, true).call;
/// VMUL.I8 `vmul.i8 Qd, Qn, Rt`: multiplies 16x8-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VMUL.I8_vec_T2" = mve.Lanewise(.mul, 8, true, true).call;
/// VMUL.I16 `vmul.i16 Qd, Qn, Rt`: multiplies 8x16-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VMUL.I16_vec_T2" = mve.Lanewise(.mul, 16, true, true).call;
/// VMUL.I32 `vmul.i32 Qd, Qn, Rt`: multiplies 4x32-bit lanes of Qn and Rt broadcast under the predicate.
pub const @"VMUL.I32_vec_T2" = mve.Lanewise(.mul, 32, true, true).call;
/// VQADD.S8 `vqadd.s8 Qd, Qn, Rt`: saturating-adds 16x8-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.S8_T2" = mve.Lanewise(.qadd, 8, true, true).call;
/// VQADD.S16 `vqadd.s16 Qd, Qn, Rt`: saturating-adds 8x16-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.S16_T2" = mve.Lanewise(.qadd, 16, true, true).call;
/// VQADD.S32 `vqadd.s32 Qd, Qn, Rt`: saturating-adds 4x32-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.S32_T2" = mve.Lanewise(.qadd, 32, true, true).call;
/// VQADD.U8 `vqadd.u8 Qd, Qn, Rt`: saturating-adds 16x8-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.U8_T2" = mve.Lanewise(.qadd, 8, false, true).call;
/// VQADD.U16 `vqadd.u16 Qd, Qn, Rt`: saturating-adds 8x16-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.U16_T2" = mve.Lanewise(.qadd, 16, false, true).call;
/// VQADD.U32 `vqadd.u32 Qd, Qn, Rt`: saturating-adds 4x32-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQADD.U32_T2" = mve.Lanewise(.qadd, 32, false, true).call;
/// VQSUB.S8 `vqsub.s8 Qd, Qn, Rt`: saturating-subtracts 16x8-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.S8_T2" = mve.Lanewise(.qsub, 8, true, true).call;
/// VQSUB.S16 `vqsub.s16 Qd, Qn, Rt`: saturating-subtracts 8x16-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.S16_T2" = mve.Lanewise(.qsub, 16, true, true).call;
/// VQSUB.S32 `vqsub.s32 Qd, Qn, Rt`: saturating-subtracts 4x32-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.S32_T2" = mve.Lanewise(.qsub, 32, true, true).call;
/// VQSUB.U8 `vqsub.u8 Qd, Qn, Rt`: saturating-subtracts 16x8-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.U8_T2" = mve.Lanewise(.qsub, 8, false, true).call;
/// VQSUB.U16 `vqsub.u16 Qd, Qn, Rt`: saturating-subtracts 8x16-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.U16_T2" = mve.Lanewise(.qsub, 16, false, true).call;
/// VQSUB.U32 `vqsub.u32 Qd, Qn, Rt`: saturating-subtracts 4x32-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VQSUB.U32_T2" = mve.Lanewise(.qsub, 32, false, true).call;
/// VHADD.S8 `vhadd.s8 Qd, Qn, Rt`: halving-adds 16x8-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.S8_T2" = mve.Lanewise(.hadd, 8, true, true).call;
/// VHADD.S16 `vhadd.s16 Qd, Qn, Rt`: halving-adds 8x16-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.S16_T2" = mve.Lanewise(.hadd, 16, true, true).call;
/// VHADD.S32 `vhadd.s32 Qd, Qn, Rt`: halving-adds 4x32-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.S32_T2" = mve.Lanewise(.hadd, 32, true, true).call;
/// VHADD.U8 `vhadd.u8 Qd, Qn, Rt`: halving-adds 16x8-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.U8_T2" = mve.Lanewise(.hadd, 8, false, true).call;
/// VHADD.U16 `vhadd.u16 Qd, Qn, Rt`: halving-adds 8x16-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.U16_T2" = mve.Lanewise(.hadd, 16, false, true).call;
/// VHADD.U32 `vhadd.u32 Qd, Qn, Rt`: halving-adds 4x32-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHADD.U32_T2" = mve.Lanewise(.hadd, 32, false, true).call;
/// VHSUB.S8 `vhsub.s8 Qd, Qn, Rt`: halving-subtracts 16x8-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.S8_T2" = mve.Lanewise(.hsub, 8, true, true).call;
/// VHSUB.S16 `vhsub.s16 Qd, Qn, Rt`: halving-subtracts 8x16-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.S16_T2" = mve.Lanewise(.hsub, 16, true, true).call;
/// VHSUB.S32 `vhsub.s32 Qd, Qn, Rt`: halving-subtracts 4x32-bit signed lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.S32_T2" = mve.Lanewise(.hsub, 32, true, true).call;
/// VHSUB.U8 `vhsub.u8 Qd, Qn, Rt`: halving-subtracts 16x8-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.U8_T2" = mve.Lanewise(.hsub, 8, false, true).call;
/// VHSUB.U16 `vhsub.u16 Qd, Qn, Rt`: halving-subtracts 8x16-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.U16_T2" = mve.Lanewise(.hsub, 16, false, true).call;
/// VHSUB.U32 `vhsub.u32 Qd, Qn, Rt`: halving-subtracts 4x32-bit unsigned lanes of Qn and Rt broadcast under the predicate.
pub const @"VHSUB.U32_T2" = mve.Lanewise(.hsub, 32, false, true).call;
/// VMLA.I8 `vmla.i8 Qd, Qn, Rt`: each 8-bit lane Qd += Qn*Rt under the predicate.
pub const @"VMLA.I8_vsv_T1" = mve.AccumulateFree(8).call;
/// VMLAS.S8 `vmlas.s8 Qd, Qn, Rt`: each 8-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.S8_vvs_T1" = mve.Accumulate(8, true).call;
/// VMLAS.U8 `vmlas.u8 Qd, Qn, Rt`: each 8-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.U8_vvs_T1" = mve.Accumulate(8, true).call;
/// VMLA.I16 `vmla.i16 Qd, Qn, Rt`: each 16-bit lane Qd += Qn*Rt under the predicate.
pub const @"VMLA.I16_vsv_T1" = mve.AccumulateFree(16).call;
/// VMLAS.S16 `vmlas.s16 Qd, Qn, Rt`: each 16-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.S16_vvs_T1" = mve.Accumulate(16, true).call;
/// VMLAS.U16 `vmlas.u16 Qd, Qn, Rt`: each 16-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.U16_vvs_T1" = mve.Accumulate(16, true).call;
/// VMLA.I32 `vmla.i32 Qd, Qn, Rt`: each 32-bit lane Qd += Qn*Rt under the predicate.
pub const @"VMLA.I32_vsv_T1" = mve.AccumulateFree(32).call;
/// VMLAS.S32 `vmlas.s32 Qd, Qn, Rt`: each 32-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.S32_vvs_T1" = mve.Accumulate(32, true).call;
/// VMLAS.U32 `vmlas.u32 Qd, Qn, Rt`: each 32-bit lane Qd = Qn*Qd + Rt under the predicate.
pub const @"VMLAS.U32_vvs_T1" = mve.Accumulate(32, true).call;
/// VDUP.32 `vdup.32 Qd, Rt`: broadcasts Rt's low word into every lane of Qd.
pub const @"VDUP.32_T1" = mve.Dup(32).call;
/// VDUP.16 `vdup.16 Qd, Rt`: broadcasts Rt's low halfword into every lane of Qd.
pub const @"VDUP.16_T1" = mve.Dup(16).call;
/// VDUP.8 `vdup.8 Qd, Rt`: broadcasts Rt's low byte into every lane of Qd.
pub const @"VDUP.8_T1" = mve.Dup(8).call;
/// VPT/VCMP `.i8|s8|u8 Qn, Qm`: compares 16x8-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I8_T1" = mve.Compare(8, false).call;
/// VPT/VCMP `.i8|s8|u8 Qn, Rm`: compares 16x8-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I8_T4" = mve.Compare(8, true).call;
/// VPT/VCMP `.i16|s16|u16 Qn, Qm`: compares 8x16-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I16_T1" = mve.Compare(16, false).call;
/// VPT/VCMP `.i16|s16|u16 Qn, Rm`: compares 8x16-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I16_T4" = mve.Compare(16, true).call;
/// VPT/VCMP `.i32|s32|u32 Qn, Qm`: compares 4x32-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I32_T1" = mve.Compare(32, false).call;
/// VPT/VCMP `.i32|s32|u32 Qn, Rm`: compares 4x32-bit lanes by cond into VPR.P0, mask opens the block.
pub const @"VPT.I32_T4" = mve.Compare(32, true).call;
/// VABS.S8 `vabs.s8 Qd, Qm`: absolute value of each 8-bit lane of Qm under the predicate.
pub const @"VABS.S8_vec_T1" = mve.Solo(.abs, 8).call;
/// VABS.S16 `vabs.s16 Qd, Qm`: absolute value of each 16-bit lane of Qm under the predicate.
pub const @"VABS.S16_vec_T1" = mve.Solo(.abs, 16).call;
/// VABS.S32 `vabs.s32 Qd, Qm`: absolute value of each 32-bit lane of Qm under the predicate.
pub const @"VABS.S32_vec_T1" = mve.Solo(.abs, 32).call;
/// VNEG.S8 `vneg.s8 Qd, Qm`: negation of each 8-bit lane of Qm under the predicate.
pub const @"VNEG.S8_vec_T1" = mve.Solo(.neg, 8).call;
/// VNEG.S16 `vneg.s16 Qd, Qm`: negation of each 16-bit lane of Qm under the predicate.
pub const @"VNEG.S16_vec_T1" = mve.Solo(.neg, 16).call;
/// VNEG.S32 `vneg.s32 Qd, Qm`: negation of each 32-bit lane of Qm under the predicate.
pub const @"VNEG.S32_vec_T1" = mve.Solo(.neg, 32).call;
/// VQABS.S8 `vqabs.s8 Qd, Qm`: saturating absolute value of each 8-bit lane of Qm under the predicate.
pub const @"VQABS.S8_T1" = mve.Solo(.qabs, 8).call;
/// VQABS.S16 `vqabs.s16 Qd, Qm`: saturating absolute value of each 16-bit lane of Qm under the predicate.
pub const @"VQABS.S16_T1" = mve.Solo(.qabs, 16).call;
/// VQABS.S32 `vqabs.s32 Qd, Qm`: saturating absolute value of each 32-bit lane of Qm under the predicate.
pub const @"VQABS.S32_T1" = mve.Solo(.qabs, 32).call;
/// VQNEG.S8 `vqneg.s8 Qd, Qm`: saturating negation of each 8-bit lane of Qm under the predicate.
pub const @"VQNEG.S8_T1" = mve.Solo(.qneg, 8).call;
/// VQNEG.S16 `vqneg.s16 Qd, Qm`: saturating negation of each 16-bit lane of Qm under the predicate.
pub const @"VQNEG.S16_T1" = mve.Solo(.qneg, 16).call;
/// VQNEG.S32 `vqneg.s32 Qd, Qm`: saturating negation of each 32-bit lane of Qm under the predicate.
pub const @"VQNEG.S32_T1" = mve.Solo(.qneg, 32).call;
/// VCLS.S8 `vcls.s8 Qd, Qm`: leading sign bit count of each 8-bit lane of Qm under the predicate.
pub const @"VCLS.S8_T1" = mve.Solo(.cls, 8).call;
/// VCLS.S16 `vcls.s16 Qd, Qm`: leading sign bit count of each 16-bit lane of Qm under the predicate.
pub const @"VCLS.S16_T1" = mve.Solo(.cls, 16).call;
/// VCLS.S32 `vcls.s32 Qd, Qm`: leading sign bit count of each 32-bit lane of Qm under the predicate.
pub const @"VCLS.S32_T1" = mve.Solo(.cls, 32).call;
/// VCLZ.I8 `vclz.i8 Qd, Qm`: leading zero count of each 8-bit lane of Qm under the predicate.
pub const @"VCLZ.I8_T1" = mve.Solo(.clz, 8).call;
/// VCLZ.I16 `vclz.i16 Qd, Qm`: leading zero count of each 16-bit lane of Qm under the predicate.
pub const @"VCLZ.I16_T1" = mve.Solo(.clz, 16).call;
/// VCLZ.I32 `vclz.i32 Qd, Qm`: leading zero count of each 32-bit lane of Qm under the predicate.
pub const @"VCLZ.I32_T1" = mve.Solo(.clz, 32).call;
/// VMVN `vmvn Qd, Qm`: bitwise NOT of each 8-bit lane of Qm under the predicate.
pub const VMVN_reg_T1 = mve.Solo(.mvn, 8).call;
/// VREV64.8 `vrev64.8 Qd, Qm`: reverses the 8-bit elements inside each 64-bit chunk of Qm.
pub const @"VREV64.8_T1" = mve.Reverse(8, 64).call;
/// VREV64.16 `vrev64.16 Qd, Qm`: reverses the 16-bit elements inside each 64-bit chunk of Qm.
pub const @"VREV64.16_T1" = mve.Reverse(16, 64).call;
/// VREV64.32 `vrev64.32 Qd, Qm`: reverses the 32-bit elements inside each 64-bit chunk of Qm.
pub const @"VREV64.32_T1" = mve.Reverse(32, 64).call;
/// VREV32.8 `vrev32.8 Qd, Qm`: reverses the 8-bit elements inside each 32-bit chunk of Qm.
pub const @"VREV32.8_T1" = mve.Reverse(8, 32).call;
/// VREV32.16 `vrev32.16 Qd, Qm`: reverses the 16-bit elements inside each 32-bit chunk of Qm.
pub const @"VREV32.16_T1" = mve.Reverse(16, 32).call;
/// VREV16.8 `vrev16.8 Qd, Qm`: reverses the 8-bit elements inside each 16-bit chunk of Qm.
pub const @"VREV16.8_T1" = mve.Reverse(8, 16).call;
/// VSHL.I8 `vshl.i8 Qd, Qm, #imm`: left shift of unsigned 8-bit lanes by imm, under the predicate.
pub const @"VSHL.I8_T1" = mve.Immediate(8, false, false, false, false, true).call;
/// VSLI.8 `vsli.8 Qd, Qm, #imm`: shifts each 8-bit lane of Qm left, keeping Qd's low bits, under the predicate.
pub const @"VSLI.8_T1" = mve.Insert(8, true).call;
/// VSRI.8 `vsri.8 Qd, Qm, #imm`: shifts each 8-bit lane of Qm right, keeping Qd's high bits, under the predicate.
pub const @"VSRI.8_T1" = mve.Insert(8, false).call;
/// VQSHLU.S8 `vqshlu.s8 Qd, Qm, #imm`: saturating left shift of signed 8-bit lanes by imm to unsigned, under the predicate.
pub const @"VQSHLU.S8_T3" = mve.Immediate(8, true, false, true, true, true).call;
/// VSHR.S8 `vshr.s8 Qd, Qm, #imm`: right shift of signed 8-bit lanes by imm, under the predicate.
pub const @"VSHR.S8_T1" = mve.Immediate(8, true, false, false, false, false).call;
/// VRSHR.S8 `vrshr.s8 Qd, Qm, #imm`: rounding right shift of signed 8-bit lanes by imm, under the predicate.
pub const @"VRSHR.S8_T1" = mve.Immediate(8, true, true, false, false, false).call;
/// VQSHL.S8 `vqshl.s8 Qd, Qm, #imm`: saturating left shift of signed 8-bit lanes by imm, under the predicate.
pub const @"VQSHL.S8_T2" = mve.Immediate(8, true, false, true, false, true).call;
/// VSHR.U8 `vshr.u8 Qd, Qm, #imm`: right shift of unsigned 8-bit lanes by imm, under the predicate.
pub const @"VSHR.U8_T1" = mve.Immediate(8, false, false, false, false, false).call;
/// VRSHR.U8 `vrshr.u8 Qd, Qm, #imm`: rounding right shift of unsigned 8-bit lanes by imm, under the predicate.
pub const @"VRSHR.U8_T1" = mve.Immediate(8, false, true, false, false, false).call;
/// VQSHL.U8 `vqshl.u8 Qd, Qm, #imm`: saturating left shift of unsigned 8-bit lanes by imm, under the predicate.
pub const @"VQSHL.U8_T2" = mve.Immediate(8, false, false, true, false, true).call;
/// VSHL.I16 `vshl.i16 Qd, Qm, #imm`: left shift of unsigned 16-bit lanes by imm, under the predicate.
pub const @"VSHL.I16_T1" = mve.Immediate(16, false, false, false, false, true).call;
/// VSLI.16 `vsli.16 Qd, Qm, #imm`: shifts each 16-bit lane of Qm left, keeping Qd's low bits, under the predicate.
pub const @"VSLI.16_T1" = mve.Insert(16, true).call;
/// VSRI.16 `vsri.16 Qd, Qm, #imm`: shifts each 16-bit lane of Qm right, keeping Qd's high bits, under the predicate.
pub const @"VSRI.16_T1" = mve.Insert(16, false).call;
/// VQSHLU.S16 `vqshlu.s16 Qd, Qm, #imm`: saturating left shift of signed 16-bit lanes by imm to unsigned, under the predicate.
pub const @"VQSHLU.S16_T3" = mve.Immediate(16, true, false, true, true, true).call;
/// VSHR.S16 `vshr.s16 Qd, Qm, #imm`: right shift of signed 16-bit lanes by imm, under the predicate.
pub const @"VSHR.S16_T1" = mve.Immediate(16, true, false, false, false, false).call;
/// VRSHR.S16 `vrshr.s16 Qd, Qm, #imm`: rounding right shift of signed 16-bit lanes by imm, under the predicate.
pub const @"VRSHR.S16_T1" = mve.Immediate(16, true, true, false, false, false).call;
/// VQSHL.S16 `vqshl.s16 Qd, Qm, #imm`: saturating left shift of signed 16-bit lanes by imm, under the predicate.
pub const @"VQSHL.S16_T2" = mve.Immediate(16, true, false, true, false, true).call;
/// VSHR.U16 `vshr.u16 Qd, Qm, #imm`: right shift of unsigned 16-bit lanes by imm, under the predicate.
pub const @"VSHR.U16_T1" = mve.Immediate(16, false, false, false, false, false).call;
/// VRSHR.U16 `vrshr.u16 Qd, Qm, #imm`: rounding right shift of unsigned 16-bit lanes by imm, under the predicate.
pub const @"VRSHR.U16_T1" = mve.Immediate(16, false, true, false, false, false).call;
/// VQSHL.U16 `vqshl.u16 Qd, Qm, #imm`: saturating left shift of unsigned 16-bit lanes by imm, under the predicate.
pub const @"VQSHL.U16_T2" = mve.Immediate(16, false, false, true, false, true).call;
/// VSHL.I32 `vshl.i32 Qd, Qm, #imm`: left shift of unsigned 32-bit lanes by imm, under the predicate.
pub const @"VSHL.I32_T1" = mve.Immediate(32, false, false, false, false, true).call;
/// VSLI.32 `vsli.32 Qd, Qm, #imm`: shifts each 32-bit lane of Qm left, keeping Qd's low bits, under the predicate.
pub const @"VSLI.32_T1" = mve.Insert(32, true).call;
/// VSRI.32 `vsri.32 Qd, Qm, #imm`: shifts each 32-bit lane of Qm right, keeping Qd's high bits, under the predicate.
pub const @"VSRI.32_T1" = mve.Insert(32, false).call;
/// VQSHLU.S32 `vqshlu.s32 Qd, Qm, #imm`: saturating left shift of signed 32-bit lanes by imm to unsigned, under the predicate.
pub const @"VQSHLU.S32_T3" = mve.Immediate(32, true, false, true, true, true).call;
/// VSHR.S32 `vshr.s32 Qd, Qm, #imm`: right shift of signed 32-bit lanes by imm, under the predicate.
pub const @"VSHR.S32_T1" = mve.Immediate(32, true, false, false, false, false).call;
/// VRSHR.S32 `vrshr.s32 Qd, Qm, #imm`: rounding right shift of signed 32-bit lanes by imm, under the predicate.
pub const @"VRSHR.S32_T1" = mve.Immediate(32, true, true, false, false, false).call;
/// VQSHL.S32 `vqshl.s32 Qd, Qm, #imm`: saturating left shift of signed 32-bit lanes by imm, under the predicate.
pub const @"VQSHL.S32_T2" = mve.Immediate(32, true, false, true, false, true).call;
/// VSHR.U32 `vshr.u32 Qd, Qm, #imm`: right shift of unsigned 32-bit lanes by imm, under the predicate.
pub const @"VSHR.U32_T1" = mve.Immediate(32, false, false, false, false, false).call;
/// VRSHR.U32 `vrshr.u32 Qd, Qm, #imm`: rounding right shift of unsigned 32-bit lanes by imm, under the predicate.
pub const @"VRSHR.U32_T1" = mve.Immediate(32, false, true, false, false, false).call;
/// VQSHL.U32 `vqshl.u32 Qd, Qm, #imm`: saturating left shift of unsigned 32-bit lanes by imm, under the predicate.
pub const @"VQSHL.U32_T2" = mve.Immediate(32, false, false, true, false, true).call;
/// VSHL.S8 `vshl.s8 Qd, Qm, Qn`: shift of signed 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.S8_T3" = mve.Variable(8, true, false, false).call;
/// VSHL.S8 `vshl.s8 Qd, Rt`: shift of signed 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.S8_T2" = mve.VariableScalar(8, true, false, false).call;
/// VSHL.S16 `vshl.s16 Qd, Qm, Qn`: shift of signed 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.S16_T3" = mve.Variable(16, true, false, false).call;
/// VSHL.S16 `vshl.s16 Qd, Rt`: shift of signed 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.S16_T2" = mve.VariableScalar(16, true, false, false).call;
/// VSHL.S32 `vshl.s32 Qd, Qm, Qn`: shift of signed 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.S32_T3" = mve.Variable(32, true, false, false).call;
/// VSHL.S32 `vshl.s32 Qd, Rt`: shift of signed 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.S32_T2" = mve.VariableScalar(32, true, false, false).call;
/// VSHL.U8 `vshl.u8 Qd, Qm, Qn`: shift of unsigned 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.U8_T3" = mve.Variable(8, false, false, false).call;
/// VSHL.U8 `vshl.u8 Qd, Rt`: shift of unsigned 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.U8_T2" = mve.VariableScalar(8, false, false, false).call;
/// VSHL.U16 `vshl.u16 Qd, Qm, Qn`: shift of unsigned 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.U16_T3" = mve.Variable(16, false, false, false).call;
/// VSHL.U16 `vshl.u16 Qd, Rt`: shift of unsigned 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.U16_T2" = mve.VariableScalar(16, false, false, false).call;
/// VSHL.U32 `vshl.u32 Qd, Qm, Qn`: shift of unsigned 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VSHL.U32_T3" = mve.Variable(32, false, false, false).call;
/// VSHL.U32 `vshl.u32 Qd, Rt`: shift of unsigned 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VSHL.U32_T2" = mve.VariableScalar(32, false, false, false).call;
/// VRSHL.S8 `vrshl.s8 Qd, Qm, Qn`: rounding shift of signed 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.S8_T1" = mve.Variable(8, true, true, false).call;
/// VRSHL.S8 `vrshl.s8 Qd, Rt`: rounding shift of signed 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.S8_T2" = mve.VariableScalar(8, true, true, false).call;
/// VRSHL.S16 `vrshl.s16 Qd, Qm, Qn`: rounding shift of signed 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.S16_T1" = mve.Variable(16, true, true, false).call;
/// VRSHL.S16 `vrshl.s16 Qd, Rt`: rounding shift of signed 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.S16_T2" = mve.VariableScalar(16, true, true, false).call;
/// VRSHL.S32 `vrshl.s32 Qd, Qm, Qn`: rounding shift of signed 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.S32_T1" = mve.Variable(32, true, true, false).call;
/// VRSHL.S32 `vrshl.s32 Qd, Rt`: rounding shift of signed 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.S32_T2" = mve.VariableScalar(32, true, true, false).call;
/// VRSHL.U8 `vrshl.u8 Qd, Qm, Qn`: rounding shift of unsigned 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.U8_T1" = mve.Variable(8, false, true, false).call;
/// VRSHL.U8 `vrshl.u8 Qd, Rt`: rounding shift of unsigned 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.U8_T2" = mve.VariableScalar(8, false, true, false).call;
/// VRSHL.U16 `vrshl.u16 Qd, Qm, Qn`: rounding shift of unsigned 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.U16_T1" = mve.Variable(16, false, true, false).call;
/// VRSHL.U16 `vrshl.u16 Qd, Rt`: rounding shift of unsigned 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.U16_T2" = mve.VariableScalar(16, false, true, false).call;
/// VRSHL.U32 `vrshl.u32 Qd, Qm, Qn`: rounding shift of unsigned 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VRSHL.U32_T1" = mve.Variable(32, false, true, false).call;
/// VRSHL.U32 `vrshl.u32 Qd, Rt`: rounding shift of unsigned 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VRSHL.U32_T2" = mve.VariableScalar(32, false, true, false).call;
/// VQSHL.S8 `vqshl.s8 Qd, Qm, Qn`: saturating shift of signed 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.S8_T4" = mve.Variable(8, true, false, true).call;
/// VQSHL.S8 `vqshl.s8 Qd, Rt`: saturating shift of signed 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.S8_T1" = mve.VariableScalar(8, true, false, true).call;
/// VQSHL.S16 `vqshl.s16 Qd, Qm, Qn`: saturating shift of signed 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.S16_T4" = mve.Variable(16, true, false, true).call;
/// VQSHL.S16 `vqshl.s16 Qd, Rt`: saturating shift of signed 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.S16_T1" = mve.VariableScalar(16, true, false, true).call;
/// VQSHL.S32 `vqshl.s32 Qd, Qm, Qn`: saturating shift of signed 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.S32_T4" = mve.Variable(32, true, false, true).call;
/// VQSHL.S32 `vqshl.s32 Qd, Rt`: saturating shift of signed 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.S32_T1" = mve.VariableScalar(32, true, false, true).call;
/// VQSHL.U8 `vqshl.u8 Qd, Qm, Qn`: saturating shift of unsigned 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.U8_T4" = mve.Variable(8, false, false, true).call;
/// VQSHL.U8 `vqshl.u8 Qd, Rt`: saturating shift of unsigned 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.U8_T1" = mve.VariableScalar(8, false, false, true).call;
/// VQSHL.U16 `vqshl.u16 Qd, Qm, Qn`: saturating shift of unsigned 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.U16_T4" = mve.Variable(16, false, false, true).call;
/// VQSHL.U16 `vqshl.u16 Qd, Rt`: saturating shift of unsigned 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.U16_T1" = mve.VariableScalar(16, false, false, true).call;
/// VQSHL.U32 `vqshl.u32 Qd, Qm, Qn`: saturating shift of unsigned 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQSHL.U32_T4" = mve.Variable(32, false, false, true).call;
/// VQSHL.U32 `vqshl.u32 Qd, Rt`: saturating shift of unsigned 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VQSHL.U32_T1" = mve.VariableScalar(32, false, false, true).call;
/// VQRSHL.S8 `vqrshl.s8 Qd, Qm, Qn`: rounding saturating shift of signed 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.S8_T1" = mve.Variable(8, true, true, true).call;
/// VQRSHL.S8 `vqrshl.s8 Qd, Rt`: rounding saturating shift of signed 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.S8_T2" = mve.VariableScalar(8, true, true, true).call;
/// VQRSHL.S16 `vqrshl.s16 Qd, Qm, Qn`: rounding saturating shift of signed 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.S16_T1" = mve.Variable(16, true, true, true).call;
/// VQRSHL.S16 `vqrshl.s16 Qd, Rt`: rounding saturating shift of signed 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.S16_T2" = mve.VariableScalar(16, true, true, true).call;
/// VQRSHL.S32 `vqrshl.s32 Qd, Qm, Qn`: rounding saturating shift of signed 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.S32_T1" = mve.Variable(32, true, true, true).call;
/// VQRSHL.S32 `vqrshl.s32 Qd, Rt`: rounding saturating shift of signed 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.S32_T2" = mve.VariableScalar(32, true, true, true).call;
/// VQRSHL.U8 `vqrshl.u8 Qd, Qm, Qn`: rounding saturating shift of unsigned 8-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.U8_T1" = mve.Variable(8, false, true, true).call;
/// VQRSHL.U8 `vqrshl.u8 Qd, Rt`: rounding saturating shift of unsigned 8-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.U8_T2" = mve.VariableScalar(8, false, true, true).call;
/// VQRSHL.U16 `vqrshl.u16 Qd, Qm, Qn`: rounding saturating shift of unsigned 16-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.U16_T1" = mve.Variable(16, false, true, true).call;
/// VQRSHL.U16 `vqrshl.u16 Qd, Rt`: rounding saturating shift of unsigned 16-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.U16_T2" = mve.VariableScalar(16, false, true, true).call;
/// VQRSHL.U32 `vqrshl.u32 Qd, Qm, Qn`: rounding saturating shift of unsigned 32-bit lanes by Qn's signed amounts, negative shifting right.
pub const @"VQRSHL.U32_T1" = mve.Variable(32, false, true, true).call;
/// VQRSHL.U32 `vqrshl.u32 Qd, Rt`: rounding saturating shift of unsigned 32-bit lanes by Rt's signed low byte, negative right.
pub const @"VQRSHL.U32_T2" = mve.VariableScalar(32, false, true, true).call;
/// VBRSR.8 `vbrsr.8 Qd, Qn, Rt`: reverses the low Rt bits of each 8-bit lane of Qn.
pub const @"VBRSR.8_T1" = mve.BitReverse(8).call;
/// VBRSR.16 `vbrsr.16 Qd, Qn, Rt`: reverses the low Rt bits of each 16-bit lane of Qn.
pub const @"VBRSR.16_T1" = mve.BitReverse(16).call;
/// VBRSR.32 `vbrsr.32 Qd, Qn, Rt`: reverses the low Rt bits of each 32-bit lane of Qn.
pub const @"VBRSR.32_T1" = mve.BitReverse(32).call;
/// VSHLC `vshlc Qd, Rt, #imm`: shifts Qd left by imm as one 128-bit value, Rt supplying and taking the bits.
pub const VSHLC_T1 = mve.carry;
/// LSLL `lsll RdaLo, RdaHi, #imm`: logical left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const LSLL_imm_T1_r1 = mve.LongPairImmediate(.lsl, 1).call;
/// LSLL `lsll RdaLo, RdaHi, #imm`: logical left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const LSLL_imm_T1_r9 = mve.LongPairImmediate(.lsl, 9).call;
/// LSRL `lsrl RdaLo, RdaHi, #imm`: logical right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const LSRL_imm_T1_r1 = mve.LongPairImmediate(.lsr, 1).call;
/// LSRL `lsrl RdaLo, RdaHi, #imm`: logical right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const LSRL_imm_T1_r9 = mve.LongPairImmediate(.lsr, 9).call;
/// ASRL `asrl RdaLo, RdaHi, #imm`: arithmetic right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const ASRL_imm_T1_r1 = mve.LongPairImmediate(.asr, 1).call;
/// ASRL `asrl RdaLo, RdaHi, #imm`: arithmetic right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const ASRL_imm_T1_r9 = mve.LongPairImmediate(.asr, 9).call;
/// UQSHLL `uqshll RdaLo, RdaHi, #imm`: unsigned saturating left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const UQSHLL_imm_T1_r1 = mve.LongPairImmediate(.uqshl, 1).call;
/// UQSHLL `uqshll RdaLo, RdaHi, #imm`: unsigned saturating left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const UQSHLL_imm_T1_r9 = mve.LongPairImmediate(.uqshl, 9).call;
/// URSHRL `urshrl RdaLo, RdaHi, #imm`: unsigned rounding right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const URSHRL_imm_T1_r1 = mve.LongPairImmediate(.urshr, 1).call;
/// URSHRL `urshrl RdaLo, RdaHi, #imm`: unsigned rounding right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const URSHRL_imm_T1_r9 = mve.LongPairImmediate(.urshr, 9).call;
/// SRSHRL `srshrl RdaLo, RdaHi, #imm`: signed rounding right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const SRSHRL_imm_T1_r1 = mve.LongPairImmediate(.srshr, 1).call;
/// SRSHRL `srshrl RdaLo, RdaHi, #imm`: signed rounding right shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const SRSHRL_imm_T1_r9 = mve.LongPairImmediate(.srshr, 9).call;
/// SQSHLL `sqshll RdaLo, RdaHi, #imm`: signed saturating left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r1-r7.
pub const SQSHLL_imm_T1_r1 = mve.LongPairImmediate(.sqshl, 1).call;
/// SQSHLL `sqshll RdaLo, RdaHi, #imm`: signed saturating left shift of the 64-bit RdaHi:RdaLo by imm, RdaHi r9/r11.
pub const SQSHLL_imm_T1_r9 = mve.LongPairImmediate(.sqshl, 9).call;
/// LSLL `lsll RdaLo, RdaHi, Rm`: logical left shift of 64-bit RdaHi:RdaLo by Rm's low byte, RdaHi r1-r7.
pub const LSLL_reg_T1_r1 = mve.LongPairRegister(.lsl, 1).call;
/// LSLL `lsll RdaLo, RdaHi, Rm`: logical left shift of 64-bit RdaHi:RdaLo by Rm's low byte, RdaHi r9/r11.
pub const LSLL_reg_T1_r9 = mve.LongPairRegister(.lsl, 9).call;
/// ASRL `asrl RdaLo, RdaHi, Rm`: arithmetic right shift of 64-bit RdaHi:RdaLo by Rm's low byte, RdaHi r1-r7.
pub const ASRL_reg_T1_r1 = mve.LongPairRegister(.asr, 1).call;
/// ASRL `asrl RdaLo, RdaHi, Rm`: arithmetic right shift of 64-bit RdaHi:RdaLo by Rm's low byte, RdaHi r9/r11.
pub const ASRL_reg_T1_r9 = mve.LongPairRegister(.asr, 9).call;
/// UQRSHLL `uqrshll RdaLo, RdaHi, #sat, Rm`: rounding left shift, RdaHi:RdaLo by Rm, clamped at sat bits, RdaHi r1-r7.
pub const UQRSHLL_reg_T1_r1 = mve.LongPairLimited(.uqrshl, 1).call;
/// UQRSHLL `uqrshll RdaLo, RdaHi, #sat, Rm`: rounding left shift, RdaHi:RdaLo by Rm, clamped at sat bits, RdaHi r9/r11.
pub const UQRSHLL_reg_T1_r9 = mve.LongPairLimited(.uqrshl, 9).call;
/// SQRSHRL `sqrshrl RdaLo, RdaHi, #sat, Rm`: rounding right shift, RdaHi:RdaLo by Rm, clamped at sat bits, RdaHi r1-r7.
pub const SQRSHRL_reg_T1_r1 = mve.LongPairLimited(.sqrshr, 1).call;
/// SQRSHRL `sqrshrl RdaLo, RdaHi, #sat, Rm`: rounding right shift, RdaHi:RdaLo by Rm, clamped at sat bits, RdaHi r9/r11.
pub const SQRSHRL_reg_T1_r9 = mve.LongPairLimited(.sqrshr, 9).call;
/// UQSHL `uqshl Rn, #imm`: unsigned saturating left shift of the 32-bit Rn by imm, Q on saturation.
pub const UQSHL_imm_T1 = mve.LongOneImmediate(.uqshl).call;
/// URSHR `urshr Rn, #imm`: unsigned rounding right shift of the 32-bit Rn by imm, Q on saturation.
pub const URSHR_imm_T1 = mve.LongOneImmediate(.urshr).call;
/// SRSHR `srshr Rn, #imm`: signed rounding right shift of the 32-bit Rn by imm, Q on saturation.
pub const SRSHR_imm_T1 = mve.LongOneImmediate(.srshr).call;
/// SQSHL `sqshl Rn, #imm`: signed saturating left shift of the 32-bit Rn by imm, Q on saturation.
pub const SQSHL_imm_T1 = mve.LongOneImmediate(.sqshl).call;
/// UQRSHL `uqrshl Rn, Rm`: unsigned saturating rounding left shift of the 32-bit Rn by Rm's signed low byte.
pub const UQRSHL_reg_T1 = mve.LongOneRegister(.uqrshl).call;
/// SQRSHR `sqrshr Rn, Rm`: signed saturating rounding right shift of the 32-bit Rn by Rm's signed low byte.
pub const SQRSHR_reg_T1 = mve.LongOneRegister(.sqrshr).call;
/// VLDRB.U8 `vldrb.u8 Qd, [Rn, #±imm]{!}`: byte load, writeback per W.
pub const @"VLDRB.U8_T5_pre" = mve.ContiguousIndexed(true, 8, 8).call;
/// VLDRB.U8 `vldrb.u8 Qd, [Rn], #±imm`: byte load, post-indexed.
pub const @"VLDRB.U8_T5_post" = mve.Contiguous(true, 8, 8).call;
/// VSTRB.8 `vstrb.8 Qd, [Rn, #±imm]{!}`: byte store, writeback per W.
pub const @"VSTRB.8_T5_pre" = mve.ContiguousIndexed(false, 8, 8).call;
/// VSTRB.8 `vstrb.8 Qd, [Rn], #±imm`: byte store, post-indexed.
pub const @"VSTRB.8_T5_post" = mve.Contiguous(false, 8, 8).call;
/// VLDRH.U16 `vldrh.u16 Qd, [Rn, #±imm]{!}`: halfword load, writeback per W.
pub const @"VLDRH.U16_T6_pre" = mve.ContiguousIndexed(true, 16, 16).call;
/// VLDRH.U16 `vldrh.u16 Qd, [Rn], #±imm`: halfword load, post-indexed.
pub const @"VLDRH.U16_T6_post" = mve.Contiguous(true, 16, 16).call;
/// VSTRH.16 `vstrh.16 Qd, [Rn, #±imm]{!}`: halfword store, writeback per W.
pub const @"VSTRH.16_T6_pre" = mve.ContiguousIndexed(false, 16, 16).call;
/// VSTRH.16 `vstrh.16 Qd, [Rn], #±imm`: halfword store, post-indexed.
pub const @"VSTRH.16_T6_post" = mve.Contiguous(false, 16, 16).call;
/// VLDRW.U32 `vldrw.u32 Qd, [Rn, #±imm]{!}`: word load, writeback per W.
pub const @"VLDRW.U32_T7_pre" = mve.ContiguousIndexed(true, 32, 32).call;
/// VLDRW.U32 `vldrw.u32 Qd, [Rn], #±imm`: word load, post-indexed.
pub const @"VLDRW.U32_T7_post" = mve.Contiguous(true, 32, 32).call;
/// VSTRW.32 `vstrw.32 Qd, [Rn, #±imm]{!}`: word store, writeback per W.
pub const @"VSTRW.32_T7_pre" = mve.ContiguousIndexed(false, 32, 32).call;
/// VSTRW.32 `vstrw.32 Qd, [Rn], #±imm`: word store, post-indexed.
pub const @"VSTRW.32_T7_post" = mve.Contiguous(false, 32, 32).call;
/// VLDRB.S16/U16 `vldrb.s16|u16 Qd, [Rn, #±imm]{!}`: bytes widened to 16-bit lanes, writeback per W.
pub const @"VLDRB.S16_T1_pre" = mve.ContiguousWideIndexed(8, 16).call;
/// VLDRB.S16/U16 `vldrb.s16|u16 Qd, [Rn], #±imm`: bytes widened to 16-bit lanes, post-indexed.
pub const @"VLDRB.S16_T1_post" = mve.ContiguousWide(8, 16).call;
/// VSTRB.16 `vstrb.16 Qd, [Rn, #±imm]{!}`: byte store, narrowing 16-bit lanes, writeback per W.
pub const @"VSTRB.16_T1_pre" = mve.ContiguousIndexed(false, 8, 16).call;
/// VSTRB.16 `vstrb.16 Qd, [Rn], #±imm`: byte store, narrowing 16-bit lanes, post-indexed.
pub const @"VSTRB.16_T1_post" = mve.Contiguous(false, 8, 16).call;
/// VLDRB.S32/U32 `vldrb.s32|u32 Qd, [Rn, #±imm]{!}`: bytes widened to 32-bit lanes, writeback per W.
pub const @"VLDRB.S32_T1_pre" = mve.ContiguousWideIndexed(8, 32).call;
/// VLDRB.S32/U32 `vldrb.s32|u32 Qd, [Rn], #±imm`: bytes widened to 32-bit lanes, post-indexed.
pub const @"VLDRB.S32_T1_post" = mve.ContiguousWide(8, 32).call;
/// VSTRB.32 `vstrb.32 Qd, [Rn, #±imm]{!}`: byte store, narrowing 32-bit lanes, writeback per W.
pub const @"VSTRB.32_T1_pre" = mve.ContiguousIndexed(false, 8, 32).call;
/// VSTRB.32 `vstrb.32 Qd, [Rn], #±imm`: byte store, narrowing 32-bit lanes, post-indexed.
pub const @"VSTRB.32_T1_post" = mve.Contiguous(false, 8, 32).call;
/// VLDRH.S32/U32 `vldrh.s32|u32 Qd, [Rn, #±imm]{!}`: halfwords widened to 32-bit lanes, writeback per W.
pub const @"VLDRH.S32_T2_pre" = mve.ContiguousWideIndexed(16, 32).call;
/// VLDRH.S32/U32 `vldrh.s32|u32 Qd, [Rn], #±imm`: halfwords widened to 32-bit lanes, post-indexed.
pub const @"VLDRH.S32_T2_post" = mve.ContiguousWide(16, 32).call;
/// VSTRH.32 `vstrh.32 Qd, [Rn, #±imm]{!}`: halfword store, narrowing 32-bit lanes, writeback per W.
pub const @"VSTRH.32_T2_pre" = mve.ContiguousIndexed(false, 16, 32).call;
/// VSTRH.32 `vstrh.32 Qd, [Rn], #±imm`: halfword store, narrowing 32-bit lanes, post-indexed.
pub const @"VSTRH.32_T2_post" = mve.Contiguous(false, 16, 32).call;
/// VLDRB.U8 `vldrb.u8 Qd, [Rn, Qm]`: byte gather into 8-bit lanes, Rn + Qm offsets.
pub const @"VLDRB.U8_vec_T1" = mve.ScatteredByte(true, 8, true).call;
/// VSTRB.8 `vstrb.8 Qd, [Rn, Qm]`: byte scatter of 8-bit lanes, Rn + Qm offsets.
pub const @"VSTRB.8_vec_T1" = mve.ScatteredByte(false, 8, true).call;
/// VLDRB.U16 `vldrb.u16 Qd, [Rn, Qm]`: byte gather into 16-bit lanes, Rn + Qm offsets.
pub const @"VLDRB.U16_vec_T1" = mve.ScatteredByte(true, 16, true).call;
/// VSTRB.16 `vstrb.16 Qd, [Rn, Qm]`: byte scatter of 16-bit lanes, Rn + Qm offsets.
pub const @"VSTRB.16_vec_T1" = mve.ScatteredByte(false, 16, true).call;
/// VLDRB.S16 `vldrb.s16 Qd, [Rn, Qm]`: byte gather into, sign-extended, 16-bit lanes, Rn + Qm offsets.
pub const @"VLDRB.S16_vec_T1" = mve.ScatteredByte(true, 16, false).call;
/// VLDRB.U32 `vldrb.u32 Qd, [Rn, Qm]`: byte gather into 32-bit lanes, Rn + Qm offsets.
pub const @"VLDRB.U32_vec_T1" = mve.ScatteredByte(true, 32, true).call;
/// VSTRB.32 `vstrb.32 Qd, [Rn, Qm]`: byte scatter of 32-bit lanes, Rn + Qm offsets.
pub const @"VSTRB.32_vec_T1" = mve.ScatteredByte(false, 32, true).call;
/// VLDRB.S32 `vldrb.s32 Qd, [Rn, Qm]`: byte gather into, sign-extended, 32-bit lanes, Rn + Qm offsets.
pub const @"VLDRB.S32_vec_T1" = mve.ScatteredByte(true, 32, false).call;
/// VLDRH.U16 `vldrh.u16 Qd, [Rn, Qm]`: halfword gather into 16-bit lanes, Rn + Qm offsets.
pub const @"VLDRH.U16_vec_T2" = mve.Scattered(true, 16, 16, true, 0).call;
/// VSTRH.16 `vstrh.16 Qd, [Rn, Qm]`: halfword scatter of 16-bit lanes, Rn + Qm offsets.
pub const @"VSTRH.16_vec_T2" = mve.Scattered(false, 16, 16, true, 0).call;
/// VLDRH.U16 `vldrh.u16 Qd, [Rn, Qm, uxtw #1]`: halfword gather into 16-bit lanes, Rn + Qm offsets scaled by 2.
pub const @"VLDRH.U16_vec_T2_uxtw" = mve.Scattered(true, 16, 16, true, 1).call;
/// VSTRH.16 `vstrh.16 Qd, [Rn, Qm, uxtw #1]`: halfword scatter of 16-bit lanes, Rn + Qm offsets scaled by 2.
pub const @"VSTRH.16_vec_T2_uxtw" = mve.Scattered(false, 16, 16, true, 1).call;
/// VLDRH.U32 `vldrh.u32 Qd, [Rn, Qm]`: halfword gather into 32-bit lanes, Rn + Qm offsets.
pub const @"VLDRH.U32_vec_T2" = mve.Scattered(true, 16, 32, true, 0).call;
/// VSTRH.32 `vstrh.32 Qd, [Rn, Qm]`: halfword scatter of 32-bit lanes, Rn + Qm offsets.
pub const @"VSTRH.32_vec_T2" = mve.Scattered(false, 16, 32, true, 0).call;
/// VLDRH.U32 `vldrh.u32 Qd, [Rn, Qm, uxtw #1]`: halfword gather into 32-bit lanes, Rn + Qm offsets scaled by 2.
pub const @"VLDRH.U32_vec_T2_uxtw" = mve.Scattered(true, 16, 32, true, 1).call;
/// VSTRH.32 `vstrh.32 Qd, [Rn, Qm, uxtw #1]`: halfword scatter of 32-bit lanes, Rn + Qm offsets scaled by 2.
pub const @"VSTRH.32_vec_T2_uxtw" = mve.Scattered(false, 16, 32, true, 1).call;
/// VLDRH.S32 `vldrh.s32 Qd, [Rn, Qm]`: halfword gather into, sign-extended, 32-bit lanes, Rn + Qm offsets.
pub const @"VLDRH.S32_vec_T2" = mve.Scattered(true, 16, 32, false, 0).call;
/// VLDRH.S32 `vldrh.s32 Qd, [Rn, Qm, uxtw #1]`: halfword gather into, sign-extended, 32-bit lanes, Rn + Qm offsets scaled by 2.
pub const @"VLDRH.S32_vec_T2_uxtw" = mve.Scattered(true, 16, 32, false, 1).call;
/// VLDRW.U32 `vldrw.u32 Qd, [Rn, Qm]`: word gather into 32-bit lanes, Rn + Qm offsets.
pub const @"VLDRW.U32_vec_T3" = mve.Scattered(true, 32, 32, true, 0).call;
/// VSTRW.32 `vstrw.32 Qd, [Rn, Qm]`: word scatter of 32-bit lanes, Rn + Qm offsets.
pub const @"VSTRW.32_vec_T3" = mve.Scattered(false, 32, 32, true, 0).call;
/// VLDRW.U32 `vldrw.u32 Qd, [Rn, Qm, uxtw #2]`: word gather into 32-bit lanes, Rn + Qm offsets scaled by 4.
pub const @"VLDRW.U32_vec_T3_uxtw" = mve.Scattered(true, 32, 32, true, 2).call;
/// VSTRW.32 `vstrw.32 Qd, [Rn, Qm, uxtw #2]`: word scatter of 32-bit lanes, Rn + Qm offsets scaled by 4.
pub const @"VSTRW.32_vec_T3_uxtw" = mve.Scattered(false, 32, 32, true, 2).call;
/// VLDRD.U64 `vldrd.u64 Qd, [Rn, Qm]`: doubleword gather into 64-bit lanes, Rn + Qm offsets.
pub const @"VLDRD.U64_vec_T4" = mve.Paired(true, 0).call;
/// VSTRD.64 `vstrd.64 Qd, [Rn, Qm]`: doubleword scatter of 64-bit lanes, Rn + Qm offsets.
pub const @"VSTRD.64_vec_T4" = mve.Paired(false, 0).call;
/// VLDRD.U64 `vldrd.u64 Qd, [Rn, Qm, uxtw #3]`: doubleword gather into 64-bit lanes, Rn + Qm offsets scaled by 8.
pub const @"VLDRD.U64_vec_T4_uxtw" = mve.Paired(true, 3).call;
/// VSTRD.64 `vstrd.64 Qd, [Rn, Qm, uxtw #3]`: doubleword scatter of 64-bit lanes, Rn + Qm offsets scaled by 8.
pub const @"VSTRD.64_vec_T4_uxtw" = mve.Paired(false, 3).call;
/// VSTRW.32 `vstrw.32 Qd, [Qm, #±imm*4]{!}`: scatter to each Qm word plus the offset, writeback per W.
pub const @"VSTRW.32_vec_T5" = mve.ScatteredOffset(false).call;
/// VSTRD.64 `vstrd.64 Qd, [Qm, #±imm*8]{!}`: scatter to each 64-bit Qm base plus the offset, writeback per W.
pub const @"VSTRD.64_vec_T6" = mve.PairedOffset(false).call;
/// VLDRW.U32 `vldrw.u32 Qd, [Qm, #±imm*4]{!}`: gather from each Qm word plus the offset, writeback per W.
pub const @"VLDRW.U32_vec_T5" = mve.ScatteredOffset(true).call;
/// VLDRD.U64 `vldrd.u64 Qd, [Qm, #±imm*8]{!}`: gather from each 64-bit Qm base plus the offset, writeback per W.
pub const @"VLDRD.U64_vec_T6" = mve.PairedOffset(true).call;
/// VST20.8 `vst20.8 {Qlist}, [Rn]{!}`: beat 0 of the two-way 8-bit de-interleave, stores two registers, writeback per W.
pub const @"VST20.8_T1" = mve.Interleaved(false, 8, false, 0).call;
/// VLD20.8 `vld20.8 {Qlist}, [Rn]{!}`: beat 0 of the two-way 8-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD20.8_T1" = mve.Interleaved(true, 8, false, 0).call;
/// VST20.16 `vst20.16 {Qlist}, [Rn]{!}`: beat 0 of the two-way 16-bit de-interleave, stores two registers, writeback per W.
pub const @"VST20.16_T1" = mve.Interleaved(false, 16, false, 0).call;
/// VLD20.16 `vld20.16 {Qlist}, [Rn]{!}`: beat 0 of the two-way 16-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD20.16_T1" = mve.Interleaved(true, 16, false, 0).call;
/// VST20.32 `vst20.32 {Qlist}, [Rn]{!}`: beat 0 of the two-way 32-bit de-interleave, stores two registers, writeback per W.
pub const @"VST20.32_T1" = mve.Interleaved(false, 32, false, 0).call;
/// VLD20.32 `vld20.32 {Qlist}, [Rn]{!}`: beat 0 of the two-way 32-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD20.32_T1" = mve.Interleaved(true, 32, false, 0).call;
/// VST21.8 `vst21.8 {Qlist}, [Rn]{!}`: beat 1 of the two-way 8-bit de-interleave, stores two registers, writeback per W.
pub const @"VST21.8_T1" = mve.Interleaved(false, 8, false, 1).call;
/// VLD21.8 `vld21.8 {Qlist}, [Rn]{!}`: beat 1 of the two-way 8-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD21.8_T1" = mve.Interleaved(true, 8, false, 1).call;
/// VST21.16 `vst21.16 {Qlist}, [Rn]{!}`: beat 1 of the two-way 16-bit de-interleave, stores two registers, writeback per W.
pub const @"VST21.16_T1" = mve.Interleaved(false, 16, false, 1).call;
/// VLD21.16 `vld21.16 {Qlist}, [Rn]{!}`: beat 1 of the two-way 16-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD21.16_T1" = mve.Interleaved(true, 16, false, 1).call;
/// VST21.32 `vst21.32 {Qlist}, [Rn]{!}`: beat 1 of the two-way 32-bit de-interleave, stores two registers, writeback per W.
pub const @"VST21.32_T1" = mve.Interleaved(false, 32, false, 1).call;
/// VLD21.32 `vld21.32 {Qlist}, [Rn]{!}`: beat 1 of the two-way 32-bit de-interleave, loads two registers, writeback per W.
pub const @"VLD21.32_T1" = mve.Interleaved(true, 32, false, 1).call;
/// VST40.8 `vst40.8 {Qlist}, [Rn]{!}`: beat 0 of the four-way 8-bit de-interleave, stores four registers, writeback per W.
pub const @"VST40.8_T1" = mve.Interleaved(false, 8, true, 0).call;
/// VLD40.8 `vld40.8 {Qlist}, [Rn]{!}`: beat 0 of the four-way 8-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD40.8_T1" = mve.Interleaved(true, 8, true, 0).call;
/// VST40.16 `vst40.16 {Qlist}, [Rn]{!}`: beat 0 of the four-way 16-bit de-interleave, stores four registers, writeback per W.
pub const @"VST40.16_T1" = mve.Interleaved(false, 16, true, 0).call;
/// VLD40.16 `vld40.16 {Qlist}, [Rn]{!}`: beat 0 of the four-way 16-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD40.16_T1" = mve.Interleaved(true, 16, true, 0).call;
/// VST40.32 `vst40.32 {Qlist}, [Rn]{!}`: beat 0 of the four-way 32-bit de-interleave, stores four registers, writeback per W.
pub const @"VST40.32_T1" = mve.Interleaved(false, 32, true, 0).call;
/// VLD40.32 `vld40.32 {Qlist}, [Rn]{!}`: beat 0 of the four-way 32-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD40.32_T1" = mve.Interleaved(true, 32, true, 0).call;
/// VST41.8 `vst41.8 {Qlist}, [Rn]{!}`: beat 1 of the four-way 8-bit de-interleave, stores four registers, writeback per W.
pub const @"VST41.8_T1" = mve.Interleaved(false, 8, true, 1).call;
/// VLD41.8 `vld41.8 {Qlist}, [Rn]{!}`: beat 1 of the four-way 8-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD41.8_T1" = mve.Interleaved(true, 8, true, 1).call;
/// VST41.16 `vst41.16 {Qlist}, [Rn]{!}`: beat 1 of the four-way 16-bit de-interleave, stores four registers, writeback per W.
pub const @"VST41.16_T1" = mve.Interleaved(false, 16, true, 1).call;
/// VLD41.16 `vld41.16 {Qlist}, [Rn]{!}`: beat 1 of the four-way 16-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD41.16_T1" = mve.Interleaved(true, 16, true, 1).call;
/// VST41.32 `vst41.32 {Qlist}, [Rn]{!}`: beat 1 of the four-way 32-bit de-interleave, stores four registers, writeback per W.
pub const @"VST41.32_T1" = mve.Interleaved(false, 32, true, 1).call;
/// VLD41.32 `vld41.32 {Qlist}, [Rn]{!}`: beat 1 of the four-way 32-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD41.32_T1" = mve.Interleaved(true, 32, true, 1).call;
/// VST42.8 `vst42.8 {Qlist}, [Rn]{!}`: beat 2 of the four-way 8-bit de-interleave, stores four registers, writeback per W.
pub const @"VST42.8_T1" = mve.Interleaved(false, 8, true, 2).call;
/// VLD42.8 `vld42.8 {Qlist}, [Rn]{!}`: beat 2 of the four-way 8-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD42.8_T1" = mve.Interleaved(true, 8, true, 2).call;
/// VST42.16 `vst42.16 {Qlist}, [Rn]{!}`: beat 2 of the four-way 16-bit de-interleave, stores four registers, writeback per W.
pub const @"VST42.16_T1" = mve.Interleaved(false, 16, true, 2).call;
/// VLD42.16 `vld42.16 {Qlist}, [Rn]{!}`: beat 2 of the four-way 16-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD42.16_T1" = mve.Interleaved(true, 16, true, 2).call;
/// VST42.32 `vst42.32 {Qlist}, [Rn]{!}`: beat 2 of the four-way 32-bit de-interleave, stores four registers, writeback per W.
pub const @"VST42.32_T1" = mve.Interleaved(false, 32, true, 2).call;
/// VLD42.32 `vld42.32 {Qlist}, [Rn]{!}`: beat 2 of the four-way 32-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD42.32_T1" = mve.Interleaved(true, 32, true, 2).call;
/// VST43.8 `vst43.8 {Qlist}, [Rn]{!}`: beat 3 of the four-way 8-bit de-interleave, stores four registers, writeback per W.
pub const @"VST43.8_T1" = mve.Interleaved(false, 8, true, 3).call;
/// VLD43.8 `vld43.8 {Qlist}, [Rn]{!}`: beat 3 of the four-way 8-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD43.8_T1" = mve.Interleaved(true, 8, true, 3).call;
/// VST43.16 `vst43.16 {Qlist}, [Rn]{!}`: beat 3 of the four-way 16-bit de-interleave, stores four registers, writeback per W.
pub const @"VST43.16_T1" = mve.Interleaved(false, 16, true, 3).call;
/// VLD43.16 `vld43.16 {Qlist}, [Rn]{!}`: beat 3 of the four-way 16-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD43.16_T1" = mve.Interleaved(true, 16, true, 3).call;
/// VST43.32 `vst43.32 {Qlist}, [Rn]{!}`: beat 3 of the four-way 32-bit de-interleave, stores four registers, writeback per W.
pub const @"VST43.32_T1" = mve.Interleaved(false, 32, true, 3).call;
/// VLD43.32 `vld43.32 {Qlist}, [Rn]{!}`: beat 3 of the four-way 32-bit de-interleave, loads four registers, writeback per W.
pub const @"VLD43.32_T1" = mve.Interleaved(true, 32, true, 3).call;
/// VMOV.16 `vmov.16 Dd[x], Rt`: 16-bit element x of Dd = Rt's low bits.
pub const @"VMOV.16_gpr_lane_T1" = mve.Element(16, false, false).call;
/// VMOV.S16 `vmov.s16 Rt, Dd[x]`: Rt = 16-bit element x of Dd, sign-extended.
pub const @"VMOV.S16_lane_gpr_T1" = mve.Element(16, true, true).call;
/// VMOV.U16 `vmov.u16 Rt, Dd[x]`: Rt = 16-bit element x of Dd, zero-extended.
pub const @"VMOV.U16_lane_gpr_T1" = mve.Element(16, true, false).call;
/// VMOV.8 `vmov.8 Dd[x], Rt`: 8-bit element x of Dd = Rt's low bits.
pub const @"VMOV.8_gpr_lane_T1" = mve.Element(8, false, false).call;
/// VMOV.S8 `vmov.s8 Rt, Dd[x]`: Rt = 8-bit element x of Dd, sign-extended.
pub const @"VMOV.S8_lane_gpr_T1" = mve.Element(8, true, true).call;
/// VMOV.U8 `vmov.u8 Rt, Dd[x]`: Rt = 8-bit element x of Dd, zero-extended.
pub const @"VMOV.U8_lane_gpr_T1" = mve.Element(8, true, false).call;
/// VSHLLB.S8 `vshllb.s8 Qd, Qm, #imm`: signed 8-bit bottom halves of Qm widened, shifted left by imm.
pub const @"VSHLLB.S8_T1" = mve.Widen(8, true, false).call;
/// VSHLLB.S8 `vshllb.s8 Qd, Qm, #8`: signed 8-bit bottom halves of Qm widened and shifted left by 8.
pub const @"VSHLLB.S8_T2" = mve.WidenWhole(8, true, false).call;
/// VQMOVNB.S16 `vqmovnb.s16 Qd, Qm`: saturating narrow of 16-bit lanes into the bottom halves of Qd.
pub const @"VQMOVNB.S16_T1" = mve.Narrow(16, true, true, false, false).call;
/// VQMOVUNB.S16 `vqmovunb.s16 Qd, Qm`: saturating to unsigned narrow of 16-bit lanes into the bottom halves of Qd.
pub const @"VQMOVUNB.S16_T1" = mve.Narrow(16, true, true, true, false).call;
/// VMOVNB.I16 `vmovnb.i16 Qd, Qm`: truncating narrow of 16-bit lanes into the bottom halves of Qd.
pub const @"VMOVNB.I16_T1" = mve.Narrow(16, false, false, false, false).call;
/// VSHLLT.S8 `vshllt.s8 Qd, Qm, #imm`: signed 8-bit top halves of Qm widened, shifted left by imm.
pub const @"VSHLLT.S8_T1" = mve.Widen(8, true, true).call;
/// VSHLLT.S8 `vshllt.s8 Qd, Qm, #8`: signed 8-bit top halves of Qm widened and shifted left by 8.
pub const @"VSHLLT.S8_T2" = mve.WidenWhole(8, true, true).call;
/// VQMOVNT.S16 `vqmovnt.s16 Qd, Qm`: saturating narrow of 16-bit lanes into the top halves of Qd.
pub const @"VQMOVNT.S16_T1" = mve.Narrow(16, true, true, false, true).call;
/// VQMOVUNT.S16 `vqmovunt.s16 Qd, Qm`: saturating to unsigned narrow of 16-bit lanes into the top halves of Qd.
pub const @"VQMOVUNT.S16_T1" = mve.Narrow(16, true, true, true, true).call;
/// VMOVNT.I16 `vmovnt.i16 Qd, Qm`: truncating narrow of 16-bit lanes into the top halves of Qd.
pub const @"VMOVNT.I16_T1" = mve.Narrow(16, false, false, false, true).call;
/// VSHLLB.S16 `vshllb.s16 Qd, Qm, #imm`: signed 16-bit bottom halves of Qm widened, shifted left by imm.
pub const @"VSHLLB.S16_T1" = mve.Widen(16, true, false).call;
/// VSHLLB.S16 `vshllb.s16 Qd, Qm, #16`: signed 16-bit bottom halves of Qm widened and shifted left by 16.
pub const @"VSHLLB.S16_T2" = mve.WidenWhole(16, true, false).call;
/// VQMOVNB.S32 `vqmovnb.s32 Qd, Qm`: saturating narrow of 32-bit lanes into the bottom halves of Qd.
pub const @"VQMOVNB.S32_T1" = mve.Narrow(32, true, true, false, false).call;
/// VQMOVUNB.S32 `vqmovunb.s32 Qd, Qm`: saturating to unsigned narrow of 32-bit lanes into the bottom halves of Qd.
pub const @"VQMOVUNB.S32_T1" = mve.Narrow(32, true, true, true, false).call;
/// VMOVNB.I32 `vmovnb.i32 Qd, Qm`: truncating narrow of 32-bit lanes into the bottom halves of Qd.
pub const @"VMOVNB.I32_T1" = mve.Narrow(32, false, false, false, false).call;
/// VSHLLT.S16 `vshllt.s16 Qd, Qm, #imm`: signed 16-bit top halves of Qm widened, shifted left by imm.
pub const @"VSHLLT.S16_T1" = mve.Widen(16, true, true).call;
/// VSHLLT.S16 `vshllt.s16 Qd, Qm, #16`: signed 16-bit top halves of Qm widened and shifted left by 16.
pub const @"VSHLLT.S16_T2" = mve.WidenWhole(16, true, true).call;
/// VQMOVNT.S32 `vqmovnt.s32 Qd, Qm`: saturating narrow of 32-bit lanes into the top halves of Qd.
pub const @"VQMOVNT.S32_T1" = mve.Narrow(32, true, true, false, true).call;
/// VQMOVUNT.S32 `vqmovunt.s32 Qd, Qm`: saturating to unsigned narrow of 32-bit lanes into the top halves of Qd.
pub const @"VQMOVUNT.S32_T1" = mve.Narrow(32, true, true, true, true).call;
/// VMOVNT.I32 `vmovnt.i32 Qd, Qm`: truncating narrow of 32-bit lanes into the top halves of Qd.
pub const @"VMOVNT.I32_T1" = mve.Narrow(32, false, false, false, true).call;
/// VSHLLB.U8 `vshllb.u8 Qd, Qm, #imm`: unsigned 8-bit bottom halves of Qm widened, shifted left by imm.
pub const @"VSHLLB.U8_T1" = mve.Widen(8, false, false).call;
/// VSHLLB.U8 `vshllb.u8 Qd, Qm, #8`: unsigned 8-bit bottom halves of Qm widened and shifted left by 8.
pub const @"VSHLLB.U8_T2" = mve.WidenWhole(8, false, false).call;
/// VQMOVNB.U16 `vqmovnb.u16 Qd, Qm`: saturating narrow of 16-bit lanes into the bottom halves of Qd.
pub const @"VQMOVNB.U16_T1" = mve.Narrow(16, false, true, false, false).call;
/// VSHLLT.U8 `vshllt.u8 Qd, Qm, #imm`: unsigned 8-bit top halves of Qm widened, shifted left by imm.
pub const @"VSHLLT.U8_T1" = mve.Widen(8, false, true).call;
/// VSHLLT.U8 `vshllt.u8 Qd, Qm, #8`: unsigned 8-bit top halves of Qm widened and shifted left by 8.
pub const @"VSHLLT.U8_T2" = mve.WidenWhole(8, false, true).call;
/// VQMOVNT.U16 `vqmovnt.u16 Qd, Qm`: saturating narrow of 16-bit lanes into the top halves of Qd.
pub const @"VQMOVNT.U16_T1" = mve.Narrow(16, false, true, false, true).call;
/// VSHLLB.U16 `vshllb.u16 Qd, Qm, #imm`: unsigned 16-bit bottom halves of Qm widened, shifted left by imm.
pub const @"VSHLLB.U16_T1" = mve.Widen(16, false, false).call;
/// VSHLLB.U16 `vshllb.u16 Qd, Qm, #16`: unsigned 16-bit bottom halves of Qm widened and shifted left by 16.
pub const @"VSHLLB.U16_T2" = mve.WidenWhole(16, false, false).call;
/// VQMOVNB.U32 `vqmovnb.u32 Qd, Qm`: saturating narrow of 32-bit lanes into the bottom halves of Qd.
pub const @"VQMOVNB.U32_T1" = mve.Narrow(32, false, true, false, false).call;
/// VSHLLT.U16 `vshllt.u16 Qd, Qm, #imm`: unsigned 16-bit top halves of Qm widened, shifted left by imm.
pub const @"VSHLLT.U16_T1" = mve.Widen(16, false, true).call;
/// VSHLLT.U16 `vshllt.u16 Qd, Qm, #16`: unsigned 16-bit top halves of Qm widened and shifted left by 16.
pub const @"VSHLLT.U16_T2" = mve.WidenWhole(16, false, true).call;
/// VQMOVNT.U32 `vqmovnt.u32 Qd, Qm`: saturating narrow of 32-bit lanes into the top halves of Qd.
pub const @"VQMOVNT.U32_T1" = mve.Narrow(32, false, true, false, true).call;
/// VSHRNB.I16 `vshrnb.i16 Qd, Qm, #imm`: right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VSHRNB.I16_T1" = mve.NarrowShift(16, false, false, false, false, false).call;
/// VSHRNT.I16 `vshrnt.i16 Qd, Qm, #imm`: right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VSHRNT.I16_T1" = mve.NarrowShift(16, false, false, false, false, true).call;
/// VSHRNB.I32 `vshrnb.i32 Qd, Qm, #imm`: right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VSHRNB.I32_T1" = mve.NarrowShift(32, false, false, false, false, false).call;
/// VSHRNT.I32 `vshrnt.i32 Qd, Qm, #imm`: right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VSHRNT.I32_T1" = mve.NarrowShift(32, false, false, false, false, true).call;
/// VRSHRNB.I16 `vrshrnb.i16 Qd, Qm, #imm`: rounding right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VRSHRNB.I16_T1" = mve.NarrowShift(16, false, true, false, false, false).call;
/// VRSHRNT.I16 `vrshrnt.i16 Qd, Qm, #imm`: rounding right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VRSHRNT.I16_T1" = mve.NarrowShift(16, false, true, false, false, true).call;
/// VRSHRNB.I32 `vrshrnb.i32 Qd, Qm, #imm`: rounding right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VRSHRNB.I32_T1" = mve.NarrowShift(32, false, true, false, false, false).call;
/// VRSHRNT.I32 `vrshrnt.i32 Qd, Qm, #imm`: rounding right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VRSHRNT.I32_T1" = mve.NarrowShift(32, false, true, false, false, true).call;
/// VQSHRUNB.S16 `vqshrunb.s16 Qd, Qm, #imm`: saturating to unsigned right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRUNB.S16_T1" = mve.NarrowShift(16, true, false, true, true, false).call;
/// VQSHRUNT.S16 `vqshrunt.s16 Qd, Qm, #imm`: saturating to unsigned right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRUNT.S16_T1" = mve.NarrowShift(16, true, false, true, true, true).call;
/// VQSHRUNB.S32 `vqshrunb.s32 Qd, Qm, #imm`: saturating to unsigned right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRUNB.S32_T1" = mve.NarrowShift(32, true, false, true, true, false).call;
/// VQSHRUNT.S32 `vqshrunt.s32 Qd, Qm, #imm`: saturating to unsigned right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRUNT.S32_T1" = mve.NarrowShift(32, true, false, true, true, true).call;
/// VQRSHRUNB.S16 `vqrshrunb.s16 Qd, Qm, #imm`: rounding saturating to unsigned right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRUNB.S16_T1" = mve.NarrowShift(16, true, true, true, true, false).call;
/// VQRSHRUNT.S16 `vqrshrunt.s16 Qd, Qm, #imm`: rounding saturating to unsigned right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRUNT.S16_T1" = mve.NarrowShift(16, true, true, true, true, true).call;
/// VQRSHRUNB.S32 `vqrshrunb.s32 Qd, Qm, #imm`: rounding saturating to unsigned right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRUNB.S32_T1" = mve.NarrowShift(32, true, true, true, true, false).call;
/// VQRSHRUNT.S32 `vqrshrunt.s32 Qd, Qm, #imm`: rounding saturating to unsigned right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRUNT.S32_T1" = mve.NarrowShift(32, true, true, true, true, true).call;
/// VQSHRNB.S16 `vqshrnb.s16 Qd, Qm, #imm`: saturating right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRNB.S16_T1" = mve.NarrowShift(16, true, false, true, false, false).call;
/// VQSHRNT.S16 `vqshrnt.s16 Qd, Qm, #imm`: saturating right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRNT.S16_T1" = mve.NarrowShift(16, true, false, true, false, true).call;
/// VQSHRNB.S32 `vqshrnb.s32 Qd, Qm, #imm`: saturating right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRNB.S32_T1" = mve.NarrowShift(32, true, false, true, false, false).call;
/// VQSHRNT.S32 `vqshrnt.s32 Qd, Qm, #imm`: saturating right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRNT.S32_T1" = mve.NarrowShift(32, true, false, true, false, true).call;
/// VQSHRNB.U16 `vqshrnb.u16 Qd, Qm, #imm`: saturating right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRNB.U16_T1" = mve.NarrowShift(16, false, false, true, false, false).call;
/// VQSHRNT.U16 `vqshrnt.u16 Qd, Qm, #imm`: saturating right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRNT.U16_T1" = mve.NarrowShift(16, false, false, true, false, true).call;
/// VQSHRNB.U32 `vqshrnb.u32 Qd, Qm, #imm`: saturating right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQSHRNB.U32_T1" = mve.NarrowShift(32, false, false, true, false, false).call;
/// VQSHRNT.U32 `vqshrnt.u32 Qd, Qm, #imm`: saturating right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQSHRNT.U32_T1" = mve.NarrowShift(32, false, false, true, false, true).call;
/// VQRSHRNB.S16 `vqrshrnb.s16 Qd, Qm, #imm`: rounding saturating right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRNB.S16_T1" = mve.NarrowShift(16, true, true, true, false, false).call;
/// VQRSHRNT.S16 `vqrshrnt.s16 Qd, Qm, #imm`: rounding saturating right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRNT.S16_T1" = mve.NarrowShift(16, true, true, true, false, true).call;
/// VQRSHRNB.S32 `vqrshrnb.s32 Qd, Qm, #imm`: rounding saturating right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRNB.S32_T1" = mve.NarrowShift(32, true, true, true, false, false).call;
/// VQRSHRNT.S32 `vqrshrnt.s32 Qd, Qm, #imm`: rounding saturating right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRNT.S32_T1" = mve.NarrowShift(32, true, true, true, false, true).call;
/// VQRSHRNB.U16 `vqrshrnb.u16 Qd, Qm, #imm`: rounding saturating right shift of 16-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRNB.U16_T1" = mve.NarrowShift(16, false, true, true, false, false).call;
/// VQRSHRNT.U16 `vqrshrnt.u16 Qd, Qm, #imm`: rounding saturating right shift of 16-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRNT.U16_T1" = mve.NarrowShift(16, false, true, true, false, true).call;
/// VQRSHRNB.U32 `vqrshrnb.u32 Qd, Qm, #imm`: rounding saturating right shift of 32-bit lanes narrowed into Qd's bottom halves.
pub const @"VQRSHRNB.U32_T1" = mve.NarrowShift(32, false, true, true, false, false).call;
/// VQRSHRNT.U32 `vqrshrnt.u32 Qd, Qm, #imm`: rounding saturating right shift of 32-bit lanes narrowed into Qd's top halves.
pub const @"VQRSHRNT.U32_T1" = mve.NarrowShift(32, false, true, true, false, true).call;
/// VMOV/VORR immediate, cmode xxxx: expanded imm8 replaces or ORs into Qd lanes.
pub const VMOV_imm_vec_T1 = mve.Constant(false, 0).call;
/// VMVN/VBIC immediate, cmode 0xxx: inverted expanded imm8 replaces or masks Qd lanes.
pub const VMVN_imm_T1_cmode0 = mve.Constant(true, 0).call;
/// VMVN/VBIC immediate, cmode 10xx: inverted expanded imm8 replaces or masks Qd lanes.
pub const VMVN_imm_T1_cmode10 = mve.Constant(true, 8).call;
/// VMVN/VBIC immediate, cmode 110x: inverted expanded imm8 replaces or masks Qd lanes.
pub const VMVN_imm_T1_cmode110 = mve.Constant(true, 12).call;
/// VMOV.I64 immediate, cmode 1110: each imm8 bit fills a byte of Qd.
pub const @"VMOV.I64_imm_T1_cmode1110" = mve.ConstantFixed(true, 14).call;
/// VIDUP.U8 `vidup.u8 Qd, Rn, #imm`: 8-bit lanes count up from Rn by imm, Rn advanced past the last.
pub const @"VIDUP.U8_T2" = mve.Counter(8, true).call;
/// VIWDUP.U8 `viwdup.u8 Qd, Rn, Rm, #imm`: 8-bit lanes count up from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VIWDUP.U8_T1_r1" = mve.CounterWrapping(8, true, 0).call;
/// VIWDUP.U8 `viwdup.u8 Qd, Rn, Rm, #imm`: 8-bit lanes count up from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VIWDUP.U8_T1_r9" = mve.CounterWrapping(8, true, 4).call;
/// VDDUP.U8 `vddup.u8 Qd, Rn, #imm`: 8-bit lanes count down from Rn by imm, Rn advanced past the last.
pub const @"VDDUP.U8_T2" = mve.Counter(8, false).call;
/// VDWDUP.U8 `vdwdup.u8 Qd, Rn, Rm, #imm`: 8-bit lanes count down from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VDWDUP.U8_T1_r1" = mve.CounterWrapping(8, false, 0).call;
/// VDWDUP.U8 `vdwdup.u8 Qd, Rn, Rm, #imm`: 8-bit lanes count down from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VDWDUP.U8_T1_r9" = mve.CounterWrapping(8, false, 4).call;
/// VIDUP.U16 `vidup.u16 Qd, Rn, #imm`: 16-bit lanes count up from Rn by imm, Rn advanced past the last.
pub const @"VIDUP.U16_T2" = mve.Counter(16, true).call;
/// VIWDUP.U16 `viwdup.u16 Qd, Rn, Rm, #imm`: 16-bit lanes count up from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VIWDUP.U16_T1_r1" = mve.CounterWrapping(16, true, 0).call;
/// VIWDUP.U16 `viwdup.u16 Qd, Rn, Rm, #imm`: 16-bit lanes count up from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VIWDUP.U16_T1_r9" = mve.CounterWrapping(16, true, 4).call;
/// VDDUP.U16 `vddup.u16 Qd, Rn, #imm`: 16-bit lanes count down from Rn by imm, Rn advanced past the last.
pub const @"VDDUP.U16_T2" = mve.Counter(16, false).call;
/// VDWDUP.U16 `vdwdup.u16 Qd, Rn, Rm, #imm`: 16-bit lanes count down from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VDWDUP.U16_T1_r1" = mve.CounterWrapping(16, false, 0).call;
/// VDWDUP.U16 `vdwdup.u16 Qd, Rn, Rm, #imm`: 16-bit lanes count down from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VDWDUP.U16_T1_r9" = mve.CounterWrapping(16, false, 4).call;
/// VIDUP.U32 `vidup.u32 Qd, Rn, #imm`: 32-bit lanes count up from Rn by imm, Rn advanced past the last.
pub const @"VIDUP.U32_T2" = mve.Counter(32, true).call;
/// VIWDUP.U32 `viwdup.u32 Qd, Rn, Rm, #imm`: 32-bit lanes count up from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VIWDUP.U32_T1_r1" = mve.CounterWrapping(32, true, 0).call;
/// VIWDUP.U32 `viwdup.u32 Qd, Rn, Rm, #imm`: 32-bit lanes count up from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VIWDUP.U32_T1_r9" = mve.CounterWrapping(32, true, 4).call;
/// VDDUP.U32 `vddup.u32 Qd, Rn, #imm`: 32-bit lanes count down from Rn by imm, Rn advanced past the last.
pub const @"VDDUP.U32_T2" = mve.Counter(32, false).call;
/// VDWDUP.U32 `vdwdup.u32 Qd, Rn, Rm, #imm`: 32-bit lanes count down from Rn by imm, wrapping at Rm, Rm r1-r7.
pub const @"VDWDUP.U32_T1_r1" = mve.CounterWrapping(32, false, 0).call;
/// VDWDUP.U32 `vdwdup.u32 Qd, Rn, Rm, #imm`: 32-bit lanes count down from Rn by imm, wrapping at Rm, Rm r9/r11.
pub const @"VDWDUP.U32_T1_r9" = mve.CounterWrapping(32, false, 4).call;
/// VADDV/VADDVA: sum of signed 8-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.S8_T1" = mve.Across(8, true).call;
/// VABAV.S8 `vabav.s8 Rt, Qn, Qm`: Rda += absolute differences of signed 8-bit lanes of Qn and Qm.
pub const @"VABAV.S8_T1" = mve.Difference(8, true).call;
/// VMAXV.S8 `vmaxv.s8 Rt, Qm`: Rda = max across Rda and the signed 8-bit lanes of Qm.
pub const @"VMAXV.S8_T1" = mve.Extremum(8, true, false, true).call;
/// VMAXAV.S8 `vmaxav.s8 Rt, Qm`: Rda = max of absolute values across Rda and the signed 8-bit lanes of Qm.
pub const @"VMAXAV.S8_T2" = mve.Extremum(8, true, true, true).call;
/// VMAXA.S8 `vmaxa.s8 Qd, Qm`: each unsigned 8-bit lane Qd = max(Qd, |Qm|), under the predicate.
pub const @"VMAXA.S8_T2" = mve.Extreme(8, true).call;
/// VMINV.S8 `vminv.s8 Rt, Qm`: Rda = min across Rda and the signed 8-bit lanes of Qm.
pub const @"VMINV.S8_T1" = mve.Extremum(8, true, false, false).call;
/// VMINAV.S8 `vminav.s8 Rt, Qm`: Rda = min of absolute values across Rda and the signed 8-bit lanes of Qm.
pub const @"VMINAV.S8_T2" = mve.Extremum(8, true, true, false).call;
/// VMINA.S8 `vmina.s8 Qd, Qm`: each unsigned 8-bit lane Qd = min(Qd, |Qm|), under the predicate.
pub const @"VMINA.S8_T2" = mve.Extreme(8, false).call;
/// VADDV/VADDVA: sum of signed 16-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.S16_T1" = mve.Across(16, true).call;
/// VABAV.S16 `vabav.s16 Rt, Qn, Qm`: Rda += absolute differences of signed 16-bit lanes of Qn and Qm.
pub const @"VABAV.S16_T1" = mve.Difference(16, true).call;
/// VMAXV.S16 `vmaxv.s16 Rt, Qm`: Rda = max across Rda and the signed 16-bit lanes of Qm.
pub const @"VMAXV.S16_T1" = mve.Extremum(16, true, false, true).call;
/// VMAXAV.S16 `vmaxav.s16 Rt, Qm`: Rda = max of absolute values across Rda and the signed 16-bit lanes of Qm.
pub const @"VMAXAV.S16_T2" = mve.Extremum(16, true, true, true).call;
/// VMAXA.S16 `vmaxa.s16 Qd, Qm`: each unsigned 16-bit lane Qd = max(Qd, |Qm|), under the predicate.
pub const @"VMAXA.S16_T2" = mve.Extreme(16, true).call;
/// VMINV.S16 `vminv.s16 Rt, Qm`: Rda = min across Rda and the signed 16-bit lanes of Qm.
pub const @"VMINV.S16_T1" = mve.Extremum(16, true, false, false).call;
/// VMINAV.S16 `vminav.s16 Rt, Qm`: Rda = min of absolute values across Rda and the signed 16-bit lanes of Qm.
pub const @"VMINAV.S16_T2" = mve.Extremum(16, true, true, false).call;
/// VMINA.S16 `vmina.s16 Qd, Qm`: each unsigned 16-bit lane Qd = min(Qd, |Qm|), under the predicate.
pub const @"VMINA.S16_T2" = mve.Extreme(16, false).call;
/// VADDV/VADDVA: sum of signed 32-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.S32_T1" = mve.Across(32, true).call;
/// VABAV.S32 `vabav.s32 Rt, Qn, Qm`: Rda += absolute differences of signed 32-bit lanes of Qn and Qm.
pub const @"VABAV.S32_T1" = mve.Difference(32, true).call;
/// VMAXV.S32 `vmaxv.s32 Rt, Qm`: Rda = max across Rda and the signed 32-bit lanes of Qm.
pub const @"VMAXV.S32_T1" = mve.Extremum(32, true, false, true).call;
/// VMAXAV.S32 `vmaxav.s32 Rt, Qm`: Rda = max of absolute values across Rda and the signed 32-bit lanes of Qm.
pub const @"VMAXAV.S32_T2" = mve.Extremum(32, true, true, true).call;
/// VMAXA.S32 `vmaxa.s32 Qd, Qm`: each unsigned 32-bit lane Qd = max(Qd, |Qm|), under the predicate.
pub const @"VMAXA.S32_T2" = mve.Extreme(32, true).call;
/// VMINV.S32 `vminv.s32 Rt, Qm`: Rda = min across Rda and the signed 32-bit lanes of Qm.
pub const @"VMINV.S32_T1" = mve.Extremum(32, true, false, false).call;
/// VMINAV.S32 `vminav.s32 Rt, Qm`: Rda = min of absolute values across Rda and the signed 32-bit lanes of Qm.
pub const @"VMINAV.S32_T2" = mve.Extremum(32, true, true, false).call;
/// VMINA.S32 `vmina.s32 Qd, Qm`: each unsigned 32-bit lane Qd = min(Qd, |Qm|), under the predicate.
pub const @"VMINA.S32_T2" = mve.Extreme(32, false).call;
/// VADDLV/VADDLVA: 64-bit sum of signed 32-bit lanes into RdaHi:RdaLo, RdaHi r1-r7.
pub const @"VADDLV.S32_T1_r1" = mve.AcrossLong(true, 0).call;
/// VADDLV/VADDLVA: 64-bit sum of signed 32-bit lanes into RdaHi:RdaLo, RdaHi r9/r11.
pub const @"VADDLV.S32_T1_r9" = mve.AcrossLong(true, 4).call;
/// VADDV/VADDVA: sum of unsigned 8-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.U8_T1" = mve.Across(8, false).call;
/// VABAV.U8 `vabav.u8 Rt, Qn, Qm`: Rda += absolute differences of unsigned 8-bit lanes of Qn and Qm.
pub const @"VABAV.U8_T1" = mve.Difference(8, false).call;
/// VMAXV.U8 `vmaxv.u8 Rt, Qm`: Rda = max across Rda and the unsigned 8-bit lanes of Qm.
pub const @"VMAXV.U8_T1" = mve.Extremum(8, false, false, true).call;
/// VMINV.U8 `vminv.u8 Rt, Qm`: Rda = min across Rda and the unsigned 8-bit lanes of Qm.
pub const @"VMINV.U8_T1" = mve.Extremum(8, false, false, false).call;
/// VADDV/VADDVA: sum of unsigned 16-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.U16_T1" = mve.Across(16, false).call;
/// VABAV.U16 `vabav.u16 Rt, Qn, Qm`: Rda += absolute differences of unsigned 16-bit lanes of Qn and Qm.
pub const @"VABAV.U16_T1" = mve.Difference(16, false).call;
/// VMAXV.U16 `vmaxv.u16 Rt, Qm`: Rda = max across Rda and the unsigned 16-bit lanes of Qm.
pub const @"VMAXV.U16_T1" = mve.Extremum(16, false, false, true).call;
/// VMINV.U16 `vminv.u16 Rt, Qm`: Rda = min across Rda and the unsigned 16-bit lanes of Qm.
pub const @"VMINV.U16_T1" = mve.Extremum(16, false, false, false).call;
/// VADDV/VADDVA: sum of unsigned 32-bit lanes of Qm into Rda, A accumulating.
pub const @"VADDV.U32_T1" = mve.Across(32, false).call;
/// VABAV.U32 `vabav.u32 Rt, Qn, Qm`: Rda += absolute differences of unsigned 32-bit lanes of Qn and Qm.
pub const @"VABAV.U32_T1" = mve.Difference(32, false).call;
/// VMAXV.U32 `vmaxv.u32 Rt, Qm`: Rda = max across Rda and the unsigned 32-bit lanes of Qm.
pub const @"VMAXV.U32_T1" = mve.Extremum(32, false, false, true).call;
/// VMINV.U32 `vminv.u32 Rt, Qm`: Rda = min across Rda and the unsigned 32-bit lanes of Qm.
pub const @"VMINV.U32_T1" = mve.Extremum(32, false, false, false).call;
/// VADDLV/VADDLVA: 64-bit sum of unsigned 32-bit lanes into RdaHi:RdaLo, RdaHi r1-r7.
pub const @"VADDLV.U32_T1_r1" = mve.AcrossLong(false, 0).call;
/// VADDLV/VADDLVA: 64-bit sum of unsigned 32-bit lanes into RdaHi:RdaLo, RdaHi r9/r11.
pub const @"VADDLV.U32_T1_r9" = mve.AcrossLong(false, 4).call;
/// VMLADAV(X): adds signed 16-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLADAV.S16_T1" = mve.ProductsExchange(16, true, false).call;
/// VMLADAV(X): adds signed 32-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLADAV.S32_T1" = mve.ProductsExchange(32, true, false).call;
/// VMLADAV(X): adds signed 8-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLADAV.S8_T2" = mve.ProductsExchange(8, true, false).call;
/// VMLAV/VMLAVA: adds the unsigned 16-bit lane products of Qn and Qm into Rda.
pub const @"VMLAV.U16_T1" = mve.Products(16, false, false).call;
/// VMLAV/VMLAVA: adds the unsigned 32-bit lane products of Qn and Qm into Rda.
pub const @"VMLAV.U32_T1" = mve.Products(32, false, false).call;
/// VMLAV/VMLAVA: adds the unsigned 8-bit lane products of Qn and Qm into Rda.
pub const @"VMLAV.U8_T2" = mve.Products(8, false, false).call;
/// VMLSDAV(X): subtracts signed 16-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLSDAV.S16_T1" = mve.ProductsExchange(16, true, true).call;
/// VMLSDAV(X): subtracts signed 32-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLSDAV.S32_T1" = mve.ProductsExchange(32, true, true).call;
/// VMLSDAV(X): subtracts signed 8-bit lane products into Rda, X exchanging Qm pairs.
pub const @"VMLSDAV.S8_T2" = mve.ProductsExchange(8, true, true).call;
/// VMLALDAV(X): 64-bit sum of signed 16-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VMLALDAV.S16_T1_r1" = mve.ProductsLongExchange(16, true, false, false, 0).call;
/// VMLALDAV(X): 64-bit sum of signed 32-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VMLALDAV.S32_T1_r1" = mve.ProductsLongExchange(32, true, false, false, 0).call;
/// VRMLALDAVH(X): 64-bit sum of signed 32-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VRMLALDAVH.S32_T1_r1" = mve.ProductsLongExchange(32, true, false, true, 0).call;
/// VMLALDAV: 64-bit sum of unsigned 16-bit lane products into RdaHi:RdaLo, RdaHi r1-r7.
pub const @"VMLALDAV.U16_T1_r1" = mve.ProductsLong(16, false, false, false, 0).call;
/// VMLALDAV: 64-bit sum of unsigned 32-bit lane products into RdaHi:RdaLo, RdaHi r1-r7.
pub const @"VMLALDAV.U32_T1_r1" = mve.ProductsLong(32, false, false, false, 0).call;
/// VRMLALDAVH: 64-bit sum of unsigned 32-bit lane products into RdaHi:RdaLo, RdaHi r1-r7.
pub const @"VRMLALDAVH.U32_T1_r1" = mve.ProductsLong(32, false, false, true, 0).call;
/// VMLSLDAV(X): 64-bit difference of signed 16-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VMLSLDAV.S16_T1_r1" = mve.ProductsLongExchange(16, true, true, false, 0).call;
/// VMLSLDAV(X): 64-bit difference of signed 32-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VMLSLDAV.S32_T1_r1" = mve.ProductsLongExchange(32, true, true, false, 0).call;
/// VRMLSLDAVH(X): 64-bit difference of signed 32-bit lane products, X exchanging, RdaHi r1-r7.
pub const @"VRMLSLDAVH.S32_T1_r1" = mve.ProductsLongExchange(32, true, true, true, 0).call;
/// VMLALDAV(X): 64-bit sum of signed 16-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VMLALDAV.S16_T1_r9" = mve.ProductsLongExchange(16, true, false, false, 4).call;
/// VMLALDAV(X): 64-bit sum of signed 32-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VMLALDAV.S32_T1_r9" = mve.ProductsLongExchange(32, true, false, false, 4).call;
/// VRMLALDAVH(X): 64-bit sum of signed 32-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VRMLALDAVH.S32_T1_r9" = mve.ProductsLongExchange(32, true, false, true, 4).call;
/// VMLALDAV: 64-bit sum of unsigned 16-bit lane products into RdaHi:RdaLo, RdaHi r9/r11.
pub const @"VMLALDAV.U16_T1_r9" = mve.ProductsLong(16, false, false, false, 4).call;
/// VMLALDAV: 64-bit sum of unsigned 32-bit lane products into RdaHi:RdaLo, RdaHi r9/r11.
pub const @"VMLALDAV.U32_T1_r9" = mve.ProductsLong(32, false, false, false, 4).call;
/// VRMLALDAVH: 64-bit sum of unsigned 32-bit lane products into RdaHi:RdaLo, RdaHi r9/r11.
pub const @"VRMLALDAVH.U32_T1_r9" = mve.ProductsLong(32, false, false, true, 4).call;
/// VMLSLDAV(X): 64-bit difference of signed 16-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VMLSLDAV.S16_T1_r9" = mve.ProductsLongExchange(16, true, true, false, 4).call;
/// VMLSLDAV(X): 64-bit difference of signed 32-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VMLSLDAV.S32_T1_r9" = mve.ProductsLongExchange(32, true, true, false, 4).call;
/// VRMLSLDAVH(X): 64-bit difference of signed 32-bit lane products, X exchanging, RdaHi r9/r11.
pub const @"VRMLSLDAVH.S32_T1_r9" = mve.ProductsLongExchange(32, true, true, true, 4).call;
/// VMULH.S8 `vmulh.s8 Qd, Qn, Qm`: high half of each signed 8-bit product of Qn and Qm.
pub const @"VMULH.S8_T1" = mve.Product(8, true, false, false, false).call;
/// VRMULH.S8 `vrmulh.s8 Qd, Qn, Qm`: high half of each rounding signed 8-bit product of Qn and Qm.
pub const @"VRMULH.S8_T2" = mve.Product(8, true, false, true, false).call;
/// VMULLB.S8 `vmullb.s8 Qd, Qn, Qm`: signed 8-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.S8_int_T1" = mve.Widening(8, true, false, false, false).call;
/// VMULLT.S8 `vmullt.s8 Qd, Qn, Qm`: signed 8-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.S8_int_T1" = mve.Widening(8, true, false, true, false).call;
/// VMULH.S16 `vmulh.s16 Qd, Qn, Qm`: high half of each signed 16-bit product of Qn and Qm.
pub const @"VMULH.S16_T1" = mve.Product(16, true, false, false, false).call;
/// VRMULH.S16 `vrmulh.s16 Qd, Qn, Qm`: high half of each rounding signed 16-bit product of Qn and Qm.
pub const @"VRMULH.S16_T2" = mve.Product(16, true, false, true, false).call;
/// VMULLB.S16 `vmullb.s16 Qd, Qn, Qm`: signed 16-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.S16_int_T1" = mve.Widening(16, true, false, false, false).call;
/// VMULLT.S16 `vmullt.s16 Qd, Qn, Qm`: signed 16-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.S16_int_T1" = mve.Widening(16, true, false, true, false).call;
/// VMULH.S32 `vmulh.s32 Qd, Qn, Qm`: high half of each signed 32-bit product of Qn and Qm.
pub const @"VMULH.S32_T1" = mve.Product(32, true, false, false, false).call;
/// VRMULH.S32 `vrmulh.s32 Qd, Qn, Qm`: high half of each rounding signed 32-bit product of Qn and Qm.
pub const @"VRMULH.S32_T2" = mve.Product(32, true, false, true, false).call;
/// VMULLB.S32 `vmullb.s32 Qd, Qn, Qm`: signed 32-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.S32_int_T1" = mve.Widening(32, true, false, false, false).call;
/// VMULLT.S32 `vmullt.s32 Qd, Qn, Qm`: signed 32-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.S32_int_T1" = mve.Widening(32, true, false, true, false).call;
/// VMULLB.P8 `vmullb.p8 Qd, Qn, Qm`: carry-less 8-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.P8_poly_T1" = mve.Polynomial(8, false).call;
/// VMULLT.P8 `vmullt.p8 Qd, Qn, Qm`: carry-less 8-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.P8_poly_T1" = mve.Polynomial(8, true).call;
/// VMULH.U8 `vmulh.u8 Qd, Qn, Qm`: high half of each unsigned 8-bit product of Qn and Qm.
pub const @"VMULH.U8_T1" = mve.Product(8, false, false, false, false).call;
/// VRMULH.U8 `vrmulh.u8 Qd, Qn, Qm`: high half of each rounding unsigned 8-bit product of Qn and Qm.
pub const @"VRMULH.U8_T2" = mve.Product(8, false, false, true, false).call;
/// VMULLB.U8 `vmullb.u8 Qd, Qn, Qm`: unsigned 8-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.U8_int_T1" = mve.Widening(8, false, false, false, false).call;
/// VMULLT.U8 `vmullt.u8 Qd, Qn, Qm`: unsigned 8-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.U8_int_T1" = mve.Widening(8, false, false, true, false).call;
/// VMULH.U16 `vmulh.u16 Qd, Qn, Qm`: high half of each unsigned 16-bit product of Qn and Qm.
pub const @"VMULH.U16_T1" = mve.Product(16, false, false, false, false).call;
/// VRMULH.U16 `vrmulh.u16 Qd, Qn, Qm`: high half of each rounding unsigned 16-bit product of Qn and Qm.
pub const @"VRMULH.U16_T2" = mve.Product(16, false, false, true, false).call;
/// VMULLB.U16 `vmullb.u16 Qd, Qn, Qm`: unsigned 16-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.U16_int_T1" = mve.Widening(16, false, false, false, false).call;
/// VMULLT.U16 `vmullt.u16 Qd, Qn, Qm`: unsigned 16-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.U16_int_T1" = mve.Widening(16, false, false, true, false).call;
/// VMULH.U32 `vmulh.u32 Qd, Qn, Qm`: high half of each unsigned 32-bit product of Qn and Qm.
pub const @"VMULH.U32_T1" = mve.Product(32, false, false, false, false).call;
/// VRMULH.U32 `vrmulh.u32 Qd, Qn, Qm`: high half of each rounding unsigned 32-bit product of Qn and Qm.
pub const @"VRMULH.U32_T2" = mve.Product(32, false, false, true, false).call;
/// VMULLB.U32 `vmullb.u32 Qd, Qn, Qm`: unsigned 32-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.U32_int_T1" = mve.Widening(32, false, false, false, false).call;
/// VMULLT.U32 `vmullt.u32 Qd, Qn, Qm`: unsigned 32-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.U32_int_T1" = mve.Widening(32, false, false, true, false).call;
/// VMULLB.P16 `vmullb.p16 Qd, Qn, Qm`: carry-less 16-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VMULLB.P16_poly_T1" = mve.Polynomial(16, false).call;
/// VMULLT.P16 `vmullt.p16 Qd, Qn, Qm`: carry-less 16-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VMULLT.P16_poly_T1" = mve.Polynomial(16, true).call;
/// VQDMULH.S8 `vqdmulh.s8 Qd, Qn, Qm`: high half of each doubling saturating signed 8-bit product of Qn and Qm.
pub const @"VQDMULH.S8_T1" = mve.Product(8, true, true, false, false).call;
/// VQDMULH.S8 `vqdmulh.s8 Qd, Qn, Rt`: high half of each doubling saturating signed 8-bit product of Qn and Rt broadcast.
pub const @"VQDMULH.S8_T3" = mve.Product(8, true, true, false, true).call;
/// VQDMULH.S16 `vqdmulh.s16 Qd, Qn, Qm`: high half of each doubling saturating signed 16-bit product of Qn and Qm.
pub const @"VQDMULH.S16_T1" = mve.Product(16, true, true, false, false).call;
/// VQDMULH.S16 `vqdmulh.s16 Qd, Qn, Rt`: high half of each doubling saturating signed 16-bit product of Qn and Rt broadcast.
pub const @"VQDMULH.S16_T3" = mve.Product(16, true, true, false, true).call;
/// VQDMULH.S32 `vqdmulh.s32 Qd, Qn, Qm`: high half of each doubling saturating signed 32-bit product of Qn and Qm.
pub const @"VQDMULH.S32_T1" = mve.Product(32, true, true, false, false).call;
/// VQDMULH.S32 `vqdmulh.s32 Qd, Qn, Rt`: high half of each doubling saturating signed 32-bit product of Qn and Rt broadcast.
pub const @"VQDMULH.S32_T3" = mve.Product(32, true, true, false, true).call;
/// VQRDMULH.S8 `vqrdmulh.s8 Qd, Qn, Qm`: high half of each rounding doubling saturating signed 8-bit product of Qn and Qm.
pub const @"VQRDMULH.S8_T2" = mve.Product(8, true, true, true, false).call;
/// VQRDMULH.S8 `vqrdmulh.s8 Qd, Qn, Rt`: high half of each rounding doubling saturating signed 8-bit product of Qn and Rt broadcast.
pub const @"VQRDMULH.S8_T4" = mve.Product(8, true, true, true, true).call;
/// VQRDMULH.S16 `vqrdmulh.s16 Qd, Qn, Qm`: high half of each rounding doubling saturating signed 16-bit product of Qn and Qm.
pub const @"VQRDMULH.S16_T2" = mve.Product(16, true, true, true, false).call;
/// VQRDMULH.S16 `vqrdmulh.s16 Qd, Qn, Rt`: high half of each rounding doubling saturating signed 16-bit product of Qn and Rt broadcast.
pub const @"VQRDMULH.S16_T4" = mve.Product(16, true, true, true, true).call;
/// VQRDMULH.S32 `vqrdmulh.s32 Qd, Qn, Qm`: high half of each rounding doubling saturating signed 32-bit product of Qn and Qm.
pub const @"VQRDMULH.S32_T2" = mve.Product(32, true, true, true, false).call;
/// VQRDMULH.S32 `vqrdmulh.s32 Qd, Qn, Rt`: high half of each rounding doubling saturating signed 32-bit product of Qn and Rt broadcast.
pub const @"VQRDMULH.S32_T4" = mve.Product(32, true, true, true, true).call;
/// VQDMULLB.S16 `vqdmullb.s16 Qd, Qn, Qm`: doubling saturating signed 16-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VQDMULLB.S16_T1" = mve.Widening(16, true, true, false, false).call;
/// VQDMULLB.S16 `vqdmullb.s16 Qd, Qn, Rt`: doubling saturating signed 16-bit bottom-half products of Qn and Rt broadcast, widened into Qd.
pub const @"VQDMULLB.S16_T2" = mve.Widening(16, true, true, false, true).call;
/// VQDMULLT.S16 `vqdmullt.s16 Qd, Qn, Qm`: doubling saturating signed 16-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VQDMULLT.S16_T1" = mve.Widening(16, true, true, true, false).call;
/// VQDMULLT.S16 `vqdmullt.s16 Qd, Qn, Rt`: doubling saturating signed 16-bit top-half products of Qn and Rt broadcast, widened into Qd.
pub const @"VQDMULLT.S16_T2" = mve.Widening(16, true, true, true, true).call;
/// VQDMULLB.S32 `vqdmullb.s32 Qd, Qn, Qm`: doubling saturating signed 32-bit bottom-half products of Qn and Qm, widened into Qd.
pub const @"VQDMULLB.S32_T1" = mve.Widening(32, true, true, false, false).call;
/// VQDMULLB.S32 `vqdmullb.s32 Qd, Qn, Rt`: doubling saturating signed 32-bit bottom-half products of Qn and Rt broadcast, widened into Qd.
pub const @"VQDMULLB.S32_T2" = mve.Widening(32, true, true, false, true).call;
/// VQDMULLT.S32 `vqdmullt.s32 Qd, Qn, Qm`: doubling saturating signed 32-bit top-half products of Qn and Qm, widened into Qd.
pub const @"VQDMULLT.S32_T1" = mve.Widening(32, true, true, true, false).call;
/// VQDMULLT.S32 `vqdmullt.s32 Qd, Qn, Rt`: doubling saturating signed 32-bit top-half products of Qn and Rt broadcast, widened into Qd.
pub const @"VQDMULLT.S32_T2" = mve.Widening(32, true, true, true, true).call;
/// VQDMLADH.S8 `vqdmladh.s8 Qd, Qn, Qm`: doubling saturating sum of paired 8-bit lane products of Qn and Qm.
pub const @"VQDMLADH.S8_T1" = mve.Doubled(8, false, false, false).call;
/// VQRDMLADH.S8 `vqrdmladh.s8 Qd, Qn, Qm`: rounding doubling saturating sum of paired 8-bit lane products of Qn and Qm.
pub const @"VQRDMLADH.S8_T2" = mve.Doubled(8, false, false, true).call;
/// VQDMLADHX.S8 `vqdmladhx.s8 Qd, Qn, Qm`: doubling saturating sum of paired 8-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLADHX.S8_T1" = mve.Doubled(8, true, false, false).call;
/// VQRDMLADHX.S8 `vqrdmladhx.s8 Qd, Qn, Qm`: rounding doubling saturating sum of paired 8-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLADHX.S8_T2" = mve.Doubled(8, true, false, true).call;
/// VQRDMLAH.S8 `vqrdmlah.s8 Qd, Qn, Rt`: rounding doubling saturating 8-bit Qd += Qn*Rt, high halves kept.
pub const @"VQRDMLAH.S8_vsv_T2" = mve.Accumulated(8, true, false).call;
/// VQDMLAH.S8 `vqdmlah.s8 Qd, Qn, Rt`: doubling saturating 8-bit Qd += Qn*Rt, high halves kept.
pub const @"VQDMLAH.S8_vsv_T1" = mve.Accumulated(8, false, false).call;
/// VQRDMLASH.S8 `vqrdmlash.s8 Qd, Qn, Rt`: rounding doubling saturating 8-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQRDMLASH.S8_vvs_T2" = mve.Accumulated(8, true, true).call;
/// VQDMLASH.S8 `vqdmlash.s8 Qd, Qn, Rt`: doubling saturating 8-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQDMLASH.S8_vvs_T1" = mve.Accumulated(8, false, true).call;
/// VCADD.I8 `vcadd.i8 Qd, Qn, Qm, #90`: complex add of 8-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VCADD.I8_T1_rot90" = mve.Turned(8, false, false).call;
/// VCADD.I8 `vcadd.i8 Qd, Qn, Qm, #270`: complex add of 8-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VCADD.I8_T1_rot270" = mve.Turned(8, true, false).call;
/// VHCADD.S8 `vhcadd.s8 Qd, Qn, Qm, #90`: halving complex add of 8-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VHCADD.S8_T1_rot90" = mve.Turned(8, false, true).call;
/// VHCADD.S8 `vhcadd.s8 Qd, Qn, Qm, #270`: halving complex add of 8-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VHCADD.S8_T1_rot270" = mve.Turned(8, true, true).call;
/// VQDMLADH.S16 `vqdmladh.s16 Qd, Qn, Qm`: doubling saturating sum of paired 16-bit lane products of Qn and Qm.
pub const @"VQDMLADH.S16_T1" = mve.Doubled(16, false, false, false).call;
/// VQRDMLADH.S16 `vqrdmladh.s16 Qd, Qn, Qm`: rounding doubling saturating sum of paired 16-bit lane products of Qn and Qm.
pub const @"VQRDMLADH.S16_T2" = mve.Doubled(16, false, false, true).call;
/// VQDMLADHX.S16 `vqdmladhx.s16 Qd, Qn, Qm`: doubling saturating sum of paired 16-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLADHX.S16_T1" = mve.Doubled(16, true, false, false).call;
/// VQRDMLADHX.S16 `vqrdmladhx.s16 Qd, Qn, Qm`: rounding doubling saturating sum of paired 16-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLADHX.S16_T2" = mve.Doubled(16, true, false, true).call;
/// VQRDMLAH.S16 `vqrdmlah.s16 Qd, Qn, Rt`: rounding doubling saturating 16-bit Qd += Qn*Rt, high halves kept.
pub const @"VQRDMLAH.S16_vsv_T2" = mve.Accumulated(16, true, false).call;
/// VQDMLAH.S16 `vqdmlah.s16 Qd, Qn, Rt`: doubling saturating 16-bit Qd += Qn*Rt, high halves kept.
pub const @"VQDMLAH.S16_vsv_T1" = mve.Accumulated(16, false, false).call;
/// VQRDMLASH.S16 `vqrdmlash.s16 Qd, Qn, Rt`: rounding doubling saturating 16-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQRDMLASH.S16_vvs_T2" = mve.Accumulated(16, true, true).call;
/// VQDMLASH.S16 `vqdmlash.s16 Qd, Qn, Rt`: doubling saturating 16-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQDMLASH.S16_vvs_T1" = mve.Accumulated(16, false, true).call;
/// VCADD.I16 `vcadd.i16 Qd, Qn, Qm, #90`: complex add of 16-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VCADD.I16_T1_rot90" = mve.Turned(16, false, false).call;
/// VCADD.I16 `vcadd.i16 Qd, Qn, Qm, #270`: complex add of 16-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VCADD.I16_T1_rot270" = mve.Turned(16, true, false).call;
/// VHCADD.S16 `vhcadd.s16 Qd, Qn, Qm, #90`: halving complex add of 16-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VHCADD.S16_T1_rot90" = mve.Turned(16, false, true).call;
/// VHCADD.S16 `vhcadd.s16 Qd, Qn, Qm, #270`: halving complex add of 16-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VHCADD.S16_T1_rot270" = mve.Turned(16, true, true).call;
/// VQDMLADH.S32 `vqdmladh.s32 Qd, Qn, Qm`: doubling saturating sum of paired 32-bit lane products of Qn and Qm.
pub const @"VQDMLADH.S32_T1" = mve.Doubled(32, false, false, false).call;
/// VQRDMLADH.S32 `vqrdmladh.s32 Qd, Qn, Qm`: rounding doubling saturating sum of paired 32-bit lane products of Qn and Qm.
pub const @"VQRDMLADH.S32_T2" = mve.Doubled(32, false, false, true).call;
/// VQDMLADHX.S32 `vqdmladhx.s32 Qd, Qn, Qm`: doubling saturating sum of paired 32-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLADHX.S32_T1" = mve.Doubled(32, true, false, false).call;
/// VQRDMLADHX.S32 `vqrdmladhx.s32 Qd, Qn, Qm`: rounding doubling saturating sum of paired 32-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLADHX.S32_T2" = mve.Doubled(32, true, false, true).call;
/// VQRDMLAH.S32 `vqrdmlah.s32 Qd, Qn, Rt`: rounding doubling saturating 32-bit Qd += Qn*Rt, high halves kept.
pub const @"VQRDMLAH.S32_vsv_T2" = mve.Accumulated(32, true, false).call;
/// VQDMLAH.S32 `vqdmlah.s32 Qd, Qn, Rt`: doubling saturating 32-bit Qd += Qn*Rt, high halves kept.
pub const @"VQDMLAH.S32_vsv_T1" = mve.Accumulated(32, false, false).call;
/// VQRDMLASH.S32 `vqrdmlash.s32 Qd, Qn, Rt`: rounding doubling saturating 32-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQRDMLASH.S32_vvs_T2" = mve.Accumulated(32, true, true).call;
/// VQDMLASH.S32 `vqdmlash.s32 Qd, Qn, Rt`: doubling saturating 32-bit Qd = Qn*Qd + Rt, high halves kept.
pub const @"VQDMLASH.S32_vvs_T1" = mve.Accumulated(32, false, true).call;
/// VCADD.I32 `vcadd.i32 Qd, Qn, Qm, #90`: complex add of 32-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VCADD.I32_T1_rot90" = mve.Turned(32, false, false).call;
/// VCADD.I32 `vcadd.i32 Qd, Qn, Qm, #270`: complex add of 32-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VCADD.I32_T1_rot270" = mve.Turned(32, true, false).call;
/// VHCADD.S32 `vhcadd.s32 Qd, Qn, Qm, #90`: halving complex add of 32-bit lane pairs with Qm rotated by 90 degrees.
pub const @"VHCADD.S32_T1_rot90" = mve.Turned(32, false, true).call;
/// VHCADD.S32 `vhcadd.s32 Qd, Qn, Qm, #270`: halving complex add of 32-bit lane pairs with Qm rotated by 270 degrees.
pub const @"VHCADD.S32_T1_rot270" = mve.Turned(32, true, true).call;
/// VADC.I32 `vadc.i32 Qd, Qn, Qm`: adds 32-bit lanes of Qn and Qm, carry-in from FPSCR.C, carry-out to FPSCR.C.
pub const @"VADC.I32_T1" = mve.Carried(false, false).call;
/// VADCI.I32 `vadci.i32 Qd, Qn, Qm`: adds 32-bit lanes of Qn and Qm, carry-in from the I bit, carry-out to FPSCR.C.
pub const @"VADCI.I32_T1" = mve.Carried(false, true).call;
/// VQDMLSDH.S8 `vqdmlsdh.s8 Qd, Qn, Qm`: doubling saturating difference of paired 8-bit lane products of Qn and Qm.
pub const @"VQDMLSDH.S8_T1" = mve.Doubled(8, false, true, false).call;
/// VQRDMLSDH.S8 `vqrdmlsdh.s8 Qd, Qn, Qm`: rounding doubling saturating difference of paired 8-bit lane products of Qn and Qm.
pub const @"VQRDMLSDH.S8_T2" = mve.Doubled(8, false, true, true).call;
/// VQDMLSDHX.S8 `vqdmlsdhx.s8 Qd, Qn, Qm`: doubling saturating difference of paired 8-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLSDHX.S8_T1" = mve.Doubled(8, true, true, false).call;
/// VQRDMLSDHX.S8 `vqrdmlsdhx.s8 Qd, Qn, Qm`: rounding doubling saturating difference of paired 8-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLSDHX.S8_T2" = mve.Doubled(8, true, true, true).call;
/// VQDMLSDH.S16 `vqdmlsdh.s16 Qd, Qn, Qm`: doubling saturating difference of paired 16-bit lane products of Qn and Qm.
pub const @"VQDMLSDH.S16_T1" = mve.Doubled(16, false, true, false).call;
/// VQRDMLSDH.S16 `vqrdmlsdh.s16 Qd, Qn, Qm`: rounding doubling saturating difference of paired 16-bit lane products of Qn and Qm.
pub const @"VQRDMLSDH.S16_T2" = mve.Doubled(16, false, true, true).call;
/// VQDMLSDHX.S16 `vqdmlsdhx.s16 Qd, Qn, Qm`: doubling saturating difference of paired 16-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLSDHX.S16_T1" = mve.Doubled(16, true, true, false).call;
/// VQRDMLSDHX.S16 `vqrdmlsdhx.s16 Qd, Qn, Qm`: rounding doubling saturating difference of paired 16-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLSDHX.S16_T2" = mve.Doubled(16, true, true, true).call;
/// VQDMLSDH.S32 `vqdmlsdh.s32 Qd, Qn, Qm`: doubling saturating difference of paired 32-bit lane products of Qn and Qm.
pub const @"VQDMLSDH.S32_T1" = mve.Doubled(32, false, true, false).call;
/// VQRDMLSDH.S32 `vqrdmlsdh.s32 Qd, Qn, Qm`: rounding doubling saturating difference of paired 32-bit lane products of Qn and Qm.
pub const @"VQRDMLSDH.S32_T2" = mve.Doubled(32, false, true, true).call;
/// VQDMLSDHX.S32 `vqdmlsdhx.s32 Qd, Qn, Qm`: doubling saturating difference of paired 32-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQDMLSDHX.S32_T1" = mve.Doubled(32, true, true, false).call;
/// VQRDMLSDHX.S32 `vqrdmlsdhx.s32 Qd, Qn, Qm`: rounding doubling saturating difference of paired 32-bit lane products of Qn and Qm, operands exchanged.
pub const @"VQRDMLSDHX.S32_T2" = mve.Doubled(32, true, true, true).call;
/// VSBC.I32 `vsbc.i32 Qd, Qn, Qm`: subtracts 32-bit lanes of Qn and Qm, carry-in from FPSCR.C, carry-out to FPSCR.C.
pub const @"VSBC.I32_T1" = mve.Carried(true, false).call;
/// VSBCI.I32 `vsbci.i32 Qd, Qn, Qm`: subtracts 32-bit lanes of Qn and Qm, carry-in from the I bit, carry-out to FPSCR.C.
pub const @"VSBCI.I32_T1" = mve.Carried(true, true).call;
/// VADD.F32 `vadd.f32 Qd, Qn, Qm`: adds 32-bit float lanes of Qn and Qm under the predicate.
pub const @"VADD.F32_fp_T1" = mve.Real(32, .add, false).call;
/// VSUB.F32 `vsub.f32 Qd, Qn, Qm`: subtracts 32-bit float lanes of Qn and Qm under the predicate.
pub const @"VSUB.F32_fp_T1" = mve.Real(32, .sub, false).call;
/// VMUL.F32 `vmul.f32 Qd, Qn, Qm`: multiplies 32-bit float lanes of Qn and Qm under the predicate.
pub const @"VMUL.F32_fp_T1" = mve.Real(32, .mul, false).call;
/// VABD.F32 `vabd.f32 Qd, Qn, Qm`: absolute difference of 32-bit float lanes of Qn and Qm under the predicate.
pub const @"VABD.F32_fp_T1" = mve.Real(32, .sub, true).call;
/// VFMA.F32 `vfma.f32 Qd, Qn, Qm`: fused 32-bit float Qd += Qn*Qm per lane under the predicate.
pub const @"VFMA.F32_fp_T1" = mve.Chained(32, .fma).call;
/// VFMS.F32 `vfms.f32 Qd, Qn, Qm`: fused 32-bit float Qd -= Qn*Qm per lane under the predicate.
pub const @"VFMS.F32_fp_T2" = mve.Chained(32, .fms).call;
/// VADD.F32 `vadd.f32 Qd, Qn, Rt`: adds 32-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VADD.F32_fp_T2" = mve.RealScalar(32, .add).call;
/// VSUB.F32 `vsub.f32 Qd, Qn, Rt`: subtracts 32-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VSUB.F32_fp_T2" = mve.RealScalar(32, .sub).call;
/// VMUL.F32 `vmul.f32 Qd, Qn, Rt`: multiplies 32-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VMUL.F32_fp_T2" = mve.RealScalar(32, .mul).call;
/// VFMA.F32 `vfma.f32 Qd, Qn, Rt`: fused 32-bit float Qd += Qn*Rt per lane, Rt broadcast.
pub const @"VFMA.F32_vsv_fp_T1" = mve.ChainedScalar(32, false).call;
/// VFMAS.F32 `vfmas.f32 Qd, Qn, Rt`: fused 32-bit float Qd = Qn*Qd + Rt per lane, Rt broadcast.
pub const @"VFMAS.F32_vvs_fp_T1" = mve.ChainedScalar(32, true).call;
/// VABS.F32 `vabs.f32 Qd, Qm`: clears the sign of each 32-bit float lane of Qm under the predicate.
pub const @"VABS.F32_fp_T1" = mve.Sign(32, false).call;
/// VNEG.F32 `vneg.f32 Qd, Qm`: flips the sign of each 32-bit float lane of Qm under the predicate.
pub const @"VNEG.F32_fp_T1" = mve.Sign(32, true).call;
/// VADD.F16 `vadd.f16 Qd, Qn, Qm`: adds 16-bit float lanes of Qn and Qm under the predicate.
pub const @"VADD.F16_fp_T1" = mve.Real(16, .add, false).call;
/// VSUB.F16 `vsub.f16 Qd, Qn, Qm`: subtracts 16-bit float lanes of Qn and Qm under the predicate.
pub const @"VSUB.F16_fp_T1" = mve.Real(16, .sub, false).call;
/// VMUL.F16 `vmul.f16 Qd, Qn, Qm`: multiplies 16-bit float lanes of Qn and Qm under the predicate.
pub const @"VMUL.F16_fp_T1" = mve.Real(16, .mul, false).call;
/// VABD.F16 `vabd.f16 Qd, Qn, Qm`: absolute difference of 16-bit float lanes of Qn and Qm under the predicate.
pub const @"VABD.F16_fp_T1" = mve.Real(16, .sub, true).call;
/// VFMA.F16 `vfma.f16 Qd, Qn, Qm`: fused 16-bit float Qd += Qn*Qm per lane under the predicate.
pub const @"VFMA.F16_fp_T1" = mve.Chained(16, .fma).call;
/// VFMS.F16 `vfms.f16 Qd, Qn, Qm`: fused 16-bit float Qd -= Qn*Qm per lane under the predicate.
pub const @"VFMS.F16_fp_T2" = mve.Chained(16, .fms).call;
/// VADD.F16 `vadd.f16 Qd, Qn, Rt`: adds 16-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VADD.F16_fp_T2" = mve.RealScalar(16, .add).call;
/// VSUB.F16 `vsub.f16 Qd, Qn, Rt`: subtracts 16-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VSUB.F16_fp_T2" = mve.RealScalar(16, .sub).call;
/// VMUL.F16 `vmul.f16 Qd, Qn, Rt`: multiplies 16-bit float lanes of Qn and broadcast Rt under the predicate.
pub const @"VMUL.F16_fp_T2" = mve.RealScalar(16, .mul).call;
/// VFMA.F16 `vfma.f16 Qd, Qn, Rt`: fused 16-bit float Qd += Qn*Rt per lane, Rt broadcast.
pub const @"VFMA.F16_vsv_fp_T1" = mve.ChainedScalar(16, false).call;
/// VFMAS.F16 `vfmas.f16 Qd, Qn, Rt`: fused 16-bit float Qd = Qn*Qd + Rt per lane, Rt broadcast.
pub const @"VFMAS.F16_vvs_fp_T1" = mve.ChainedScalar(16, true).call;
/// VABS.F16 `vabs.f16 Qd, Qm`: clears the sign of each 16-bit float lane of Qm under the predicate.
pub const @"VABS.F16_fp_T1" = mve.Sign(16, false).call;
/// VNEG.F16 `vneg.f16 Qd, Qm`: flips the sign of each 16-bit float lane of Qm under the predicate.
pub const @"VNEG.F16_fp_T1" = mve.Sign(16, true).call;
/// VPT/VCMP.F32 `Qn, Qm`: EQ or NE compare of 32-bit float lanes into VPR.P0.
pub const @"VPT.F32_fp_T1_eq" = mve.RealCompare(32).call;
/// VPT/VCMP.F32 `Qn, Rm`: EQ or NE compare of 32-bit float lanes with scalar Rm into VPR.P0, Rm r0-r7.
pub const @"VPT.F32_fp_T2_eq_r0" = mve.RealCompareScalar(32, 0).call;
/// VPT/VCMP.F32 `Qn, Rm`: EQ or NE compare of 32-bit float lanes with scalar Rm into VPR.P0, Rm r8-r11.
pub const @"VPT.F32_fp_T2_eq_r8" = mve.RealCompareScalar(32, 8).call;
/// VPT/VCMP.F32 `Qn, r12`: EQ or NE compare of 32-bit float lanes with scalar r12 into VPR.P0.
pub const @"VPT.F32_fp_T2_eq_r12" = mve.RealCompareScalarOnly(32, 12).call;
/// VPT/VCMP.F32 `Qn, Rm`: EQ or NE compare of 32-bit float lanes with scalar Rm into VPR.P0, Rm lr/zr.
pub const @"VPT.F32_fp_T2_eq_lr" = mve.RealCompareScalar(32, 14).call;
/// VPT/VCMP.F32 `Qn, Qm`: GE, LT, GT or LE compare of 32-bit float lanes into VPR.P0.
pub const @"VPT.F32_fp_T1_ge" = mve.RealCompareHigh(32).call;
/// VPT/VCMP.F32 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm r0-r7.
pub const @"VPT.F32_fp_T2_ge_r0" = mve.RealCompareScalarHigh(32, 0).call;
/// VPT/VCMP.F32 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm r8-r11.
pub const @"VPT.F32_fp_T2_ge_r8" = mve.RealCompareScalarHigh(32, 8).call;
/// VPT/VCMP.F32 `Qn, r12`: GE, LT, GT or LE compare of 32-bit float lanes with scalar r12 into VPR.P0.
pub const @"VPT.F32_fp_T2_ge_r12" = mve.RealCompareScalarHighOnly(32, 12).call;
/// VPT/VCMP.F32 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm lr/zr.
pub const @"VPT.F32_fp_T2_ge_lr" = mve.RealCompareScalarHigh(32, 14).call;
/// VMAXNM.F32 `vmaxnm.f32 Qd, Qn, Qm`: IEEE maxNum of 32-bit float lanes of Qn and Qm.
pub const @"VMAXNM.F32_fp_T1" = mve.Nearest(32, true).call;
/// VMAXNMA.F32 `vmaxnma.f32 Qd, Qm`: each 32-bit float lane Qd = maxNum(|Qd|, |Qm|).
pub const @"VMAXNMA.F32_fp_T2" = mve.NearestAbsolute(32, true).call;
/// VMAXNMAV.F32 `vmaxnmav.f32 Rt, Qm`: Rda = maxNum of absolute values across Rda and the 32-bit float lanes of Qm.
pub const @"VMAXNMAV.F32_fp_T2" = mve.Finest(32, true, true).call;
/// VMAXNMV.F32 `vmaxnmv.f32 Rt, Qm`: Rda = maxNum across Rda and the 32-bit float lanes of Qm.
pub const @"VMAXNMV.F32_fp_T1" = mve.Finest(32, true, false).call;
/// VMINNM.F32 `vminnm.f32 Qd, Qn, Qm`: IEEE minNum of 32-bit float lanes of Qn and Qm.
pub const @"VMINNM.F32_fp_T1" = mve.Nearest(32, false).call;
/// VMINNMA.F32 `vminnma.f32 Qd, Qm`: each 32-bit float lane Qd = minNum(|Qd|, |Qm|).
pub const @"VMINNMA.F32_fp_T2" = mve.NearestAbsolute(32, false).call;
/// VMINNMAV.F32 `vminnmav.f32 Rt, Qm`: Rda = minNum of absolute values across Rda and the 32-bit float lanes of Qm.
pub const @"VMINNMAV.F32_fp_T2" = mve.Finest(32, false, true).call;
/// VMINNMV.F32 `vminnmv.f32 Rt, Qm`: Rda = minNum across Rda and the 32-bit float lanes of Qm.
pub const @"VMINNMV.F32_fp_T1" = mve.Finest(32, false, false).call;
/// VPT/VCMP.F16 `Qn, Qm`: EQ or NE compare of 16-bit float lanes into VPR.P0.
pub const @"VPT.F16_fp_T1_eq" = mve.RealCompare(16).call;
/// VPT/VCMP.F16 `Qn, Rm`: EQ or NE compare of 16-bit float lanes with scalar Rm into VPR.P0, Rm r0-r7.
pub const @"VPT.F16_fp_T2_eq_r0" = mve.RealCompareScalar(16, 0).call;
/// VPT/VCMP.F16 `Qn, Rm`: EQ or NE compare of 16-bit float lanes with scalar Rm into VPR.P0, Rm r8-r11.
pub const @"VPT.F16_fp_T2_eq_r8" = mve.RealCompareScalar(16, 8).call;
/// VPT/VCMP.F16 `Qn, r12`: EQ or NE compare of 16-bit float lanes with scalar r12 into VPR.P0.
pub const @"VPT.F16_fp_T2_eq_r12" = mve.RealCompareScalarOnly(16, 12).call;
/// VPT/VCMP.F16 `Qn, Rm`: EQ or NE compare of 16-bit float lanes with scalar Rm into VPR.P0, Rm lr/zr.
pub const @"VPT.F16_fp_T2_eq_lr" = mve.RealCompareScalar(16, 14).call;
/// VPT/VCMP.F16 `Qn, Qm`: GE, LT, GT or LE compare of 16-bit float lanes into VPR.P0.
pub const @"VPT.F16_fp_T1_ge" = mve.RealCompareHigh(16).call;
/// VPT/VCMP.F16 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm r0-r7.
pub const @"VPT.F16_fp_T2_ge_r0" = mve.RealCompareScalarHigh(16, 0).call;
/// VPT/VCMP.F16 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm r8-r11.
pub const @"VPT.F16_fp_T2_ge_r8" = mve.RealCompareScalarHigh(16, 8).call;
/// VPT/VCMP.F16 `Qn, r12`: GE, LT, GT or LE compare of 16-bit float lanes with scalar r12 into VPR.P0.
pub const @"VPT.F16_fp_T2_ge_r12" = mve.RealCompareScalarHighOnly(16, 12).call;
/// VPT/VCMP.F16 `Qn, Rm`: GE, LT, GT or LE compare of float lanes with scalar Rm into VPR.P0, Rm lr/zr.
pub const @"VPT.F16_fp_T2_ge_lr" = mve.RealCompareScalarHigh(16, 14).call;
/// VMAXNM.F16 `vmaxnm.f16 Qd, Qn, Qm`: IEEE maxNum of 16-bit float lanes of Qn and Qm.
pub const @"VMAXNM.F16_fp_T1" = mve.Nearest(16, true).call;
/// VMAXNMA.F16 `vmaxnma.f16 Qd, Qm`: each 16-bit float lane Qd = maxNum(|Qd|, |Qm|).
pub const @"VMAXNMA.F16_fp_T2" = mve.NearestAbsolute(16, true).call;
/// VMAXNMAV.F16 `vmaxnmav.f16 Rt, Qm`: Rda = maxNum of absolute values across Rda and the 16-bit float lanes of Qm.
pub const @"VMAXNMAV.F16_fp_T2" = mve.Finest(16, true, true).call;
/// VMAXNMV.F16 `vmaxnmv.f16 Rt, Qm`: Rda = maxNum across Rda and the 16-bit float lanes of Qm.
pub const @"VMAXNMV.F16_fp_T1" = mve.Finest(16, true, false).call;
/// VMINNM.F16 `vminnm.f16 Qd, Qn, Qm`: IEEE minNum of 16-bit float lanes of Qn and Qm.
pub const @"VMINNM.F16_fp_T1" = mve.Nearest(16, false).call;
/// VMINNMA.F16 `vminnma.f16 Qd, Qm`: each 16-bit float lane Qd = minNum(|Qd|, |Qm|).
pub const @"VMINNMA.F16_fp_T2" = mve.NearestAbsolute(16, false).call;
/// VMINNMAV.F16 `vminnmav.f16 Rt, Qm`: Rda = minNum of absolute values across Rda and the 16-bit float lanes of Qm.
pub const @"VMINNMAV.F16_fp_T2" = mve.Finest(16, false, true).call;
/// VMINNMV.F16 `vminnmv.f16 Rt, Qm`: Rda = minNum across Rda and the 16-bit float lanes of Qm.
pub const @"VMINNMV.F16_fp_T1" = mve.Finest(16, false, false).call;
/// VCVT.S32.F32 `vcvt.s32.f32 Qd, Qm`: 32-bit float lanes to signed int, toward zero.
pub const @"VCVT.S32.F32_int_T1_vec" = mve.Fixed(32, false, .zero).call;
/// VCVT.F32.S32 `vcvt.f32.s32 Qd, Qm`: signed 32-bit int lanes to float under FPSCR rounding.
pub const @"VCVT.F32.S32_int_T1_vec" = mve.Loosed(32, false).call;
/// VCVTA.S32.F32 `vcvta.s32.f32 Qd, Qm`: 32-bit float lanes to signed int, ties away from zero.
pub const @"VCVTA.S32.F32_int_T1" = mve.Fixed(32, false, .away).call;
/// VCVTN.S32.F32 `vcvtn.s32.f32 Qd, Qm`: 32-bit float lanes to signed int, ties to even.
pub const @"VCVTN.S32.F32_int_T1" = mve.Fixed(32, false, .even).call;
/// VCVTP.S32.F32 `vcvtp.s32.f32 Qd, Qm`: 32-bit float lanes to signed int, toward +inf.
pub const @"VCVTP.S32.F32_int_T1" = mve.Fixed(32, false, .plus).call;
/// VCVTM.S32.F32 `vcvtm.s32.f32 Qd, Qm`: 32-bit float lanes to signed int, toward -inf.
pub const @"VCVTM.S32.F32_int_T1" = mve.Fixed(32, false, .minus).call;
/// VCVT.S32.F32 `vcvt.s32.f32 Qd, Qm, #imm`: 32-bit float lanes to signed fixed-point with fbits, toward zero.
pub const @"VCVT.S32.F32_fix_vec_T1" = mve.FixedScaled(32, false).call;
/// VCVT.F32.S32 `vcvt.f32.s32 Qd, Qm, #imm`: signed 32-bit fixed-point lanes with fbits to float.
pub const @"VCVT.F32.S32_fix_vec_T1" = mve.LoosedScaled(32, false).call;
/// VCVT.U32.F32 `vcvt.u32.f32 Qd, Qm`: 32-bit float lanes to unsigned int, toward zero.
pub const @"VCVT.U32.F32_int_T1_vec" = mve.Fixed(32, true, .zero).call;
/// VCVT.F32.U32 `vcvt.f32.u32 Qd, Qm`: unsigned 32-bit int lanes to float under FPSCR rounding.
pub const @"VCVT.F32.U32_int_T1_vec" = mve.Loosed(32, true).call;
/// VCVTA.U32.F32 `vcvta.u32.f32 Qd, Qm`: 32-bit float lanes to unsigned int, ties away from zero.
pub const @"VCVTA.U32.F32_int_T1" = mve.Fixed(32, true, .away).call;
/// VCVTN.U32.F32 `vcvtn.u32.f32 Qd, Qm`: 32-bit float lanes to unsigned int, ties to even.
pub const @"VCVTN.U32.F32_int_T1" = mve.Fixed(32, true, .even).call;
/// VCVTP.U32.F32 `vcvtp.u32.f32 Qd, Qm`: 32-bit float lanes to unsigned int, toward +inf.
pub const @"VCVTP.U32.F32_int_T1" = mve.Fixed(32, true, .plus).call;
/// VCVTM.U32.F32 `vcvtm.u32.f32 Qd, Qm`: 32-bit float lanes to unsigned int, toward -inf.
pub const @"VCVTM.U32.F32_int_T1" = mve.Fixed(32, true, .minus).call;
/// VCVT.U32.F32 `vcvt.u32.f32 Qd, Qm, #imm`: 32-bit float lanes to unsigned fixed-point with fbits, toward zero.
pub const @"VCVT.U32.F32_fix_vec_T1" = mve.FixedScaled(32, true).call;
/// VCVT.F32.U32 `vcvt.f32.u32 Qd, Qm, #imm`: unsigned 32-bit fixed-point lanes with fbits to float.
pub const @"VCVT.F32.U32_fix_vec_T1" = mve.LoosedScaled(32, true).call;
/// VRINTN.F32 `vrintn.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, ties to even.
pub const @"VRINTN.F32_fp_T1" = mve.Integral(32, .even).call;
/// VRINTX.F32 `vrintx.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, FPSCR mode, inexact raised.
pub const @"VRINTX.F32_fp_T1" = mve.Integral(32, .exact).call;
/// VRINTA.F32 `vrinta.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, ties away from zero.
pub const @"VRINTA.F32_fp_T1" = mve.Integral(32, .away).call;
/// VRINTZ.F32 `vrintz.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, toward zero.
pub const @"VRINTZ.F32_fp_T1" = mve.Integral(32, .zero).call;
/// VRINTM.F32 `vrintm.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, toward -inf.
pub const @"VRINTM.F32_fp_T1" = mve.Integral(32, .minus).call;
/// VRINTP.F32 `vrintp.f32 Qd, Qm`: rounds each 32-bit float lane to an integral value, toward +inf.
pub const @"VRINTP.F32_fp_T1" = mve.Integral(32, .plus).call;
/// VCVT.S16.F16 `vcvt.s16.f16 Qd, Qm`: 16-bit float lanes to signed int, toward zero.
pub const @"VCVT.S16.F16_int_T1" = mve.Fixed(16, false, .zero).call;
/// VCVT.F16.S16 `vcvt.f16.s16 Qd, Qm`: signed 16-bit int lanes to float under FPSCR rounding.
pub const @"VCVT.F16.S16_int_T1" = mve.Loosed(16, false).call;
/// VCVTA.S16.F16 `vcvta.s16.f16 Qd, Qm`: 16-bit float lanes to signed int, ties away from zero.
pub const @"VCVTA.S16.F16_int_T1" = mve.Fixed(16, false, .away).call;
/// VCVTN.S16.F16 `vcvtn.s16.f16 Qd, Qm`: 16-bit float lanes to signed int, ties to even.
pub const @"VCVTN.S16.F16_int_T1" = mve.Fixed(16, false, .even).call;
/// VCVTP.S16.F16 `vcvtp.s16.f16 Qd, Qm`: 16-bit float lanes to signed int, toward +inf.
pub const @"VCVTP.S16.F16_int_T1" = mve.Fixed(16, false, .plus).call;
/// VCVTM.S16.F16 `vcvtm.s16.f16 Qd, Qm`: 16-bit float lanes to signed int, toward -inf.
pub const @"VCVTM.S16.F16_int_T1" = mve.Fixed(16, false, .minus).call;
/// VCVT.S16.F16 `vcvt.s16.f16 Qd, Qm, #imm`: 16-bit float lanes to signed fixed-point with fbits, toward zero.
pub const @"VCVT.S16.F16_fix_vec_T1" = mve.FixedScaled(16, false).call;
/// VCVT.F16.S16 `vcvt.f16.s16 Qd, Qm, #imm`: signed 16-bit fixed-point lanes with fbits to float.
pub const @"VCVT.F16.S16_fix_vec_T1" = mve.LoosedScaled(16, false).call;
/// VCVT.U16.F16 `vcvt.u16.f16 Qd, Qm`: 16-bit float lanes to unsigned int, toward zero.
pub const @"VCVT.U16.F16_int_T1" = mve.Fixed(16, true, .zero).call;
/// VCVT.F16.U16 `vcvt.f16.u16 Qd, Qm`: unsigned 16-bit int lanes to float under FPSCR rounding.
pub const @"VCVT.F16.U16_int_T1" = mve.Loosed(16, true).call;
/// VCVTA.U16.F16 `vcvta.u16.f16 Qd, Qm`: 16-bit float lanes to unsigned int, ties away from zero.
pub const @"VCVTA.U16.F16_int_T1" = mve.Fixed(16, true, .away).call;
/// VCVTN.U16.F16 `vcvtn.u16.f16 Qd, Qm`: 16-bit float lanes to unsigned int, ties to even.
pub const @"VCVTN.U16.F16_int_T1" = mve.Fixed(16, true, .even).call;
/// VCVTP.U16.F16 `vcvtp.u16.f16 Qd, Qm`: 16-bit float lanes to unsigned int, toward +inf.
pub const @"VCVTP.U16.F16_int_T1" = mve.Fixed(16, true, .plus).call;
/// VCVTM.U16.F16 `vcvtm.u16.f16 Qd, Qm`: 16-bit float lanes to unsigned int, toward -inf.
pub const @"VCVTM.U16.F16_int_T1" = mve.Fixed(16, true, .minus).call;
/// VCVT.U16.F16 `vcvt.u16.f16 Qd, Qm, #imm`: 16-bit float lanes to unsigned fixed-point with fbits, toward zero.
pub const @"VCVT.U16.F16_fix_vec_T1" = mve.FixedScaled(16, true).call;
/// VCVT.F16.U16 `vcvt.f16.u16 Qd, Qm, #imm`: unsigned 16-bit fixed-point lanes with fbits to float.
pub const @"VCVT.F16.U16_fix_vec_T1" = mve.LoosedScaled(16, true).call;
/// VRINTN.F16 `vrintn.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, ties to even.
pub const @"VRINTN.F16_fp_T1" = mve.Integral(16, .even).call;
/// VRINTX.F16 `vrintx.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, FPSCR mode, inexact raised.
pub const @"VRINTX.F16_fp_T1" = mve.Integral(16, .exact).call;
/// VRINTA.F16 `vrinta.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, ties away from zero.
pub const @"VRINTA.F16_fp_T1" = mve.Integral(16, .away).call;
/// VRINTZ.F16 `vrintz.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, toward zero.
pub const @"VRINTZ.F16_fp_T1" = mve.Integral(16, .zero).call;
/// VRINTM.F16 `vrintm.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, toward -inf.
pub const @"VRINTM.F16_fp_T1" = mve.Integral(16, .minus).call;
/// VRINTP.F16 `vrintp.f16 Qd, Qm`: rounds each 16-bit float lane to an integral value, toward +inf.
pub const @"VRINTP.F16_fp_T1" = mve.Integral(16, .plus).call;
/// VCVTB.F16.F32 `vcvtb.f16.f32 Qd, Qm`: narrows single lanes of Qm into the bottom half-precision halves of Qd.
pub const @"VCVTB.F16.F32_hp_T1" = mve.Halved(false, false).call;
/// VCVTT.F16.F32 `vcvtt.f16.f32 Qd, Qm`: narrows single lanes of Qm into the top half-precision halves of Qd.
pub const @"VCVTT.F16.F32_hp_T1" = mve.Halved(false, true).call;
/// VCVTB.F32.F16 `vcvtb.f32.f16 Qd, Qm`: widens the bottom half-precision halves of Qm to single lanes.
pub const @"VCVTB.F32.F16_hp_T1" = mve.Halved(true, false).call;
/// VCVTT.F32.F16 `vcvtt.f32.f16 Qd, Qm`: widens the top half-precision halves of Qm to single lanes.
pub const @"VCVTT.F32.F16_hp_T1" = mve.Halved(true, true).call;
/// VCMUL.F32 `vcmul.f32 Qd, Qn, Qm, #rot`: complex 32-bit float multiply of lane pairs, Qm rotated by rot.
pub const @"VCMUL.F32_fp_T1" = mve.Complex(32).call;
/// VCMLA.F32 `vcmla.f32 Qd, Qn, Qm, #rot`: Qd += complex 32-bit float product of lane pairs, Qm rotated by rot.
pub const @"VCMLA.F32_fp_T1" = mve.ComplexAccumulate(32).call;
/// VCADD.F32 `vcadd.f32 Qd, Qn, Qm, #90`: complex 32-bit float add of lane pairs with Qm rotated by 90 degrees.
pub const @"VCADD.F32_fp_T1_rot90" = mve.Crossed(32, false).call;
/// VCADD.F32 `vcadd.f32 Qd, Qn, Qm, #270`: complex 32-bit float add of lane pairs with Qm rotated by 270 degrees.
pub const @"VCADD.F32_fp_T1_rot270" = mve.Crossed(32, true).call;
/// VCMUL.F16 `vcmul.f16 Qd, Qn, Qm, #rot`: complex 16-bit float multiply of lane pairs, Qm rotated by rot.
pub const @"VCMUL.F16_fp_T1" = mve.Complex(16).call;
/// VCMLA.F16 `vcmla.f16 Qd, Qn, Qm, #rot`: Qd += complex 16-bit float product of lane pairs, Qm rotated by rot.
pub const @"VCMLA.F16_fp_T1" = mve.ComplexAccumulate(16).call;
/// VCADD.F16 `vcadd.f16 Qd, Qn, Qm, #90`: complex 16-bit float add of lane pairs with Qm rotated by 90 degrees.
pub const @"VCADD.F16_fp_T1_rot90" = mve.Crossed(16, false).call;
/// VCADD.F16 `vcadd.f16 Qd, Qn, Qm, #270`: complex 16-bit float add of lane pairs with Qm rotated by 270 degrees.
pub const @"VCADD.F16_fp_T1_rot270" = mve.Crossed(16, true).call;

/// VMRS `vmrs Rt, vpr`: Rt = the whole VPR, privileged.
pub const VMRS_T1_vpr = mve.Move(true, ~@as(u32, 0)).call;
/// VMSR `vmsr vpr, Rt`: the whole VPR, privileged = Rt.
pub const VMSR_T1_vpr = mve.Move(false, ~@as(u32, 0)).call;
/// VMRS `vmrs Rt, p0`: Rt = VPR.P0.
pub const VMRS_T1_p0 = mve.Move(true, mve.lib.p0).call;
/// VMSR `vmsr p0, Rt`: VPR.P0 = Rt.
pub const VMSR_T1_p0 = mve.Move(false, mve.lib.p0).call;
/// VMOV `vmov Rt, Rt2, Qd[i+2], Qd[i]`: Rt, Rt2 = two words of Qd, i and i+2.
pub const VMOV_lanes_gprs_T1 = mve.Lanes(true).call;
/// VMOV `vmov Qd[i+2], Qd[i], Rt, Rt2`: words i and i+2 of Qd = Rt, Rt2.
pub const VMOV_gprs_lanes_T1 = mve.Lanes(false).call;
/// VPST: opens a predicated block with mask k; mask 0 inverts VPR.P0 instead.
pub const VPST_T1 = mve.block;
/// VPSEL `vpsel Qd, Qn, Qm`: each byte of Qd from Qn where VPR.P0 is set, else Qm.
pub const VPSEL_T1 = mve.select;
/// VCTP `vctp.size Rn`: VPR.P0 enables the first Rn elements of the named size.
pub const VCTP_T1 = mve.tail;
/// LETP `letp lr, label`: tail-predicated loop end, lr counts elements, branches back while any remain.
pub const LETP_T3 = mve.loopEndTail;
/// LCTP `lctp`: ends tail predication, clearing the loop's element count.
pub const LCTP_T1 = mve.loopClear;
/// WLSTP `wlstp.size lr, Rn, label`: tail-predicated while-loop start, lr = Rn elements, skips when zero.
pub const WLSTP_T3_r0 = mve.WhileTail(0).call;
/// WLSTP `wlstp.size lr, Rn, label`: tail-predicated while-loop start, lr = Rn elements, skips when zero, Rn r8-r11.
pub const WLSTP_T3_r8 = mve.WhileTail(8).call;
/// WLSTP `wlstp.size lr, Rn, label`: tail-predicated while-loop start, lr = Rn elements, skips when zero, Rn r12-r13.
pub const WLSTP_T3_r12 = mve.WhileTail(12).call;
/// WLSTP `wlstp.size lr, lr, label`: tail-predicated while-loop start counting lr itself, skips when zero.
pub const WLSTP_T3_lr = mve.whileTailLink;
/// DLSTP `dlstp.size lr, Rn`: tail-predicated do-loop start, lr = Rn elements.
pub const DLSTP_T4_r0 = mve.DoTail(0).call;
/// DLSTP `dlstp.size lr, Rn`: tail-predicated do-loop start, lr = Rn elements, Rn r8-r11.
pub const DLSTP_T4_r8 = mve.DoTail(8).call;
/// DLSTP `dlstp.size lr, Rn`: tail-predicated do-loop start, lr = Rn elements, Rn r12-r13.
pub const DLSTP_T4_r12 = mve.DoTail(12).call;
/// DLSTP `dlstp.size lr, lr`: tail-predicated do-loop start counting lr itself.
pub const DLSTP_T4_lr = mve.doTailLink;

/// Per-row branch target functions the disassembler calls to print a destination address.
pub const target = struct {
    /// Disassembly target of WLS `wls lr, Rn, label`: pc+4 plus the loop offset.
    pub const WLS_T1 = branch.targetLoopForward;
    /// Disassembly target of LE `le lr, label`: pc+4 minus the loop offset.
    pub const LE_T1 = branch.targetLoopBack;
    /// Disassembly target of LE `le label`: pc+4 minus the loop offset.
    pub const LE_T2 = branch.targetLoopBack;
    /// Disassembly target of B `b label`: pc+4 plus the 11-bit halfword offset, A7.7.12.
    pub const B_T2 = branch.targetB;
    /// Disassembly target of BEQ `beq label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BEQ_T1 = branch.targetCond;
    /// Disassembly target of BNE `bne label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BNE_T1 = branch.targetCond;
    /// Disassembly target of CBZ `cbz Rn, label`: pc+4 plus the zero-extended 6-bit halfword offset.
    pub const CBZ_T1 = branch.targetCbz;
    /// Disassembly target of BCS `bcs label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BCS_T1 = branch.targetCond;
    /// Disassembly target of BCC `bcc label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BCC_T1 = branch.targetCond;
    /// Disassembly target of BMI `bmi label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BMI_T1 = branch.targetCond;
    /// Disassembly target of BPL `bpl label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BPL_T1 = branch.targetCond;
    /// Disassembly target of BHI `bhi label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BHI_T1 = branch.targetCond;
    /// Disassembly target of BLS `bls label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BLS_T1 = branch.targetCond;
    /// Disassembly target of BGE `bge label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BGE_T1 = branch.targetCond;
    /// Disassembly target of BLT `blt label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BLT_T1 = branch.targetCond;
    /// Disassembly target of BGT `bgt label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BGT_T1 = branch.targetCond;
    /// Disassembly target of BLE `ble label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BLE_T1 = branch.targetCond;
    /// Disassembly target of BEQ.W `beq.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BEQ_T3 = branch.targetWide;
    /// Disassembly target of BNE.W `bne.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BNE_T3 = branch.targetWide;
    /// Disassembly target of BCS.W `bcs.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BCS_T3 = branch.targetWide;
    /// Disassembly target of BCC.W `bcc.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BCC_T3 = branch.targetWide;
    /// Disassembly target of BMI.W `bmi.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BMI_T3 = branch.targetWide;
    /// Disassembly target of BHI.W `bhi.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BHI_T3 = branch.targetWide;
    /// Disassembly target of BGE.W `bge.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BGE_T3 = branch.targetWide;
    /// Disassembly target of BLT.W `blt.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BLT_T3 = branch.targetWide;
    /// Disassembly target of BGT.W `bgt.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BGT_T3 = branch.targetWide;
    /// Disassembly target of BLE.W `ble.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BLE_T3 = branch.targetWide;
    /// Disassembly target of B.W `b.w label`: S with inverted J1 and J2, 24-bit halfword offset, A7.7.18.
    pub const B_T4 = branch.targetBl;
    /// Disassembly target of CBNZ `cbnz Rn, label`: pc+4 plus the zero-extended 6-bit halfword offset.
    pub const CBNZ_T1 = branch.targetCbz;
    /// Disassembly target of BL `bl label`: S with inverted J1 and J2, 24-bit halfword offset, A7.7.18.
    pub const BL_T1 = branch.targetBl;
    /// Disassembly target of BVS `bvs label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BVS_T1 = branch.targetCond;
    /// Disassembly target of BVC `bvc label`: pc+4 plus the 8-bit halfword offset, A7.7.12.
    pub const BVC_T1 = branch.targetCond;
    /// Disassembly target of BPL.W `bpl.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BPL_T3 = branch.targetWide;
    /// Disassembly target of BVS.W `bvs.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BVS_T3 = branch.targetWide;
    /// Disassembly target of BVC.W `bvc.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BVC_T3 = branch.targetWide;
    /// Disassembly target of BLS.W `bls.w label`: J2:J1 above the 6-bit field, 20-bit halfword offset, A7.7.12.
    pub const BLS_T3 = branch.targetWide;
    /// Disassembly target of LETP `letp lr, label`: pc+4 minus the loop offset.
    pub const LETP_T3 = branch.targetLoopBack;
    /// Disassembly target of WLSTP. `wlstp.size lr, Rn, label`: pc+4 plus the loop offset, size and Rn ignored.
    pub const WLSTP_T3_r0 = branch.targetLoopForwardTail;
    /// Disassembly target of WLSTP. `wlstp.size lr, Rn, label`: pc+4 plus the loop offset, size and Rn ignored, Rn r8-r11.
    pub const WLSTP_T3_r8 = branch.targetLoopForwardTail;
    /// Disassembly target of WLSTP. `wlstp.size lr, Rn, label`: pc+4 plus the loop offset, size and Rn ignored, Rn r12-r13.
    pub const WLSTP_T3_r12 = branch.targetLoopForwardTail;
    /// Disassembly target of WLSTP. `wlstp.size lr, lr, label`: pc+4 plus the loop offset, Rn=lr.
    pub const WLSTP_T3_lr = branch.targetLoopForward;
};

/// The host type behind a host pointer, which the access layer needs by type.
pub fn Host(comptime Pointer: type) type {
    return @typeInfo(Pointer).pointer.child;
}

/// Reads width bits at an address through the host, signed or strict as the row asks.
pub fn read(host: anytype, at: u32, comptime width: u8, comptime signed: bool, comptime strict: bool) Failure!u32 {
    return access.read(Host(@TypeOf(host)), host, at, width, signed, strict);
}

/// Writes width bits of value at an address through the host, strict where the row asks.
pub fn write(host: anytype, at: u32, comptime width: u8, value: u32, comptime strict: bool) Failure!void {
    return access.write(Host(@TypeOf(host)), host, at, width, value, strict);
}

/// Starts a Run of consecutive words at an address for block transfers.
pub fn run(host: anytype, at: u32) access.Run(Host(@TypeOf(host))) {
    return .{ .host = host, .at = at };
}

/// Does nothing and answers .next; the NOP, YIELD and unallocated hint rows.
pub fn nop(s: *State, host: anytype) Outcome {
    _ = .{ s, host };
    return .next;
}

/// DSB, DMB, ISB, A7.7.32: nothing to order on a one-access core, option ignored.
pub fn barrier(s: *State, host: anytype, h: u32) Outcome {
    _ = .{ s, host, h };
    return .next;
}

/// Reads register i of the state.
pub fn get(s: *const State, i: u32) u32 {
    return s.get(@intCast(i));
}

/// Register i as a load base: r15 reads as the word-aligned pc plus four, A5.1.2.
pub fn base(s: *const State, i: u32) u32 {
    return if (i == 15) (s.pc +% 4) & ~@as(u32, 3) else s.get(@intCast(i));
}

/// Writes register i; sp writes clear bits 1:0, B1.4.1, per CONTROL's bank.
pub fn set(s: *State, i: u32, value: u32) void {
    s.set(@intCast(i), value);
}

/// Sets N and Z from a result, leaving C and V.
pub fn setNZ(s: *State, value: u32) void {
    s.setNZ(value);
}

/// Sets N and Z from a result and C from the shifter carry.
pub fn setNZC(s: *State, value: u32, carry: bool) void {
    s.setNZC(value, carry);
}

/// Sets all four condition flags from an adder result.
pub fn setNZCV(s: *State, value: u32, carry: bool, overflow: bool) void {
    s.setNZCV(value, carry, overflow);
}

/// Whether execution is inside an IT block.
pub fn inIt(s: *const State) bool {
    return s.inIt();
}

/// Whether the current IT slot's condition holds.
pub fn itPasses(s: *const State) bool {
    return s.itPasses();
}

/// Loads a fresh IT state from an IT instruction's condition and mask byte.
pub fn setItState(s: *State, it: u8) void {
    s.setItState(it);
}

/// Steps the IT state to the next slot after an instruction retires.
pub fn itAdvance(s: *State) void {
    s.itAdvance();
}
