// C Function Pointer Baseline - 5 Handlers
// Tests: How does callback overhead scale with subscriber count?

#include <stdio.h>
#include <stdint.h>

#define MESSAGES 10000000ULL
#define NUM_HANDLERS 5

static volatile uint64_t sum1 = 0, sum2 = 0, sum3 = 0, sum4 = 0, sum5 = 0;

void handler1(uint64_t value) { sum1 += value; }
void handler2(uint64_t value) { sum2 += value; }
void handler3(uint64_t value) { sum3 += value; }
void handler4(uint64_t value) { sum4 += value; }
void handler5(uint64_t value) { sum5 += value; }

typedef void (*Handler)(uint64_t);
// volatile to prevent compiler from optimizing away the indirection
static volatile Handler handlers[NUM_HANDLERS] = { handler1, handler2, handler3, handler4, handler5 };

int main(void) {
    // Producer: emit 10M events to NUM_HANDLERS subscribers
    for (uint64_t i = 0; i < MESSAGES; i++) {
        for (int h = 0; h < NUM_HANDLERS; h++) {
            handlers[h](i);
        }
    }

    // Validate (each handler should have the same sum)
    uint64_t expected = MESSAGES * (MESSAGES - 1) / 2;
    if (sum1 == expected && sum2 == expected && sum3 == expected && sum4 == expected && sum5 == expected) {
        printf("C (%d handlers): Validated %llu messages (checksum: %llu)\n", NUM_HANDLERS, MESSAGES, sum1);
    } else {
        printf("C (%d handlers): CHECKSUM MISMATCH!\n", NUM_HANDLERS);
        return 1;
    }
    return 0;
}
