// C Function Pointer Baseline
// Producer calls registered callbacks for 10M events
//
// The simplest possible event emission pattern:
// - Array of function pointers
// - Iterate and call on each emit
//
// This is the BARE MINIMUM overhead for callbacks.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#define MESSAGES 10000000ULL
#define MAX_HANDLERS 16

// Global accumulator
static uint64_t sum = 0;

// Callback types
typedef void (*NextHandler)(uint64_t value);
typedef void (*DoneHandler)(void);

// Simple event emitter
typedef struct {
    NextHandler next_handlers[MAX_HANDLERS];
    int next_count;
    DoneHandler done_handlers[MAX_HANDLERS];
    int done_count;
} EventEmitter;

void emitter_init(EventEmitter* e) {
    e->next_count = 0;
    e->done_count = 0;
}

void emitter_on_next(EventEmitter* e, NextHandler handler) {
    if (e->next_count < MAX_HANDLERS) {
        e->next_handlers[e->next_count++] = handler;
    }
}

void emitter_on_done(EventEmitter* e, DoneHandler handler) {
    if (e->done_count < MAX_HANDLERS) {
        e->done_handlers[e->done_count++] = handler;
    }
}

void emitter_emit_next(EventEmitter* e, uint64_t value) {
    for (int i = 0; i < e->next_count; i++) {
        e->next_handlers[i](value);
    }
}

void emitter_emit_done(EventEmitter* e) {
    for (int i = 0; i < e->done_count; i++) {
        e->done_handlers[i]();
    }
}

// Handlers
void accumulate(uint64_t value) {
    sum += value;
}

void validate(void) {
    uint64_t expected = MESSAGES * (MESSAGES - 1) / 2;
    if (sum == expected) {
        printf("✓ C Callbacks: Validated %llu messages (checksum: %llu)\n", MESSAGES, sum);
    } else {
        printf("✗ C Callbacks: CHECKSUM MISMATCH! got %llu, expected %llu\n", sum, expected);
        exit(1);
    }
}

int main(void) {
    EventEmitter emitter;
    emitter_init(&emitter);

    // Register observers
    emitter_on_next(&emitter, accumulate);
    emitter_on_done(&emitter, validate);

    // Producer: emit 10M events
    for (uint64_t i = 0; i < MESSAGES; i++) {
        emitter_emit_next(&emitter, i);
    }
    emitter_emit_done(&emitter);

    return 0;
}
