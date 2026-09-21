/* The slice of libc the Embench sources and CoreMark need, written over port.h so no image links
   a real C library: memory and string primitives, ctype, abort, and a printf that renders %d %u
   %x %c %s with an optional width into the console buffer. The __aeabi_ entries are what the ARM
   compiler emits for struct copies and clears. */
#include <stdarg.h>
#include <stddef.h>
#include "port.h"

void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    unsigned char *a = d;
    const unsigned char *b = s;
    if (a < b) return memcpy(d, s, n);
    for (size_t i = n; i-- > 0;) a[i] = b[i];
    return d;
}

void *memset(void *d, int c, size_t n) {
    unsigned char *a = d;
    while (n--) *a++ = (unsigned char)c;
    return d;
}

int memcmp(const void *x, const void *y, size_t n) {
    const unsigned char *a = x, *b = y;
    for (size_t i = 0; i < n; i++)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

char *strchr(const char *s, int c) {
    for (; *s; s++)
        if (*s == (char)c) return (char *)s;
    return c == 0 ? (char *)s : 0;
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int abs(int v) { return v < 0 ? -v : v; }
int tolower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
int toupper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalpha(int c) { return (c | 32) >= 'a' && (c | 32) <= 'z'; }
int isxdigit(int c) { return isdigit(c) || ((c | 32) >= 'a' && (c | 32) <= 'f'); }

#ifdef __arm__
void __aeabi_memcpy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy4(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy8(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memmove(void *d, const void *s, size_t n) { memmove(d, s, n); }
void __aeabi_memmove4(void *d, const void *s, size_t n) { memmove(d, s, n); }
void __aeabi_memset(void *d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memset4(void *d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memclr(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr4(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr8(void *d, size_t n) { memset(d, 0, n); }
#endif

void abort(void) { bench_exit(1); for (;;) {} }

int puts(const char *s) {
    while (*s) console_put(*s++);
    console_put('\n');
    return 0;
}

static void put_unsigned(unsigned value, unsigned base, int width) {
    char digits[32];
    int n = 0;
    do { digits[n++] = "0123456789abcdef"[value % base]; value /= base; } while (value);
    while (n < width) digits[n++] = '0';
    while (n--) console_put(digits[n]);
}

/* Formats %d, %u, %x, %c, %s and %% with an optional width into the console; other conversions
   print ?. */
int printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { console_put(*fmt); continue; }
        fmt++;
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') fmt++;
        switch (*fmt) {
            case 'd': {
                int v = va_arg(args, int);
                if (v < 0) { console_put('-'); put_unsigned((unsigned)-v, 10, width); }
                else put_unsigned((unsigned)v, 10, width);
                break;
            }
            case 'u': put_unsigned(va_arg(args, unsigned), 10, width); break;
            case 'x': put_unsigned(va_arg(args, unsigned), 16, width); break;
            case 'c': console_put((char)va_arg(args, int)); break;
            case 's': { const char *s = va_arg(args, const char *); while (*s) console_put(*s++); break; }
            case '%': console_put('%'); break;
            default: console_put('?'); break;
        }
    }
    va_end(args);
    return 0;
}
