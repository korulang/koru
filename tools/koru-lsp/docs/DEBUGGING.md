# Debugging Koru LSP

Three layers — pick the one that matches the symptom.

```
Cursor/VS Code  ──JSON-RPC──►  koru-lsp (Node)  ──JSONL──►  koruc --ccp (Zig)
```

## Two windows — what goes where

| Window | Workspace | Purpose |
|--------|-----------|---------|
| **1 — Dev** | `~/src/koru` | Edit compiler, LSP, extension. Press **F5** here. |
| **2 — Extension Host** | `~/src/koru-examples` | Pretend to be a user. Open `.k` files here. |

Do **not** hack on the compiler in window 2 — it's the "user project" sandbox.
Do **not** expect window 2 to open the koru repo by default; the launch config
now passes `../koru-examples` so Cursor stops bouncing you back to the monorepo.

Optional: a separate Cursor instance with only `tools/koru-lsp` open is fine if
you're extension-only, but you still need `koruc` built in the main repo and
`KORUC_PATH` pointing at it. Default workflow keeps window 1 on `koru`.

## Checkpoint 1 — Extension Development Host

**When:** first time testing in Cursor/VS Code.

1. Build everything:

```bash
zig build
cd tools/koru-lsp/package && npm install && npm run build
cd ../vscode && npm install && npm run build
```

2. Open **`~/src/koru`** in Cursor (window 1).
3. Run **Run and Debug** → **Launch Koru Extension**.
4. Window 2 opens with **`koru-examples`** already loaded.
5. Open e.g. `gallery/gallery.k` or `todo/todo_tui.k`.
6. Check **Output → Koru** for `CCP ready`.

Use **Launch Koru Extension (koru repo)** only when testing regression fixtures
inside the compiler tree.

Optional compound launch **Extension + LSP** attaches Node debugger to port 9229.

## Checkpoint 3 — Syntax + diagnostics

**When:** verifying colors and red squiggles after hover/definition already work.

1. Rebuild (`zig build`, `npm run build` in `package/` and `vscode/`).
2. F5 → open `todo/todo_tui.k` in the Extension Host.
3. **Syntax:** imports, `std/store:new`, `|>`, `!` branches, `{% liquid %}`, `<instance!>` phantoms should color.
4. **Diagnostics:** in any `.k` file, change a phantom to square brackets — e.g.
   `String<instance!>` → `String[instance!]` — expect `KORU033` squiggle after ~400ms.

Diagnostics are **parse-time only** for now (not shape/flow/abstract-impl).
Some later-pass errors (e.g. bare `const` on `.k`) won't squiggle yet.

| Symptom | Check |
|---------|-------|
| No colors | Extension not active — open a `.k` file; grammar loads on `onLanguage:koru` |
| No squiggles but hover works | CCP `diagnostics` failing — enable `koru.trace.server`: `verbose` |
## Checkpoint 4 — Completion

**When:** verifying Koru-native completions (not Copilot word guesses).

1. Rebuild (`zig build`, `npm run build` in `package/`).
2. F5 → open `todo/todo_tui.k` (must have `import std/store` at top).
3. On a line with `std/store:`, type after the colon — expect `new`, `insert`, `sweep`, etc. with signatures in the detail.
4. On `import std/st`, expect module path suggestions (`std/store`, `std/string`, …).

Trigger characters: `:` and `/`. Real completions come from CCP; ghost-text from Copilot is separate.

| Symptom | Check |
|---------|-------|
| Only word matches, no signatures | Not koru-lsp — disable Copilot inline suggest briefly to compare |
| Empty after `:` | Module not imported yet — v1 completes events from imported modules only |
| No import paths | `KORU_PROJECT_ROOT` / cwd must reach `koru.json` for `std` alias |

## Layer 1 — Editor / extension

| Symptom | Check |
|---------|-------|
| No Koru language mode | Extension not loaded; confirm `.k` extension in `vscode/package.json` |
| No LSP output channel | Extension failed to spawn server; check **Help → Toggle Developer Tools → Console** |
| Wrong koruc binary | Setting `koru.korucPath` or env `KORUC_PATH` |

Trace LSP wire:

```json
"koru.trace.server": "verbose"
```

## Layer 2 — koru-lsp (Node)

Standalone:

```bash
export KORUC_PATH="$PWD/zig-out/bin/koruc"
export KORU_PROJECT_ROOT="$PWD"
export KORU_LSP_LOG=1
node --inspect-brk tools/koru-lsp/package/dist/server.js --stdio
```

Attach **Attach to koru-lsp** (port 9229). `KORU_LSP_LOG=1` prints every CCP line on stderr.

## Layer 3 — koruc --ccp (Zig)

No editor:

```bash
./tools/koru-lsp/scripts/smoke-ccp.sh
```

Trace JSONL on stderr (stdout stays clean):

```bash
KORU_CCP_TRACE=1 printf '{"cmd":"glance","file":"path/to/file.k"}\n{"cmd":"exit"}\n' | ./zig-out/bin/koruc --ccp
```

CLI control for the same frontend path:

```bash
./zig-out/bin/koruc path/to/file.k glance
```

## Environment variables

| Variable | Layer | Effect |
|----------|-------|--------|
| `KORUC_PATH` | LSP | Path to `koruc` binary |
| `KORU_PROJECT_ROOT` | LSP | CCP process cwd (import resolution) |
| `KORU_LSP_LOG=1` | LSP | Log CCP requests/responses on stderr |
| `KORU_CCP_TRACE=1` | CCP | Log JSONL commands on stderr |

## Zed (later)

Same `koru-lsp` binary; needs a thin Zed extension to register `.k`/`.kz` and point at the server. Debug via Zed log panel + `KORU_LSP_LOG=1`.
