#!/bin/bash
# Test CCP observability in tcp-echo

echo "Starting tcp-echo with CCP observability..."
./zig-out/bin/tcp-echo > ccp_output.jsonl 2>&1 &
SERVER_PID=$!

sleep 2

echo "Sending test message..."
echo "Hello CCP!" | nc localhost 9999

sleep 1

echo "Stopping server..."
kill $SERVER_PID 2>/dev/null

echo ""
echo "CCP events captured in ccp_output.jsonl:"
cat ccp_output.jsonl

echo ""
echo "CCP test complete!"
