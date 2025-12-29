// Go Baseline: Producer/Consumer with Buffered Channels
//
// Tests idiomatic Go concurrency:
// - Buffered channel (1024 capacity, like MPMC ring)
// - Goroutines (2 threads: producer + consumer)
// - Channel send/receive (10M messages)
// - Synchronization (WaitGroup)
// - Data integrity (checksum validation)
//
// This is how you'd actually write concurrent Go code.

package main

import (
	"fmt"
	"sync"
)

const MESSAGES = 10_000_000
const BUFFER_SIZE = 1024

func main() {
	// Buffered channel - like MPMC ring with 1024 capacity
	messages := make(chan uint64, BUFFER_SIZE)

	var wg sync.WaitGroup
	wg.Add(1)

	// Producer goroutine - send 10M messages
	go func() {
		defer wg.Done()
		for i := uint64(0); i < MESSAGES; i++ {
			messages <- i
		}
		close(messages)
	}()

	// Consumer runs on MAIN THREAD (same as Zig, Rust, and Koru!)
	var sum uint64
	for msg := range messages {
		sum += msg
	}

	// Wait for producer to complete
	wg.Wait()

	// Validate checksum (sum of 0 to N-1 = N*(N-1)/2)
	expected := uint64(MESSAGES * (MESSAGES - 1) / 2)
	if sum == expected {
		fmt.Printf("✓ Go: Validated %d messages (checksum: %d)\n", MESSAGES, sum)
	} else {
		fmt.Printf("✗ Go: CHECKSUM MISMATCH! got %d, expected %d\n", sum, expected)
	}
}
