#!/bin/bash
# Test the TCP echo server

echo "Starting tcp-echo server..."
./zig-out/bin/tcp-echo &
SERVER_PID=$!

sleep 1

echo "Sending test message..."
echo "Hello from Koru!" | nc localhost 9999

sleep 1

echo "Cleaning up..."
kill $SERVER_PID 2>/dev/null

echo "Test complete!"
