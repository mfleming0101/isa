//! Declares what the library requires of a host. A Requirement names one pub fn a host must
//! declare, its signature and why a row needs it. The per-architecture lists extend the three-entry
//! span contract with the answers Arm and RISC-V rows ask for beyond memory. assertHost checks a
//! host against a list at compile time, so the contract is measured rather than assumed; required
//! and optional count entries for the bench metrics.

/// One declaration a host must provide: its name, signature, optionality and the reason a row needs
/// it.
pub const Requirement = struct {
    name: [:0]const u8,
    Signature: type,
    optional: bool = false,
    why: []const u8,
};

/// Counts the entries of a requirement list a host may not omit.
pub fn required(comptime reqs: []const Requirement) usize {
    comptime {
        var n: usize = 0;
        for (reqs) |r| n += @intFromBool(!r.optional);
        return n;
    }
}

/// Counts the entries of a requirement list a host may omit.
pub fn optional(comptime reqs: []const Requirement) usize {
    comptime {
        var n: usize = 0;
        for (reqs) |r| n += @intFromBool(r.optional);
        return n;
    }
}

/// Compile error unless Host declares every requirement in the spelled shape; *anyopaque stands for
/// Host, anyerror for its errors, and a []u8 answer is also met by a []const u8 one.
pub fn assertHost(comptime Host: type, comptime reqs: []const Requirement) void {
    inline for (reqs) |r| {
        if (!@hasDecl(Host, r.name)) {
            if (r.optional) continue;
            @compileError(@typeName(Host) ++ " is missing pub fn " ++ r.name ++ ": " ++ r.why);
        }
        if (!shaped(Host, @TypeOf(@field(Host, r.name)), r.Signature))
            @compileError(@typeName(Host) ++ "." ++ r.name ++ " is not " ++ @typeName(r.Signature));
    }
}

fn shaped(comptime Host: type, comptime Got: type, comptime Want: type) bool {
    const got = switch (@typeInfo(Got)) {
        .@"fn" => |f| f,
        else => return false,
    };
    const want = @typeInfo(Want).@"fn";
    if (got.params.len != want.params.len) return false;
    inline for (got.params, want.params, 0..) |g, w, i| {
        if (g.is_generic != w.is_generic) return false;
        if (g.is_generic) continue;
        if (g.type != (if (i == 0 and w.type == *anyopaque) *Host else w.type)) return false;
    }
    return answers(got.return_type, want.return_type);
}

fn answers(comptime Got: ?type, comptime Want: ?type) bool {
    const g = Got orelse return Want == null;
    const w = Want orelse return false;
    if (g == w) return true;
    if (w == []u8 and g == []const u8) return true;
    const refused = switch (@typeInfo(w)) {
        .error_union => |u| u,
        else => return false,
    };
    const raised = switch (@typeInfo(g)) {
        .error_union => |u| u,
        else => return false,
    };
    return refused.error_set == anyerror and raised.payload == refused.payload;
}

/// The span contract: the three memory declarations every host must answer.
pub const host_requirements = [_]Requirement{
    .{ .name = "span", .Signature = fn (*anyopaque, u32, anytype) []u8, .why = "the span an access falls in, from its address to the end of the block the host answers for; a device, a hole and a refusal are all the empty slice, so a load multiple and a two-parcel fetch are answered by one lookup; a host over a read-only image answers []const u8 and takes its writes through access" },
    .{ .name = "access", .Signature = fn (*anyopaque, u32, anytype, u32) anyerror!u32, .why = "the lane for everything `span` answered short, and the refusal itself, which comes back as the return value rather than a flag left behind the call" },
    .{ .name = "touch", .Signature = fn (*anyopaque, u32) void, .why = "the address a lookup was made at, once a lookup rather than once a word, for the fault address registers, MMFAR and BFAR on Arm and mtval on RISC-V, and for the trace line" },
};

/// Span contract plus the PMP and event declarations the Zicsr rows need.
pub const riscv_requirements = host_requirements ++ [_]Requirement{
    .{ .name = "readPmp", .Signature = fn (*anyopaque, @import("riscv/isa/csr.zig").Protection) u32, .why = "a pmpcfg or pmpaddr register, Privileged 3.7.1: it belongs to the protection unit the processor has rather than to the hart, so a CSR access to one goes through the host" },
    .{ .name = "writePmp", .Signature = fn (*anyopaque, @import("riscv/isa/csr.zig").Protection, u32) void, .why = "the same on the way in, which is also where the unit re-reads the entries the run loop's standing word was computed from" },
    .{ .name = "rearm", .Signature = fn (*anyopaque) void, .why = "that a write reached mstatus or mie, Privileged 3.1.6.1 and 3.1.10: mstatus.MIE is the global interrupt gate and mie the per-source one, so software turning either on is one of the rare events that can make an interrupt due" },
    .{ .name = "returned", .Signature = fn (*anyopaque) void, .why = "that MRET changed the privilege the hart runs at and restored MIE, Privileged 3.3.2, which is what the protection unit's answers and the pending-interrupt word both depend on" },
    .{ .name = "sleep", .Signature = fn (*anyopaque) void, .why = "that WFI asked the core to halt, Privileged 3.3.3: the hart stalls until an interrupt is due, and what ends the wait is an event of the system rather than of the instruction" },
};

