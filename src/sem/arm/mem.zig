//! Load and store semantics for the T32 rows: the narrow immediate, register, SP-relative and
//! literal forms, the wide immediate, indexed, negative-offset and register-offset forms, PUSH,
//! POP, LDM, STM and their wide and decrementing variants, the exclusive and acquire/release
//! accesses, CLREX, and LDRD/STRD. Rows take the machine state, host and decoded fields, access
//! memory through root.zig's read and write helpers, and return an `Outcome`; a fault becomes the
//! matching outcome. A load into r15 becomes a branch through branch.zig.
const root = @import("root.zig");
const State = root.State;
const Outcome = root.Outcome;
const branch = @import("branch.zig");

const Run = root.run;

/// STR (SP-relative), narrow: stores Rt at SP + imm8 * 4.
pub fn strSp(s: *State, host: anytype, t: u32, i: u32) Outcome {
    return write(host, s.sp() +% i * 4, 32, s.r[t], false);
}

/// LDR (SP-relative), narrow: loads Rt from SP + imm8 * 4.
pub fn ldrSp(s: *State, host: anytype, t: u32, i: u32) Outcome {
    switch (read(host, s.sp() +% i * 4, 32, false, false)) {
        .bad => |b| return b,
        .value => |v| s.r[t] = v,
    }
    return .next;
}

/// LDR (literal), narrow: loads Rt from the word-aligned pc + imm8 * 4.
pub fn ldrLit(s: *State, host: anytype, t: u32, i: u32) Outcome {
    switch (read(host, ((s.pc +% 4) & ~@as(u32, 3)) +% i * 4, 32, false, false)) {
        .bad => |b| return b,
        .value => |v| s.r[t] = v,
    }
    return .next;
}

/// PUSH: lowest register at the lowest address; SP moves only once every word is stored.
pub fn push(s: *State, host: anytype, l: u32, r: u32) Outcome {
    const bottom = s.sp() -% 4 *% (@as(u32, @popCount(r)) + l);
    switch (storeList(s, host, bottom, r, l)) {
        .next => {},
        else => |bad| return bad,
    }
    s.setSp(bottom);
    return .next;
}

/// STMDB, A7.7.159; PUSH's wide encoding is the SP form with writeback.
pub fn stmdb(s: *State, host: anytype, w: u32, n: u32, l: u32, r: u32) Outcome {
    const bottom = root.get(s, n) -% 4 *% (@as(u32, @popCount(r)) + l);
    switch (storeList(s, host, bottom, r, l)) {
        .next => {},
        else => |bad| return bad,
    }
    if (w != 0) root.set(s, n, bottom);
    return .next;
}

fn storeList(s: *State, host: anytype, from: u32, r: u32, l: u32) Outcome {
    var run = Run(host, from);
    var rest = r;
    while (rest != 0) : (rest &= rest - 1) run.write(s.r[@ctz(rest)]) catch |err| return Outcome.faulted(err);
    if (l == 1) run.write(s.lr) catch |err| return Outcome.faulted(err);
    return .next;
}

const Read = union(enum) { value: u32, bad: Outcome };

fn read(host: anytype, at: u32, comptime width: u8, comptime signed: bool, comptime strict: bool) Read {
    return .{ .value = root.read(host, at, width, signed, strict) catch |err| return .{ .bad = Outcome.faulted(err) } };
}

fn write(host: anytype, at: u32, comptime width: u8, value: u32, comptime strict: bool) Outcome {
    root.write(host, at, width, value, strict) catch |err| return Outcome.faulted(err);
    return .next;
}

/// Narrow immediate loads and stores: three-bit fields, offset scaled by the access width.
pub fn NarrowImm(comptime width: u8, comptime signed: bool, comptime loads: bool) type {
    return struct {
        /// Transfers Rt at Rn plus the scaled immediate.
        pub fn call(s: *State, host: anytype, i: u32, n: u32, t: u32) Outcome {
            const at = s.r[n] +% i * (width / 8);
            if (!loads) return write(host, at, width, s.r[t], false);
            switch (read(host, at, width, signed, false)) {
                .bad => |b| return b,
                .value => |v| s.r[t] = v,
            }
            return .next;
        }
    };
}

