/* Hand-written C. No generated header is included — this is the declaration a
   plugin author writes by hand, which is the whole point of a C ABI. */
#include <stdio.h>
#include <stddef.h>

void apply_gain(const float *input, size_t input_len,
                float *output, size_t output_len, float gain);
float sum_buffer(const float *values, size_t values_len);

int main(void) {
    float in[8]  = {0.0f, 0.25f, 0.5f, -0.5f, 1.0f, -1.0f, 0.125f, -0.75f};
    float out[8] = {0};
    apply_gain(in, 8, out, 8, 0.5f);
    for (int i = 0; i < 8; i++) {
        float want = in[i] * 0.5f;
        if (out[i] != want) {
            printf("FAIL: sample %d is %f, expected %f\n", i, out[i], want);
            return 1;
        }
    }
    float s = sum_buffer(in, 8);
    if (s != -0.375f) { printf("FAIL: sum is %f, expected -0.375\n", s); return 1; }
    printf("PASS: C wrote through a Koru-owned gain stage and read a scalar back\n");
    return 0;
}
