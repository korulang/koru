// C Conditional Callbacks Baseline
// Tests: What happens when handlers have conditions but all get dispatched?
//
// Scenario: 10M events with values 0-99
// 10 handlers, each only cares about 1/10th of values (ranges 0-9, 10-19, etc.)
// Average: only 1 handler does real work per event
// But: ALL 10 handlers get dispatched and check their condition
//
// This is the "achievement system" / "rule engine" / "event filter" pattern.

#include <stdio.h>
#include <stdint.h>

#define MESSAGES 10000000ULL
#define NUM_HANDLERS 10

// Each handler accumulates values in its range
static volatile uint64_t sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0, sum4 = 0;
static volatile uint64_t sum5 = 0, sum6 = 0, sum7 = 0, sum8 = 0, sum9 = 0;

// Each handler checks if value is in its range, then accumulates
void handler0(uint64_t value) { if ((value % 100) < 10) sum0 += value; }
void handler1(uint64_t value) { if ((value % 100) >= 10 && (value % 100) < 20) sum1 += value; }
void handler2(uint64_t value) { if ((value % 100) >= 20 && (value % 100) < 30) sum2 += value; }
void handler3(uint64_t value) { if ((value % 100) >= 30 && (value % 100) < 40) sum3 += value; }
void handler4(uint64_t value) { if ((value % 100) >= 40 && (value % 100) < 50) sum4 += value; }
void handler5(uint64_t value) { if ((value % 100) >= 50 && (value % 100) < 60) sum5 += value; }
void handler6(uint64_t value) { if ((value % 100) >= 60 && (value % 100) < 70) sum6 += value; }
void handler7(uint64_t value) { if ((value % 100) >= 70 && (value % 100) < 80) sum7 += value; }
void handler8(uint64_t value) { if ((value % 100) >= 80 && (value % 100) < 90) sum8 += value; }
void handler9(uint64_t value) { if ((value % 100) >= 90) sum9 += value; }

typedef void (*Handler)(uint64_t);
static volatile Handler handlers[NUM_HANDLERS] = {
    handler0, handler1, handler2, handler3, handler4,
    handler5, handler6, handler7, handler8, handler9
};

int main(void) {
    // Producer: emit 10M events, dispatch to ALL handlers
    // Each handler checks condition internally
    for (uint64_t i = 0; i < MESSAGES; i++) {
        for (int h = 0; h < NUM_HANDLERS; h++) {
            handlers[h](i);  // ALL handlers called, most do nothing
        }
    }

    // Validate - each bucket should have sum of values in its range
    uint64_t total = sum0 + sum1 + sum2 + sum3 + sum4 + sum5 + sum6 + sum7 + sum8 + sum9;
    uint64_t expected = MESSAGES * (MESSAGES - 1) / 2;

    if (total == expected) {
        printf("C (10 conditional handlers): Validated %llu messages (checksum: %llu)\n", MESSAGES, total);
    } else {
        printf("C (10 conditional handlers): CHECKSUM MISMATCH! got %llu, expected %llu\n", total, expected);
        return 1;
    }
    return 0;
}