/// Narrow register-offset loads and stores.
pub fn NarrowReg(comptime width: u8, comptime signed: bool, comptime loads: bool) type {
    return struct {
        /// Transfers Rt at Rn plus Rm.
        pub fn call(s: *State, host: anytype, m: u32, n: u32, t: u32) Outcome {
            const at = s.r[n] +% s.r[m];
            if (!loads) return write(host, at, width, s.r[t], false);
            switch (read(host, at, width, signed, false)) {
                .bad => |b| return b,
                .value => |v| s.r[t] = v,
            }
            return .next;
        }
    };
}

fn landed(s: *State, host: anytype, comptime width: u8, t: u32, value: u32, lands: bool) Outcome {
    if (width == 32 and t == 15) return branch.landing(s, host, value, lands);
    root.set(s, t, value);
    return .next;
}

fn hint(comptime width: u8, comptime loads: bool, t: u32) bool {
    return loads and width != 32 and t == 15;
}

fn forced(host: anytype, comptime on: bool) void {
    if (@hasDecl(root.Host(@TypeOf(host)), "forceUnprivileged")) host.forceUnprivileged(on);
}

/// LDR T3, LDRT and siblings: an unsigned offset from a base; `top` fixes high n bits.
pub fn WideLoad(comptime width: u8, comptime signed: bool, comptime top: u32, comptime unprivileged: bool) type {
    return struct {
        /// Loads Rt from Rn plus the offset; r15 as Rt branches.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, i: u32) Outcome {
            return wideLoad(s, host, width, signed, unprivileged, top | n, t, i);
        }
    };
}

/// `WideLoad` with the base register fixed by the encoding.
pub fn WideLoadAt(comptime width: u8, comptime signed: bool, comptime reg: u32, comptime unprivileged: bool) type {
    return struct {
        /// Loads Rt from the fixed base plus the offset.
        pub fn call(s: *State, host: anytype, t: u32, i: u32) Outcome {
            return wideLoad(s, host, width, signed, unprivileged, reg, t, i);
        }
    };
}

fn wideLoad(s: *State, host: anytype, comptime width: u8, comptime signed: bool, comptime unprivileged: bool, n: u32, t: u32, i: u32) Outcome {
    if (hint(width, true, t)) return .next;
    if (unprivileged) forced(host, true);
    defer if (unprivileged) forced(host, false);
    switch (read(host, root.base(s, n) +% i, width, signed, false)) {
        .bad => |b| return b,
        .value => |v| return landed(s, host, width, t, v, true),
    }
}

/// Literal loads with U=0, A7.7.44: a twelve-bit offset below the word-aligned pc.
pub fn Literal(comptime width: u8, comptime signed: bool) type {
    return struct {
        /// Loads Rt from the aligned pc minus the offset.
        pub fn call(s: *State, host: anytype, t: u32, i: u32) Outcome {
            if (hint(width, true, t)) return .next;
            switch (read(host, root.base(s, 15) -% i, width, signed, false)) {
                .bad => |b| return b,
                .value => |v| return landed(s, host, width, t, v, true),
            }
        }
    };
}

/// STR T3, STRT and siblings, A7.7.161: UNDEFINED with a base of r15.
pub fn WideStore(comptime width: u8, comptime unprivileged: bool) type {
    return struct {
        /// Stores Rt at Rn plus the offset.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, i: u32) Outcome {
            if (n == 15) return .undefined;
            if (unprivileged) forced(host, true);
            defer if (unprivileged) forced(host, false);
            return write(host, root.get(s, n) +% i, width, root.get(s, t), false);
        }
    };
}

