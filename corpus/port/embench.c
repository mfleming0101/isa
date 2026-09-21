/* The board layer Embench expects, over port.h: no board setup, empty timing triggers, and a main
   that runs one benchmark, verifies it, and prints P or F followed by the result in hex so the
   console CRC pins both. */
#include "support.h"
#include "port.h"

void initialise_board(void) {}
void __attribute__((noinline)) start_trigger(void) {}
void __attribute__((noinline)) stop_trigger(void) {}

static void put_hex(unsigned value) {
    for (int i = 7; i >= 0; i--) console_put("0123456789abcdef"[(value >> (i * 4)) & 15]);
}

/* Runs the benchmark once after warming, prints the verdict and result, returns nonzero on
   failure. */
int main(void) {
    int result, correct;
    initialise_board();
    initialise_benchmark();
    warm_caches(WARMUP_HEAT);
    start_trigger();
    result = benchmark();
    stop_trigger();
    correct = verify_benchmark(result);
    console_put(correct ? 'P' : 'F');
    put_hex((unsigned)result);
    return !correct;
}
