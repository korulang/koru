#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>

static char *__koru_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *r = (char *)malloc(la + lb + 1);
    if (!r) { fputs("koru: out of memory\n", stderr); abort(); }
    memcpy(r, a, la);
    memcpy(r + la, b, lb + 1);
    return r;
}
static void __koru_stdout_write(const char *s) { fputs(s, stdout); }
static void __koru_stderr_write(const char *s) { fputs(s, stderr); }
static long long __koru_len_str(const char *s) { return (long long)strlen(s); }
static int __koru_streq(const char *a, const char *b) { return strcmp(a, b) == 0; }
static char *__koru_str_i64(long long v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", v);
    return __koru_concat(buf, "");
}
static void __koru_stdout_write_i64(long long v) { printf("%lld", v); }
static void __koru_stderr_write_i64(long long v) { fprintf(stderr, "%lld", v); }
static void __koru_stdout_write_f64(double v) { printf("%g", v); }
static void __koru_stderr_write_f64(double v) { fprintf(stderr, "%g", v); }
static void __koru_stdout_write_f64_prec(double v, int prec) { printf("%.*f", prec, v); }
static void __koru_stderr_write_f64_prec(double v, int prec) { fprintf(stderr, "%.*f", prec, v); }
static int __koru_argc;
static char **__koru_argv;
static char __koru_readln_buf[8192];
struct __koru_comptime_Expression { char __koru_comptime; };
struct __koru_comptime_Source { char __koru_comptime; };
static _Noreturn void __koru_unreachable(const char *what) {
    fflush(NULL); // buffered stdout must land before the trap (zig flushes; abort does not)
    fprintf(stderr, "koru: %s\n", what);
    abort();
}
static long long __koru_intcast(long long v, long long lo, long long hi) {
    if (v < lo || v > hi) __koru_unreachable("@intCast out of range");
    return v;
}
static unsigned long long __koru_intcast_u(unsigned long long v, unsigned long long lo, unsigned long long hi) {
    if (v < lo || v > hi) __koru_unreachable("@intCast out of range");
    return v;
}
static long long __koru_max_ll(long long a, long long b) { return a > b ? a : b; }
static long long __koru_min_ll(long long a, long long b) { return a < b ? a : b; }

struct __koru_slice_const_struct_Item { const struct Item *ptr; uintptr_t len; };
struct __koru_rec_sum_i32_max_i32 {
    int32_t sum;
    int32_t max;
};
static void std_control_capture(void);
static void std_testing_validate_mocks(void);
static const char * std_spec_spec_revision(void);
static struct __koru_rec_sum_i32_max_i32 input_compute_stats(void);

static void std_control_capture(void) {
    __koru_unreachable("std.control:capture: transform/comptime tor invoked on the C lane");
}

static void std_testing_validate_mocks(void) {
    __koru_unreachable("std.testing:validate-mocks: transform/comptime tor invoked on the C lane");
}

static const char * std_spec_spec_revision(void) {
    return "std/spec:0";
}

static struct __koru_rec_sum_i32_max_i32 input_compute_stats(void) {
    struct __koru_cap_c { int32_t sum; int32_t max; } c = { .sum = 0, .max = 0 };
const int32_t __koru_items2[] = { 3, 1, 4, 1, 5 };
    for (size_t __koru_i2 = 0; __koru_i2 < sizeof(__koru_items2) / sizeof(__koru_items2[0]); __koru_i2++)
        {
        { long long val = __koru_items2[__koru_i2];         {
            struct __koru_cap_c __koru_snap = c;
            __koru_snap.sum = c.sum + val;
            __koru_snap.max = (val > c.max ? val  :  c.max);
            c = __koru_snap;
        }
 }

        
    }
    {  }
    struct __koru_cap_c final = c;
    return (struct __koru_rec_sum_i32_max_i32){ .sum = final.sum, .max = final.max };
}

static void koru_flow_0(void) {
    struct __koru_rec_sum_i32_max_i32 const r = input_compute_stats();
__koru_stdout_write("sum="); __koru_stdout_write_i64((r.sum)); __koru_stdout_write(" max="); __koru_stdout_write_i64((r.max)); __koru_stdout_write("\n");}

int main(int argc, char **argv) {
    __koru_argc = argc;
    __koru_argv = argv;
    koru_flow_0();
    return 0;
}
