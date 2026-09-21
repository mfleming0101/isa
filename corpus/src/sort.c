/* Insertion sort of 256 pseudo-random words repeated ROUNDS times: compare-and-branch inner loops
   with a moving store, the classic branchy memory pattern. */
#include "../port/port.h"
#ifndef ROUNDS
#define ROUNDS 120
#endif
static void isort(int *a, int n) {
    for (int i = 1; i < n; i++) {
        int v = a[i], j = i - 1;
        while (j >= 0 && a[j] > v) { a[j + 1] = a[j]; j--; }
        a[j + 1] = v;
    }
}
int main(void) {
    static int a[256];
    unsigned seed = 12345, acc = 0;
    for (int round = 0; round < ROUNDS; round++) {
        for (int i = 0; i < 256; i++) { seed = seed * 1103515245u + 12345u; a[i] = (int)(seed >> 16); }
        isort(a, 256);
        acc += (unsigned)a[0] ^ (unsigned)a[255];
    }
    for (int i = 0; i < 8; i++) console_put((char)('a' + ((acc >> (i * 4)) & 15)));
    return 0;
}
