/* Naive scalar reduction: strict IEEE, serial accumulator. Compiled plain
 * (-O3) this is the honest "hand-written strict loop" competitor — LLVM cannot
 * reassociate the float sum so it stays sequential, exactly like the Koru
 * reduce loop does.
 *
 * Build:    cc -O3 -march=native bench.c -o bench
 *
 * The headroom reference: compile the SAME source with reassociation allowed —
 *      cc -O3 -ffast-math -march=native bench.c -o bench_fast
 * LLVM then keeps 4-wide partial sums and SIMD-vectorizes the loop, which is
 * where the ~490x the Koru reduce leaves on the table is measured. Same output;
 * only the float-order (rounding) is relaxed, which the README notes.
 */
#include <stdio.h>
#include <stdlib.h>
#define N 64
int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 1;
    double m[N];
    for (int i = 0; i < N; i++) m[i] = (double)(i * 999 + 1) + 0.5;
    double total = 0;
    long count = 0;
    for (long s = 0; s < n; s++)
        for (int i = 0; i < N; i++) { total += m[i]; count++; }
    printf("total=%.0f count=%ld\n", total, count);
    return 0;
}