fn indexed(
    s: *State,
    host: anytype,
    comptime width: u8,
    comptime signed: bool,
    comptime loads: bool,
    comptime writeback: bool,
    n: u32,
    t: u32,
    pre: bool,
    add: bool,
    i: u32,
) Outcome {
    if (hint(width, loads, t)) return .next;
    if (n == 15) return .undefined;
    const start = root.get(s, n);
    const moved = if (add) start +% i else start -% i;
    const at = if (pre) moved else start;
    if (!loads) {
        switch (write(host, at, width, root.get(s, t), false)) {
            .next => {},
            else => |bad| return bad,
        }
        if (writeback) root.set(s, n, moved);
        return .next;
    }
    switch (read(host, at, width, signed, false)) {
        .bad => |b| return b,
        .value => |v| {
            if (writeback) root.set(s, n, moved);
            return landed(s, host, width, t, v, !(writeback and n == 13));
        },
    }
}

/// LDR T4 and siblings, A7.7.42: eight-bit offset, pre- or post-indexed, with writeback.
pub fn Indexed(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime top: u32) type {
    return struct {
        /// Transfers Rt with P and U selecting indexing and direction, writing Rn back.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, p: u32, u: u32, i: u32) Outcome {
            return indexed(s, host, width, signed, loads, true, top | n, t, p == 1, u == 1, i);
        }
    };
}

/// `Indexed` with the base register fixed by the encoding.
pub fn IndexedAt(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime reg: u32) type {
    return struct {
        /// Transfers Rt from the fixed base with P and U, writing it back.
        pub fn call(s: *State, host: anytype, t: u32, p: u32, u: u32, i: u32) Outcome {
            return indexed(s, host, width, signed, loads, true, reg, t, p == 1, u == 1, i);
        }
    };
}

/// The P=1 U=0 W=0 corner: a negative eight-bit offset with no writeback.
pub fn Negative(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime top: u32) type {
    return struct {
        /// Transfers Rt at Rn minus the offset.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, i: u32) Outcome {
            return indexed(s, host, width, signed, loads, false, top | n, t, true, false, i);
        }
    };
}

/// `Negative` with the base register fixed by the encoding.
pub fn NegativeAt(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime reg: u32) type {
    return struct {
        /// Transfers Rt at the fixed base minus the offset.
        pub fn call(s: *State, host: anytype, t: u32, i: u32) Outcome {
            return indexed(s, host, width, signed, loads, false, reg, t, true, false, i);
        }
    };
}

fn offsetReg(
    s: *State,
    host: anytype,
    comptime width: u8,
    comptime signed: bool,
    comptime loads: bool,
    n: u32,
    t: u32,
    y: u32,
    m: u32,
) Outcome {
    if (hint(width, loads, t)) return .next;
    if (n == 15) return .undefined;
    const at = root.get(s, n) +% (root.get(s, m) << @intCast(y));
    if (!loads) return write(host, at, width, root.get(s, t), false);
    switch (read(host, at, width, signed, false)) {
        .bad => |b| return b,
        .value => |v| return landed(s, host, width, t, v, true),
    }
}

/// LDR T2 and siblings, A7.7.43: a register offset scaled by up to eight.
pub fn OffsetReg(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime top: u32) type {
    return struct {
        /// Transfers Rt at Rn plus Rm shifted left by y.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, y: u32, m: u32) Outcome {
            return offsetReg(s, host, width, signed, loads, top | n, t, y, m);
        }
    };
}

/// `OffsetReg` with the base register fixed by the encoding.
pub fn OffsetRegAt(comptime width: u8, comptime signed: bool, comptime loads: bool, comptime reg: u32) type {
    return struct {
        /// Transfers Rt at the fixed base plus shifted Rm.
        pub fn call(s: *State, host: anytype, t: u32, y: u32, m: u32) Outcome {
            return offsetReg(s, host, width, signed, loads, reg, t, y, m);
        }
    };
}

