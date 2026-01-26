# CCP: Compiler Communication Protocol

**Status**: Design phase

## Overview

CCP enables Koru Studio to maintain a persistent, bidirectional connection with the Koru compiler. The compiler runs as a long-lived daemon, accepting commands via stdin and streaming responses via stdout.

## Invocation

```bash
koruc --ccp
# Compiler enters daemon mode, waits for JSONL commands on stdin
```

No source file argument - files are specified via commands.

## Protocol

- **Transport**: stdin (commands) / stdout (responses) 
- **Format**: JSONL (one JSON object per line)
- **stderr**: Reserved for human-readable debug logs

## Commands (Studio → Compiler)

### `parse` - Parse a source file
```json
{"cmd":"parse","file":"src/main.kz"}
```

Response:
```json
{"type":"parsed","file":"src/main.kz","ast":{...},"diagnostics":[]}
```

### `compile` - Run compilation pipeline
```json
{"cmd":"compile","entry":"src/main.kz"}
```

Streams multiple responses:
```json
{"type":"pass_start","pass":"frontend","file":"src/main.kz"}
{"type":"pass_done","pass":"frontend","duration_ms":12}
{"type":"pass_start","pass":"check_structure"}
{"type":"pass_done","pass":"check_structure","duration_ms":3}
...
{"type":"compiled","output":"zig-out/bin/main"}
```

Or on error:
```json
{"type":"diagnostic","level":"error","msg":"Unknown event 'foo'","file":"src/main.kz","line":42,"col":5}
{"type":"compile_failed"}
```

### `ast` - Get AST at current state
```json
{"cmd":"ast"}
```

Response:
```json
{"type":"ast","data":{...}}
```

### `ast_json` - Get AST as JSON (like koruc --ast-json)
```json
{"cmd":"ast_json","file":"src/main.kz"}
```

Response:
```json
{"type":"ast_json","file":"src/main.kz","ast":{...}}
```

### `set_flag` - Set a compiler flag
```json
{"cmd":"set_flag","flag":"emit_ccp","value":true}
```

### `add_pass` - Inject a custom pass
```json
{"cmd":"add_pass","pass":"ast_dump","after":"frontend"}
```

### `remove_pass` - Remove an injected pass
```json
{"cmd":"remove_pass","pass":"ast_dump"}
```

### `exit` - Graceful shutdown
```json
{"cmd":"exit"}
```

Response:
```json
{"type":"exit","code":0}
```

Then compiler exits.

## Responses (Compiler → Studio)

All responses have a `type` field:

| Type | Description |
|------|-------------|
| `ready` | Compiler is ready for commands |
| `parsed` | File parsed successfully |
| `ast` | AST data |
| `ast_json` | AST as JSON |
| `pass_start` | Pipeline pass starting |
| `pass_done` | Pipeline pass completed |
| `diagnostic` | Error/warning/info message |
| `compiled` | Compilation succeeded |
| `compile_failed` | Compilation failed |
| `exit` | Acknowledging shutdown |
| `error` | Command error (invalid command, etc.) |

## Session Lifecycle

```
Studio                              Compiler
  │                                     │
  ├──── spawn koruc --ccp ─────────────►│
  │◄─── {"type":"ready"} ──────────────┤
  │                                     │
  │  (interactive session)              │
  │                                     │
  ├──── {"cmd":"parse",...} ───────────►│
  │◄─── {"type":"parsed",...} ─────────┤
  │                                     │
  ├──── {"cmd":"compile",...} ─────────►│
  │◄─── {"type":"pass_start",...} ─────┤
  │◄─── {"type":"pass_done",...} ──────┤
  │◄─── {"type":"compiled",...} ───────┤
  │                                     │
  │  (need fresh state)                 │
  │                                     │
  ├──── {"cmd":"exit"} ────────────────►│
  │◄─── {"type":"exit","code":0} ──────┤
  │                                     ╳
  │                                     │
  ├──── spawn koruc --ccp ─────────────►│
  │◄─── {"type":"ready"} ──────────────┤
  │                                     │
```

## Implementation Notes

### Compiler Side (Zig)

The main loop in `--ccp` mode:

```zig
// Pseudocode
pub fn ccpMain() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("{\"type\":\"ready\"}\n", .{});
    
    var line_buf: [64 * 1024]u8 = undefined;
    while (stdin.readUntilDelimiter(&line_buf, '\n')) |line| {
        const cmd = std.json.parse(Command, line);
        switch (cmd.cmd) {
            .parse => handleParse(cmd, stdout),
            .compile => handleCompile(cmd, stdout),
            .exit => {
                try stdout.print("{\"type\":\"exit\",\"code\":0}\n", .{});
                return;
            },
            // ...
        }
    } else |err| {
        // stdin closed, exit gracefully
        return;
    }
}
```

### Studio Side (TypeScript)

```typescript
const compiler = spawn('koruc', ['--ccp'], {
    stdio: ['pipe', 'pipe', 'inherit']  // stdin, stdout piped; stderr inherited
});

const rl = readline.createInterface({ input: compiler.stdout });

rl.on('line', (line) => {
    const msg = JSON.parse(line);
    switch (msg.type) {
        case 'ready': onReady(); break;
        case 'parsed': onParsed(msg); break;
        case 'compiled': onCompiled(msg); break;
        // ...
    }
});

function send(cmd: object) {
    compiler.stdin.write(JSON.stringify(cmd) + '\n');
}
```

## Future Extensions

- `watch` - File system watching (compiler notifies on changes)
- `debug` - Breakpoints in pipeline passes  
- `inject_mock` - Runtime mock injection (for --inter integration)
- `eval` - Evaluate Koru expression in current context