/// Span contract plus the configuration, mask, sleep and floating-point answers Arm rows need.
pub const arm_requirements = host_requirements ++ [_]Requirement{
    .{ .name = "architecture", .Signature = fn (*anyopaque) @import("arm/isa/architecture.zig").Architecture, .why = "which architecture the core implements: whether an unaligned single access is answered or refused, which bits of the APSR an MSR write reaches, and whether the halfword saturations exist" },
    .{ .name = "security", .Signature = fn (*anyopaque) bool, .why = "whether the Security Extension is implemented: without it the alternate state's special registers are not addressable at all" },
    .{ .name = "pacbti", .Signature = fn (*anyopaque) bool, .why = "whether the PACBTI Extension is implemented: without it the landing-pad bit is never set and the key registers read as zero" },
    .{ .name = "priorityBits", .Signature = fn (*anyopaque) u4, .why = "how many priority bits the NVIC implements, which is the mask a write to BASEPRI is truncated by" },
    .{ .name = "trapsUnaligned", .Signature = fn (*anyopaque) bool, .why = "CCR.UNALIGN_TRP: whether a core with the Main Extension refuses an unaligned single access instead of answering it" },
    .{ .name = "trapsDivideByZero", .Signature = fn (*anyopaque) bool, .why = "CCR.DIV_0_TRP: whether a divide by zero refuses instead of answering zero" },
    .{ .name = "signal", .Signature = fn (*anyopaque, @import("arm/isa/step.zig").Signal) void, .why = "that a supervisor call, an exception return or a function return retired, so the host enters or leaves the handler the instruction only asked for" },
    .{ .name = "rearm", .Signature = fn (*anyopaque) void, .why = "that a write reached PRIMASK, BASEPRI or FAULTMASK, B1.5.16, so the host re-arms and may take an exception the mask was holding off, which is the same question mstatus and mie ask on RISC-V" },
    .{ .name = "sleep", .Signature = fn (*anyopaque, @import("arm/isa/step.zig").Wait) void, .why = "that WFE or WFI asked the core to halt: what ends the wait is an event of the system, not of the instruction" },
    .{ .name = "event", .Signature = fn (*anyopaque) void, .why = "that SEV set the event register, which the next WFE consumes instead of halting" },
    .{ .name = "mve", .Signature = fn (*anyopaque) bool, .why = "whether MVE is implemented, which is what decides whether a low-overhead loop end is undefined over a live tail-predicated block, because only MVE gives FPSCR an LTPSIZE" },
    .{ .name = "coprocessorEnabled", .Signature = fn (*anyopaque) bool, .why = "CPACR.CP10: whether the unit in front of the core is reachable at all, which is what every floating-point row asks before it reads a register" },
    .{ .name = "doublePrecision", .Signature = fn (*anyopaque) bool, .why = "whether the unit in front of the core computes in double precision, which a row asks for itself because a single-precision unit still moves 64-bit registers and only refuses to compute with them" },
    .{ .name = "halfPrecision", .Signature = fn (*anyopaque) bool, .why = "whether the unit computes in half precision, asked for the same reason as doublePrecision: the width a row wants is a property of the unit the core was built with, not of the architecture whose rows were selected" },
    .{ .name = "fpv5", .Signature = fn (*anyopaque) bool, .why = "whether the unit is an FPv5 one, which is what decides whether the directed rounding and selection rows exist at all rather than being undefined" },
    .{ .name = "automaticFpState", .Signature = fn (*anyopaque) bool, .why = "FPCCR.ASPEN: whether the core opens a context of its own for code that has none, which is the only thing that resets FPSCR between two pieces of code" },
    .{ .name = "defaultFpscr", .Signature = fn (*anyopaque) u32, .why = "FPDSCR: the FPSCR a context the core opens begins with, which is a register of the system rather than of the state" },
    .{ .name = "lazyFpFrame", .Signature = fn (*anyopaque) ?u32, .why = "FPCCR.LSPACT and FPCAR: the frame a deferred save still owes, which the next floating-point row must settle before it reads a register" },
    .{ .name = "lazyFpEnabled", .Signature = fn (*anyopaque) bool, .why = "FPCCR.LSPEN: whether the host defers a save instead of making it now, which is what decides whether VLSTM writes the frame or only records where it will go" },
    .{ .name = "lazyFpCallee", .Signature = fn (*anyopaque) bool, .why = "whether the frame the deferred save owes carries the callee-saved half as well, which is a question about the security state the frame was pushed in" },
    .{ .name = "setLazyFp", .Signature = fn (*anyopaque, ?u32) void, .why = "that the deferred save has been settled, so the host clears FPCCR.LSPACT rather than the state carrying a copy of it" },
    .{ .name = "treatAsSecure", .Signature = fn (*anyopaque) bool, .why = "FPCCR.TS: whether the floating-point context is treated as Secure, which is what gives the FPCXT_NS rows a context to move; without it those rows answer the host's FPSCR instead" },
    .{ .name = "nonSecureFpscr", .Signature = fn (*anyopaque) u32, .why = "the FPSCR the Non-secure side holds, which an FPCXT transfer reads or restores because that register is banked by the host rather than carried in the state" },
};
