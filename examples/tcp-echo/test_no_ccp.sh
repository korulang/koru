#!/bin/bash
# Test tcp-echo WITHOUT CCP

echo "Starting tcp-echo WITHOUT CCP..."
./zig-out/bin/tcp-echo > no_ccp_output.txt 2>&1 &
SERVER_PID=$!

sleep 2

echo "Sending test message..."
echo "Hello without CCP!" | nc localhost 9999

sleep 1

echo "Stopping server..."
kill $SERVER_PID 2>/dev/null

echo ""
echo "Server output (should be NO JSON):"
cat no_ccp_output.txt

echo ""
echo "Test complete!"
