// C Function Pointer Baseline - 1 Handler
// Tests: How does callback overhead scale with subscriber count?

#include <stdio.h>
#include <stdint.h>

#define MESSAGES 10000000ULL
#define NUM_HANDLERS 1

static volatile uint64_t sum1 = 0;

void handler1(uint64_t value) { sum1 += value; }

typedef void (*Handler)(uint64_t);
// volatile to prevent compiler from optimizing away the indirection
static volatile Handler handlers[NUM_HANDLERS] = { handler1 };

int main(void) {
    // Producer: emit 10M events to NUM_HANDLERS subscribers
    for (uint64_t i = 0; i < MESSAGES; i++) {
        for (int h = 0; h < NUM_HANDLERS; h++) {
            handlers[h](i);
        }
    }

    // Validate
    uint64_t expected = MESSAGES * (MESSAGES - 1) / 2;
    uint64_t total = sum1;
    if (total == expected) {
        printf("C (%d handlers): Validated %llu messages (checksum: %llu)\n", NUM_HANDLERS, MESSAGES, total);
    } else {
        printf("C (%d handlers): CHECKSUM MISMATCH! got %llu, expected %llu\n", NUM_HANDLERS, total, expected);
        return 1;
    }
    return 0;
}