/// STM T1, A7.7.156: stores the list upward from Rn and writes the base back.
pub fn stm(s: *State, host: anytype, n: u32, r: u32) Outcome {
    var run = Run(host, s.r[n]);
    var list = r;
    while (list != 0) : (list &= list - 1) run.write(s.r[@ctz(list)]) catch |err| return Outcome.faulted(err);
    s.r[n] = run.at;
    return .next;
}

/// LDM T1, A7.7.40: loads the list upward; Rn is written back only when not listed.
pub fn ldm(s: *State, host: anytype, n: u32, r: u32) Outcome {
    var run = Run(host, s.r[n]);
    switch (loadList(s, &run, r, 0)) {
        .next => {},
        else => |bad| return bad,
    }
    if ((r >> @intCast(n)) & 1 == 0) s.r[n] = run.at;
    return .next;
}

fn loadList(s: *State, run: anytype, r: u32, l: u32) Outcome {
    var list = r;
    while (list != 0) : (list &= list - 1) s.r[@ctz(list)] = run.read() catch |err| return Outcome.faulted(err);
    if (l == 1) s.lr = run.read() catch |err| return Outcome.faulted(err);
    return .next;
}

/// POP, A7.7.99: loads the list from the stack upward, SP landing above it.
pub fn pop(s: *State, host: anytype, r: u32) Outcome {
    var run = Run(host, s.sp());
    switch (loadList(s, &run, r, 0)) {
        .next => {},
        else => |bad| return bad,
    }
    s.setSp(run.at);
    return .next;
}

/// POP with pc, A7.7.99: the last word is a branch target; no landing pad is set.
pub fn popPc(s: *State, host: anytype, r: u32) Outcome {
    var run = Run(host, s.sp());
    switch (loadList(s, &run, r, 0)) {
        .next => {},
        else => |bad| return bad,
    }
    const target = run.read() catch |err| return Outcome.faulted(err);
    s.setSp(run.at);
    return branch.landing(s, host, target, false);
}

fn block(s: *State, host: anytype, comptime loads: bool, comptime with_pc: bool, comptime down: bool, n: u32, w: u32, l: u32, r: u32) Outcome {
    const start = root.get(s, n);
    const count: u32 = @as(u32, @popCount(r)) + l + @intFromBool(with_pc);
    const bottom = if (down) start -% 4 *% count else start;
    var run = Run(host, bottom);
    var loaded: [14]u32 = undefined;
    var taken: usize = 0;
    var list = r;
    while (list != 0) : (list &= list - 1) {
        if (loads) {
            loaded[taken] = run.read() catch |err| return Outcome.faulted(err);
            taken += 1;
        } else run.write(s.r[@ctz(list)]) catch |err| return Outcome.faulted(err);
    }
    if (l == 1) {
        if (loads) {
            loaded[taken] = run.read() catch |err| return Outcome.faulted(err);
        } else run.write(s.lr) catch |err| return Outcome.faulted(err);
    }
    const at = run.at;
    const target = if (with_pc) run.read() catch |err| return Outcome.faulted(err) else 0;
    if (loads) {
        var written: usize = 0;
        list = r;
        while (list != 0) : (list &= list - 1) {
            s.r[@ctz(list)] = loaded[written];
            written += 1;
        }
        if (l == 1) s.lr = loaded[written];
    }
    if (w == 1) root.set(s, n, if (down) bottom else at +% (if (with_pc) @as(u32, 4) else 0));
    if (with_pc) return branch.landing(s, host, target, !(w == 1 and n == 13));
    return .next;
}

/// LDM.W and STM.W, A7.7.41: thirteen-bit list plus lr, and pc for the pop forms.
pub fn Block(comptime loads: bool, comptime with_pc: bool, comptime first: u32) type {
    return struct {
        /// Transfers the list from Rn, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, n: u32, l: u32, r: u32) Outcome {
            return block(s, host, loads, with_pc, false, first + n, w, l, r);
        }
    };
}

