# Koru Web Server Example

A simple HTTP server demonstrating Koru's event-driven architecture.

## Features

- **Event-driven request handling** - Each request flows through event chains
- **Pattern matching routes** - Routes matched via event branches
- **Clean error handling** - 404s and errors handled through event branches
- **JSON API support** - Demonstrates both HTML and JSON responses
- **Stdlib integration** - Uses `http.kz` and `io.kz` from standard library

## Routes

- `GET /` - Home page with links
- `GET /about` - About Koru
- `GET /api/hello` - JSON greeting
- `GET /api/time` - Current server timestamp
- Everything else - 404 page

## Event Flow

```
serve
  └─> http:parse_request
       ├─> request -> handle_request
       │             ├─> match "/" -> handle_home -> format_response
       │             ├─> match "/about" -> handle_about -> format_response
       │             ├─> match "/api/*" -> handle_api -> format_response
       │             └─> no_match -> format_404
       └─> invalid -> error
```

## Running the Demo

```bash
koruc server.kz
./server
```

The demo simulates three requests:
1. `GET /` - Home page
2. `GET /api/hello` - JSON API
3. `GET /nonexistent` - 404 page

## What This Demonstrates

### 1. Event Chaining
Requests flow through event chains with pattern matching:
```koru
~serve =
    http:parse_request(data: request_data)
    | request req |> handle_request(method: req.method, path: req.path)
        | response r |> format_response(status: r.status, body: r.body)
        | not_found |> format_404()
    | invalid err |> error { msg: err.msg }
```

### 2. Route Matching
Nested pattern matching for routes:
```koru
http:match_route(path: path, pattern: "/")
| matched |> handle_home(method: method)
| no_match |>
    http:match_route(path: path, pattern: "/about")
    | matched |> handle_about(method: method)
    | no_match |> ...
```

### 3. Clean Field Access
Handler procs use unpacked field names directly:
```koru
~proc handle_home {
    if (std.mem.eql(u8, method, "GET")) {  // ← Clean! No e.method!
        return .{ .response = .{ .status = 200, .body = "..." }};
    }
}
```

### 4. Error Handling
Every event explicitly handles success and failure branches:
- `parse_request` → `request` | `invalid`
- `handle_request` → `response` | `not_found`
- `serve` → `response` | `error`

## Future Extensions

This example could be extended to:
- **Real TCP server** - Accept actual connections (net.kz)
- **Middleware chain** - Authentication, logging, etc.
- **Template rendering** - Generate HTML from data
- **Database integration** - Store and retrieve data
- **WebSocket support** - Real-time communication
- **Event observability** - Tap into request events for metrics

## Why Koru?

This example shows how Koru makes HTTP servers **explicit and composable**:
- Every possible outcome is visible in the event flow
- Error handling is baked into the architecture
- Routes are just pattern matching on events
- Easy to test (just invoke events with mock data!)
- Easy to observe (add taps anywhere in the event chain!)

Traditional frameworks hide control flow in callbacks and middleware. Koru makes it **explicit and beautiful**. 🚀
