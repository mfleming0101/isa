/* The one image that needs the F extension. Each round exercises the RV32F rows through inline
   assembly the compiler cannot lower differently: arithmetic, fused multiply-adds, sign
   injection, comparisons, conversions, classification, rounding-mode and flag CSRs, and the loads
   and stores in both compressed and uncompressed encodings. The rounding mode changes every round
   so the flags and results depend on it. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 2000
#endif

static void enable_fpu(void) {
    __asm__ volatile("csrs mstatus, %0" ::"r"(0x2000));
}

static float root_of(float x) {
    float r;
    __asm__("fsqrt.s %0, %1" : "=f"(r) : "f"(x));
    return r;
}

static float smaller(float a, float b) {
    float r;
    __asm__("fmin.s %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    return r;
}

static float larger(float a, float b) {
    float r;
    __asm__("fmax.s %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    return r;
}

static float fused(float a, float b, float c) {
    float r;
    __asm__("fmadd.s %0, %1, %2, %3" : "=f"(r) : "f"(a), "f"(b), "f"(c));
    return r;
}

static float signed_like(float a, float b) {
    float r;
    __asm__("fsgnj.s %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    return r;
}

static float difference(float a, float b) {
    float r;
    __asm__("fsub.s %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    return r;
}

static float signed_apart(float a, float b) {
    float r;
    __asm__("fsgnjx.s %0, %1, %2" : "=f"(r) : "f"(a), "f"(b));
    return r;
}

static float fused_low(float a, float b, float c) {
    float r;
    __asm__("fmsub.s %0, %1, %2, %3" : "=f"(r) : "f"(a), "f"(b), "f"(c));
    return r;
}

static float fused_negated(float a, float b, float c) {
    float r;
    __asm__("fnmadd.s %0, %1, %2, %3" : "=f"(r) : "f"(a), "f"(b), "f"(c));
    return r;
}

static float fused_negated_low(float a, float b, float c) {
    float r;
    __asm__("fnmsub.s %0, %1, %2, %3" : "=f"(r) : "f"(a), "f"(b), "f"(c));
    return r;
}

static float from_word(int x) {
    float r;
    __asm__("fcvt.s.w %0, %1" : "=f"(r) : "r"(x));
    return r;
}

/* The four compressed transfers C adds with F, pinned to registers the CL and CS formats can
   name. */
static float through_memory(float x, float *slot) {
    register float given __asm__("fa1") = x;
    register float *at __asm__("a0") = slot;
    register float taken __asm__("fa2");
    __asm__ volatile(
        "addi sp, sp, -8\n"
        "fsw %1, 0(%2)\n"
        "c.fsw %1, 4(%2)\n"
        "c.flw %0, 4(%2)\n"
        "c.fswsp %0, 0(sp)\n"
        "c.flwsp %0, 0(sp)\n"
        "addi sp, sp, 8\n"
        : "=f"(taken)
        : "f"(given), "r"(at)
        : "memory");
    return taken;
}

/* The two uncompressed transfers, pinned to registers outside the eight the compressed formats
   can name. */
static float wide_memory(float x, float *slot) {
    register float given __asm__("ft8") = x;
    register float *at __asm__("a7") = slot;
    register float taken __asm__("ft9");
    __asm__ volatile(
        "fsw %1, 0(%2)\n"
        "flw %0, 0(%2)\n"
        : "=f"(taken)
        : "f"(given), "r"(at)
        : "memory");
    return taken;
}

static unsigned kind_of(float x) {
    unsigned r;
    __asm__("fclass.s %0, %1" : "=r"(r) : "f"(x));
    return r;
}

static unsigned flags_of(void) {
    unsigned r;
    __asm__ volatile("csrr %0, fflags" : "=r"(r));
    return r;
}

static void mode(unsigned m) {
    __asm__ volatile("csrw frm, %0" ::"r"(m));
}

static unsigned bits(float x) {
    union {
        float f;
        unsigned u;
    } v;
    v.f = x;
    return v.u;
}

static float value(unsigned u) {
    union {
        float f;
        unsigned u;
    } v;
    v.u = u;
    return v.f;
}

int main(void) {
    enable_fpu();
    unsigned acc = 0;
    float table[16];
    static float slot[2];
    for (int i = 0; i < 16; i++) table[i] = value(0x3f800000u + (unsigned)i * 0x00100000u);
    for (int round = 0; round < ROUNDS; round++) {
        mode((unsigned)round & 3u);
        float sum = 0.0f;
        float product = 1.0f;
        for (int i = 0; i < 16; i++) {
            float x = table[i];
            sum = sum + x;
            product = product * (x - 0.5f);
            sum = sum + x / (float)(i + 1);
            sum = fused(x, product, sum);
            if (x < product) sum = sum - 1.0f;
            if (x == product) sum = sum + 2.0f;
            if (x <= product) acc += 3;
        }
        float root = root_of(sum < 0.0f ? -sum : sum);
        root = smaller(root, sum);
        root = larger(root, product);
        root = signed_like(root, product);
        root = difference(root, signed_apart(root, sum));
        root = fused_low(root, product, sum);
        root = fused_negated(root, product, sum);
        root = fused_negated_low(root, product, sum);
        root = root + from_word(round);
        root = through_memory(root, slot);
        root = wide_memory(root, slot);
        acc += bits(sum) ^ bits(product) ^ bits(root);
        acc += kind_of(root) + kind_of(sum);
        acc += (unsigned)(int)root;
        acc ^= (unsigned)(unsigned int)(sum < 0.0f ? 0.0f : sum);
        acc += flags_of();
        table[round & 15] = value((bits(table[round & 15]) & 0x7fffffffu) | ((acc & 1u) << 31));
    }
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
