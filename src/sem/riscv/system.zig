//! RV32I system handlers and the Zicsr and privileged rows: FENCE, ECALL, EBREAK, the six CSR
//! accesses, MRET and WFI. FENCE is a no-op on a hart that reaches memory in program order. A CSR
//! access follows the section 6.1 rules for whether it reads or writes, reaches PMP registers
//! through the host, and tells the processor about mstatus and mie writes. MRET and WFI report the
//! privilege change and the sleep through the host. Bound by `sem/riscv/root.zig`.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const csr = root.csr;

/// FENCE (RV32I): a no-op, since one in-order hart has nothing to order, section 2.7.
pub fn fence(s: *State, host: anytype, f: u32, p: u32, t: u32, n: u32, d: u32) Outcome {
    _ = .{ s, host, f, p, t, n, d };
    return .next;
}

/// ECALL (RV32I): raises the environment-call exception the processor traps through mtvec, section
/// 2.8.
pub fn ecall(s: *State, host: anytype) Outcome {
    _ = .{ s, host };
    return .environment_call;
}

/// EBREAK (RV32I) and C.EBREAK: leaves the loop so a debugger or semihosting call sees it.
pub fn ebreak(s: *State, host: anytype) Outcome {
    _ = .{ s, host };
    return .breakpoint;
}

const Kind = enum { swap, set, clear };

/// CSRRW, CSRRS, CSRRC and the immediate forms (Zicsr), section 6.1: one shape for all six
/// accesses.
pub fn Access(comptime kind: Kind, comptime immediate: bool) type {
    return struct {
        /// Reads unless a swap into x0, writes unless a set or clear from zero, then tells the host.
        pub fn call(s: *State, host: anytype, c: u32, source_field: u32, d: u32) Outcome {
            const source: u32 = if (immediate) source_field else s.x[source_field];
            const writing = switch (kind) {
                .swap => true,
                .set, .clear => source_field != 0,
            };
            const reads = kind != .swap or d != 0;
            const target = csr.allowed(@intCast(c), s.privilege, writing, s.csr.implementation) orelse return .illegal;
            switch (target) {
                .hart => |number| if (csr.floating(number) and s.csr.mstatus.fs == .off) return .illegal,
                .protection => {},
            }
            const old = if (!reads) 0 else switch (target) {
                .hart => |number| s.csr.read(number),
                .protection => |number| host.readPmp(number),
            };
            if (writing) {
                const value = switch (kind) {
                    .swap => source,
                    .set => old | source,
                    .clear => old & ~source,
                };
                switch (target) {
                    .hart => |number| {
                        s.csr.write(number, value);
                        if (number == .mstatus or number == .mie) host.rearm();
                    },
                    .protection => |number| host.writePmp(number, value),
                }
            }
            if (reads) root.write(s, d, old);
            return .next;
        }
    };
}

/// MRET (privileged): resumes what a trap interrupted, machine mode only, Privileged 3.3.2.
pub fn mret(s: *State, host: anytype) Outcome {
    if (s.privilege != .machine) return .illegal;
    s.pc = s.csr.leave(&s.privilege);
    host.returned();
    return .branched;
}

/// WFI (privileged): halts the hart until an interrupt, Privileged 3.3.3; illegal in user mode with
/// mstatus.TW.
pub fn wfi(s: *State, host: anytype) Outcome {
    if (s.privilege != .machine and s.csr.mstatus.tw) return .illegal;
    host.sleep();
    return .next;
}
