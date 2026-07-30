# Koru LSP

Editor tooling for Koru: a thin **TypeScript LSP** in front of **`koruc --ccp`**
(the Compiler Communication Protocol daemon).

## Architecture

```
┌──────────────┐   JSON-RPC    ┌─────────────────┐   JSONL/stdio   ┌─────────────┐
│ Cursor/VSCode│ ◄───────────► │  koru-lsp (TS)  │ ◄──────────────►│ koruc --ccp │
└──────────────┘               └─────────────────┘                 └─────────────┘
                                      │                                    │
                              textDocument/*                         open, change,
                              (LSP wire)                             parse, hover…
                                                                           │
                                                                           ▼
                                                                 frontend_introspect
                                                                 (same path as `glance`)
```

- **CCP** owns Koru semantics — parse, import resolution, hover, definition.
- **koru-lsp** owns LSP wire format, document sync, spawning the daemon.
- No directory watching in koruc; the editor **pushes** buffer text via `open` /
  `change` (standard LSP `didOpen` / `didChange`).

## Layout

| Path | Purpose |
|------|---------|
| `docs/CCP.md` | CCP command schema |
| `docs/DEBUGGING.md` | How to debug each layer |
| `package/` | TypeScript language server (`vscode-languageserver`) |
| `vscode/` | VS Code / Cursor extension (thin client) |
| `fixtures/` | Sample JSONL command streams |
| `scripts/smoke-ccp.sh` | Pipe commands at `koruc --ccp` |
| `.vscode/launch.json` | Extension Development Host + LSP attach |

## Prerequisites

- Built compiler: `zig build` → `zig-out/bin/koruc`
- Node 20+

## Build

```bash
zig build
cd tools/koru-lsp/package && npm install && npm run build
cd ../vscode && npm install && npm run build
```

## Smoke-test CCP

```bash
./tools/koru-lsp/scripts/smoke-ccp.sh
```

## Try in Cursor / VS Code

See **`docs/DEBUGGING.md`** for the full two-window workflow. Quick path:

1. Build (above).
2. Open **`~/src/koru`** → **Run and Debug** → **Launch Koru Extension**.
3. Extension Host opens **`koru-examples`** — open e.g. `todo/todo_tui.k`.
4. Check **Output → Koru** for `CCP ready`.

### What works today

| Feature | Status |
|---------|--------|
| Syntax highlighting | TextMate grammar for `.k`/`.kz`/`.kjs` |
| Hover | Resolves `std/module:event` against imports |
| Go to definition | Jumps to definition site (e.g. `koru_std/store.kz`) |
| Diagnostics | Parse-time errors from `ErrorReporter` (red squiggles) |
| Completion | Import paths + `module:event` from resolved AST |
| Completion (deeper) | Not yet — Copilot may still suggest words |

Introduce a parse error (e.g. `*Resource[active!]` instead of `<active!>`) to
see diagnostics. Hover/definition on `std/store:new`-style calls in valid files.

## Status

- CCP: `open`/`change`/`close`, `parse`, `glance`, `hover`, `definition`, `diagnostics`
- koru-lsp: document sync, hover, definition, debounced diagnostics publish
- VS Code extension: grammar, language config, Koru output channel
- Next: deeper diagnostics (shape/flow passes), Zed extension
