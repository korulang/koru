// Go Callback Slice Baseline
// Producer calls registered callbacks for 10M events
//
// Go doesn't have built-in events, so people use callback slices.
// This is the idiomatic Go pattern for pub/sub.

package main

import "fmt"

const MESSAGES uint64 = 10_000_000

// Simple event emitter with callbacks
type EventEmitter struct {
	nextHandlers []func(uint64)
	doneHandlers []func()
}

func NewEventEmitter() *EventEmitter {
	return &EventEmitter{
		nextHandlers: make([]func(uint64), 0),
		doneHandlers: make([]func(), 0),
	}
}

func (e *EventEmitter) OnNext(handler func(uint64)) {
	e.nextHandlers = append(e.nextHandlers, handler)
}

func (e *EventEmitter) OnDone(handler func()) {
	e.doneHandlers = append(e.doneHandlers, handler)
}

func (e *EventEmitter) EmitNext(value uint64) {
	for _, handler := range e.nextHandlers {
		handler(value)
	}
}

func (e *EventEmitter) EmitDone() {
	for _, handler := range e.doneHandlers {
		handler()
	}
}

func main() {
	var sum uint64 = 0

	emitter := NewEventEmitter()

	// Register observers
	emitter.OnNext(func(value uint64) {
		sum += value
	})

	emitter.OnDone(func() {
		expected := MESSAGES * (MESSAGES - 1) / 2
		if sum == expected {
			fmt.Printf("✓ Go Callbacks: Validated %d messages (checksum: %d)\n", MESSAGES, sum)
		} else {
			fmt.Printf("✗ Go Callbacks: CHECKSUM MISMATCH! got %d, expected %d\n", sum, expected)
		}
	})

	// Producer: emit 10M events
	var i uint64
	for i = 0; i < MESSAGES; i++ {
		emitter.EmitNext(i)
	}
	emitter.EmitDone()
}
