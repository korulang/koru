// AoC 2015 Day 22 — the two SCRIPTED statement fights, replayed exactly
// (fight 1: Poison, Magic Missile vs 13/8 → win, hp 2, mana 24; fight 2:
// the five-spell sequence vs 14/8 → win, hp 1, mana 114 — both end-states
// verbatim from the statement's turn narration). The actual puzzle ask
// (MINIMUM mana to win) is NOT pinned: a quick local BFS oracle disproved
// itself against the statement, and we do not pin against an untrusted
// oracle — min-mana lands when a trusted one exists.
//
// Engine math is FULLY worked out and python-oracled (turn-by-turn replay,
// player start hp 10 / mana 250; start-of-turn Shield/Poison/Recharge timers;
// spell effects; boss attack max(1, dmg-armor); poison can kill the boss at a
// turn start → win). Encoding it is blocked on a REAL obligation-system gap,
// not on the simulation — confirmed by reproduction (see below):
//
// GAP — obligation threading through value-recursion / label-folds.
//   The spell SCRIPT is variable-length, so it must be read into an indexable
//   std/list (an OWNED *List_i64<list!>), then the turn engine recurses
//   turn-by-turn (a value-recursive event, 320_095) RANDOM-ACCESSING that list
//   per player turn. Carrying that owned list-handle into a user event's
//   parameter, or threading it through a recursive/label-fold continue
//   payload, trips the phantom checker:
//
//     error[KORU030]: Phantom state mismatch: expected 'input:list' but got
//       'std.list:list!' for argument 'spells'
//
//   The user-event parameter's phantom state is namespaced to the user module
//   ('input:list'), and that does NOT unify with the std/list-namespaced state
//   the live handle carries ('std.list:list!'), so a freshly-`new`-ed list
//   cannot be passed to ANY user event that declares a `*List_i64<...>` param.
//   The same gap surfaces two other ways on adjacent encodings:
//     • "Label jump '@r' drops cleanup obligation for '_.nxt'" — an owned list
//       threaded through a #r/@r continue payload reads as a leak at the jump
//       instead of a hand-off to the re-invocation.
//     • "Unknown event referenced" (terser, at emit time) — when an owned
//       list-handle field rides inside a struct branch payload returned from
//       an event's top-level `if`.
//   (Minimal repro: any user event `pub event f { xs: *List_i64<!list> }` with
//   a `new`-ed list passed in → KORU030 at the call. Structurally IDENTICAL to
//   the day-10 round-step/say idiom, which is itself stubbed RED for the SAME
//   reason — see 810_101's ledger.)
//
//   This is design-shaped (ownership transfer of a phantom-obligation resource
//   through user-event params and fold/recursion payloads — no namespace
//   unification between 'input:' and 'std.list:' phantom states), not a missing
//   leaf. Left RED honestly pending that work. Everything ELSE the engine needs
//   (regex bhp/bdmg parse, std/string:split spell tail, branchless effect math,
//   value-recursion) is already green in the corpus; only the indexable owned
//   spell-list handoff is blocked.

import std/io
import std/fs

pub event fight { line: string }
| outcome string

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_221_day22_part1/input.txt")
! line l |> fight(line: l)
    | outcome o |> std/io:print.ln("{{ o:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
