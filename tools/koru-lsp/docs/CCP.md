# Compiler Communication Protocol (CCP)

JSONL over stdin/stdout. One JSON object per line. Responses ditto.

Launch:

```bash
koruc --ccp
```

The daemon prints `{"type":"ready","version":"…"}` and blocks for commands until stdin
closes or `{"cmd":"exit"}`.

## Transport

- **Request:** single-line JSON with a `"cmd"` field. Optional `"id"` (number) for correlation.
- **Response:** single-line JSON with a `"type"` field. Echoes `"id"` when the request carried one.
- **Errors:** `{"type":"error","msg":"…"}` or `{"type":"error","id":1,"msg":"…"}`
- **Trace:** `KORU_CCP_TRACE=1` logs commands/responses on **stderr** (stdout stays JSONL-only).

Commands are parsed with `std.json` (nested `"text"` in `open`/`change` is supported).

## Implemented today

| cmd | fields | response type | notes |
|-----|--------|---------------|-------|
| `open` | `file`, `text`, `version?` | `opened` | In-memory buffer overrides disk |
| `change` | `file`, `text`, `version` | `changed` | Replace buffer text |
| `close` | `file` | `closed` | Drop buffer |
| `parse` | `file`, `merge_companions?` | `parsed` | Uses buffer when open, else disk |
| `ast_json` | `file`, `merge_companions?` | `ast_json` | Same path as `parse` |
| `glance` | `file`, `app?` | `glance` | Module/event counts |
| `hover` | `file`, `line`, `column` | `hover` | Markdown + optional definition link |
| `definition` | `file`, `line`, `column` | `definition` | Target location (1-based line/column) |
| `diagnostics` | `file` | `diagnostics` | Parse-time errors from `ErrorReporter` |
| `completion` | `file`, `line`, `column` | `completion` | Import paths + module events |
| `compile` | `entry` | `compiled` | **Stub** |
| `set_flag` | `flag` | `flag_set` | e.g. `emit_ccp` |
| `exit` | — | `exit` | Terminates daemon |

## Planned (LSP support)

| cmd | fields | response type | purpose |
|-----|--------|---------------|---------|
| `hover` | (existing) | `hover` | Deeper type/signature info |
| `diagnostics` | (existing) | `diagnostics` | Shape/flow/abstract-impl passes |

### `hover` response (target)

```json
{
  "type": "hover",
  "id": 7,
  "file": "app.k",
  "line": 8,
  "column": 12,
  "contents": "**std/store:new**(entity: string)\n\n`store.kz:120`",
  "definition": {
    "file": "/abs/path/koru_std/store.kz",
    "line": 120,
    "column": 1
  }
}
```

Null/absent `definition` when nothing resolves at the cursor.

### `diagnostics` response

```json
{
  "type": "diagnostics",
  "id": 20,
  "file": "app.k",
  "items": [
    {
      "line": 7,
      "column": 20,
      "endLine": 7,
      "endColumn": 29,
      "severity": "error",
      "code": "KORU033",
      "message": "invalid phantom-state syntax",
      "hint": "phantom state uses angle brackets — write `*Resource<active!>`"
    }
  ]
}
```

Line/column are **1-based**, matching Koru CLI diagnostics.

### Buffer precedence

Parse/hover/definition use buffer text when the file is `open`; otherwise read from disk
(relative to process cwd). LSP clients should `open` on `didOpen`.

## Versioning

`ready.version` tracks `koruc` (currently `0.1.7` in `src/ccp.zig`).

## Related code

| Location | Role |
|----------|------|
| `src/ccp.zig` | Frontend daemon |
| `src/frontend_introspect.zig` | Shared parse + import path |
| `src/main.zig` | CLI `glance`, `--ast-json` |
| `tools/koru-lsp/package/` | TypeScript LSP wrapper |
| `tools/koru-lsp/vscode/` | VS Code / Cursor extension |
| `koru_std/compiler.kz` | Backend `process-ccp-commands` — **not** this daemon |

## Manual test

```bash
./tools/koru-lsp/scripts/smoke-ccp.sh
```

See also `docs/DEBUGGING.md`.