/// `Block` with the base register fixed by the encoding.
pub fn BlockAt(comptime loads: bool, comptime with_pc: bool, comptime reg: u32) type {
    return struct {
        /// Transfers the list from the fixed base, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, l: u32, r: u32) Outcome {
            return block(s, host, loads, with_pc, false, reg, w, l, r);
        }
    };
}

/// LDMDB: the list is answered from below the base, writeback leaving it at the bottom.
pub fn BlockDown(comptime with_pc: bool) type {
    return struct {
        /// Loads the list from below Rn, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, n: u32, l: u32, r: u32) Outcome {
            return block(s, host, true, with_pc, true, n, w, l, r);
        }
    };
}

fn loadExclusive(s: *State, host: anytype, comptime width: u8, n: u32, t: u32, i: u32) Outcome {
    const at = root.get(s, n) +% i;
    switch (read(host, at, width, false, true)) {
        .bad => |b| return b,
        .value => |v| {
            s.exclusive = at;
            root.set(s, t, v);
        },
    }
    return .next;
}

fn storeExclusive(s: *State, host: anytype, comptime width: u8, n: u32, t: u32, d: u32, i: u32) Outcome {
    const at = root.get(s, n) +% i;
    if (at % (width / 8) != 0) {
        host.touch(at);
        return .unaligned;
    }
    const held = s.exclusive;
    s.exclusive = null;
    if (held == null or held.? != at) {
        root.set(s, d, 1);
        return .next;
    }
    switch (write(host, at, width, root.get(s, t), true)) {
        .next => {},
        else => |bad| return bad,
    }
    root.set(s, d, 0);
    return .next;
}

/// LDREX, A7.7.52: a strictly aligned load that tags the monitor; word-scaled offset.
pub fn LoadExclusiveImm(comptime width: u8) type {
    return struct {
        /// Loads Rt from Rn plus imm8 * 4 and tags the monitor.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, i: u32) Outcome {
            return loadExclusive(s, host, width, n, t, i << 2);
        }
    };
}

/// LDREXB and LDREXH, A7.7.52: strictly aligned, no offset.
pub fn LoadExclusivePlain(comptime width: u8) type {
    return struct {
        /// Loads Rt from Rn and tags the monitor.
        pub fn call(s: *State, host: anytype, n: u32, t: u32) Outcome {
            return loadExclusive(s, host, width, n, t, 0);
        }
    };
}

/// STREX, A7.7.167: alignment is tested first, then the monitor, which is cleared either way.
pub fn StoreExclusiveImm(comptime width: u8, comptime top: u32) type {
    return struct {
        /// Stores Rt at Rn plus imm8 * 4 if the monitor holds; Rd reports it.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, d: u32, i: u32) Outcome {
            return storeExclusive(s, host, width, n, top | t, d, i << 2);
        }
    };
}

/// `StoreExclusiveImm` with the transfer register fixed by the encoding.
pub fn StoreExclusiveImmAt(comptime width: u8, comptime reg: u32) type {
    return struct {
        /// Stores the fixed register at Rn plus imm8 * 4; Rd reports it.
        pub fn call(s: *State, host: anytype, n: u32, d: u32, i: u32) Outcome {
            return storeExclusive(s, host, width, n, reg, d, i << 2);
        }
    };
}

/// STREXB and STREXH, A7.7.167: no offset.
pub fn StoreExclusivePlain(comptime width: u8) type {
    return struct {
        /// Stores Rt at Rn if the monitor holds; Rd reports it.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, d: u32) Outcome {
            return storeExclusive(s, host, width, n, t, d, 0);
        }
    };
}

/// LDA, LDAB and LDAH: a strictly aligned load-acquire.
pub fn Acquire(comptime width: u8) type {
    return struct {
        /// Loads Rt from Rn, strictly aligned.
        pub fn call(s: *State, host: anytype, n: u32, t: u32) Outcome {
            switch (read(host, root.get(s, n), width, false, true)) {
                .bad => |b| return b,
                .value => |v| root.set(s, t, v),
            }
            return .next;
        }
    };
}

