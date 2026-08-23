// Manifest Server - serve a registered scope's manifest as the live contract
// endpoint.
//
// The scope's record is minted at scope creation (std/runtime:register) from
// the same event data the dispatch tables are emitted from; GET /manifest
// serializes that record to JSON via std/runtime:scope-manifest. The served
// contract and the enforcement are the same bytes - a drifted manifest is
// impossible, not just avoided. Route bodies are plain Koru chains.
//
// Run: koruc main.k && ./a.out
// curl localhost:3456/manifest
//
// NOTE: currently blocks on the compiler's abstract-handler binding (request
// time panics "reached handler, which nothing implements"); worked in the
// immediately-previous compiler build - see session notes.

import orisha
import std/runtime
import std/io

// ============================================================================
// THE SCOPE - a small vocabulary with possession arcs
// ============================================================================

pub tor open-note { path: string } -> string<open!>

open-note -> { "note_0" }

pub tor close-note { handle: string<!open> }

close-note -> {}

std/runtime:register(scope: "notes") {
    open-note(10)
    close-note(1)
}

// ============================================================================
// SERVE THE RECORD
// ============================================================================

orisha:handler = orisha:router(req)
! [GET /] |> response { status: 200, body: "manifest server - GET /manifest for the scope contract", content_type: "text/plain" }
! [GET /manifest] |> std/runtime:scope-manifest(name: "notes")
    | ok json |> response { status: 200, body: json, content_type: "application/json" }
    | not-found |> response { status: 404, body: "scope not found", content_type: "text/plain" }
! [*] |> response { status: 404, body: "not found", content_type: "text/plain" }

orisha:serve(port: 3456)
| shutdown _ |> _
| failed f |> std/io:print.ln(f)