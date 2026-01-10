def ping(value):
    return {"branch": "pong", "value": value}

ITERATIONS = 10_000_000
result = None
for i in range(ITERATIONS):
    result = ping("test")

print(f"OK: {result['branch']}")