/// STL, STLB and STLH: a strictly aligned store-release.
pub fn Release(comptime width: u8) type {
    return struct {
        /// Stores Rt at Rn, strictly aligned.
        pub fn call(s: *State, host: anytype, n: u32, t: u32) Outcome {
            return write(host, root.get(s, n), width, root.get(s, t), true);
        }
    };
}

/// CLREX, A7.7.30: the monitor returns to open access.
pub fn clrex(s: *State, host: anytype) Outcome {
    _ = host;
    s.exclusive = null;
    return .next;
}

fn double(s: *State, host: anytype, comptime loads: bool, writeback: bool, add: bool, pre: bool, n: u32, t: u32, e: u32, i: u32) Outcome {
    const start = root.base(s, n);
    const offset = i << 2;
    const to = if (add) start +% offset else start -% offset;
    const at = if (pre) to else start;
    if (loads) {
        switch (read(host, at, 32, false, true)) {
            .bad => |b| return b,
            .value => |v| root.set(s, t, v),
        }
        switch (read(host, at +% 4, 32, false, true)) {
            .bad => |b| return b,
            .value => |v| root.set(s, e, v),
        }
    } else {
        switch (write(host, at, 32, root.get(s, t), true)) {
            .next => {},
            else => |bad| return bad,
        }
        switch (write(host, at +% 4, 32, root.get(s, e), true)) {
            .next => {},
            else => |bad| return bad,
        }
    }
    if (writeback) root.set(s, n, to);
    return .next;
}

/// LDRD and STRD, A7.7.49 and A7.7.166: two words at a positive word-scaled offset, pre-indexed.
pub fn DoubleUp(comptime loads: bool) type {
    return struct {
        /// Transfers Rt and Rt2 at Rn plus the offset, writing back when W is set.
        pub fn call(s: *State, host: anytype, w: u32, n: u32, t: u32, e: u32, i: u32) Outcome {
            return double(s, host, loads, w == 1, true, true, n, t, e, i);
        }
    };
}

/// LDRD and STRD with U selecting the direction, pre-indexed.
pub fn DoubleSigned(comptime loads: bool) type {
    return struct {
        /// Transfers Rt and Rt2 at Rn plus or minus the offset, writing back when W is set.
        pub fn call(s: *State, host: anytype, u: u32, w: u32, n: u32, t: u32, e: u32, i: u32) Outcome {
            return double(s, host, loads, w == 1, u == 1, true, n, t, e, i);
        }
    };
}

/// The U=0 LDRD encodings split out per base: an offset below it, writeback fixed by the encoding.
pub fn DoubleDown(comptime top: u32, comptime writeback: bool) type {
    return struct {
        /// Loads Rt and Rt2 from Rn minus the offset.
        pub fn call(s: *State, host: anytype, n: u32, t: u32, e: u32, i: u32) Outcome {
            return double(s, host, true, writeback, false, true, top | n, t, e, i);
        }
    };
}

/// `DoubleDown` with the base register fixed and writeback on.
pub fn DoubleDownAt(comptime reg: u32) type {
    return struct {
        /// Loads Rt and Rt2 from the fixed base minus the offset, writing it back.
        pub fn call(s: *State, host: anytype, t: u32, e: u32, i: u32) Outcome {
            return double(s, host, true, true, false, true, reg, t, e, i);
        }
    };
}

/// The P=0 LDRD and STRD forms: the words land at the base, which then moves.
pub fn DoublePost(comptime loads: bool) type {
    return struct {
        /// Transfers Rt and Rt2 at Rn, then moves Rn by the offset.
        pub fn call(s: *State, host: anytype, u: u32, n: u32, t: u32, e: u32, i: u32) Outcome {
            return double(s, host, loads, true, u == 1, false, n, t, e, i);
        }
    };
}
