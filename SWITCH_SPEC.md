# Spec: `std/switch` — value dispatch as a transform

## Goal

Add a stdlib construct that dispatches on an exact value (starting with a char)
and compiles to a Zig `switch` (jump/comparison), NOT to a regex DFA.

It exists to replace two bad options that exist today:

1. Nested `if(ch == 'x')` trees. These work — `tests/regression/810_AOC_2015/810_081_day08_part1/input.k`
   is a green per-char state machine built this way — but they are unreadable at depth.
2. `std/regex:match`. This works, but every literal arm compiles to a full DFA: a
   768-entry transition table per arm plus a per-char loop over the input. That is
   massive overkill for exact-value dispatch.

`std/switch:char` is the value-dispatch sibling of `std/regex:match`: same surface,
different engine.

## THE ONE HARD CONSTRAINT (read this first)

**DO NOT TOUCH THE PARSER, LEXER, OR BRANCH GRAMMAR.** Not one line.

The reason this is possible: a branch head in a transform dispatch is an **opaque
backtick string**. The parser already accepts arbitrary characters between
backticks — this is proven by the existing regex test (see below), whose arm heads
are things like `` `[a-z]+@[a-z]+` ``. The parser does not interpret the contents;
it hands the raw string to the transform proc.

A `[transform]` proc **owns the interpretation** of that opaque string. The shape
checker enforces the branch contract with zero match-specific code (a transform is
just a proc on an ordinary event). `std/regex:match` interprets the string as a
regex; `std/switch:char` will interpret it as a value / range / set.

So this feature is a **new transform that reuses the existing branch grammar
verbatim**. There is nothing to add to the parser. If you find yourself editing
`src/parser.zig`, `src/lexer.zig`, or branch-head parsing, you have gone wrong.

## Grounded surface form

This is the existing regex form, verbatim from
`tests/regression/600_STDLIB/640_REGEX/640_001_match_basic/input.k`:

```
import std/regex
import std/io

std/regex:match("foo@bar")
| `[a-z]+@[a-z]+` _ |> std/io:print.ln("matched-email")
| `[0-9]+` _ |> std/io:print.ln("matched-number")
| no-match |> std/io:print.ln("no-match")
```

`std/switch:char` mirrors that grammar exactly — the only difference is the module
name, the event name, and what is written inside the backticks:

```
import std/switch
import std/io

std/switch:char(ch)
| `a` c |> std/io:print.ln("got a")
| `b` c |> std/io:print.ln("got b")
| no-match |> std/io:print.ln("other")
```

Every token here already parses today:
- `std/switch:char(ch)` — the `module:event(arg)` call form (identical shape to
  `std/regex:match(...)`).
- `` | `a` `` — a branch whose head is a backtick opaque string. Same grammar as
  `` | `[a-z]+@[a-z]+` ``.
- `c` — the binding for the payload. Bind it, or discard it with `_`, exactly as
  `640_001` discards with `_`. (Same bind-or-discard contract regex arms obey.)
- `| no-match` — the fallback branch. Same token regex uses.

## Opaque-string content grammar (transform-side — THIS is what you implement)

The switch transform parses the content of each arm's backtick string. The proposed
mini-grammar (this lives entirely inside the transform; the parser never sees it):

- **single char**: `` `a` `` matches the char `a`.
- **range**: `` `a-z` `` matches `a` through `z`. (The `-` separator mirrors a regex
  character-class interior; here the switch transform parses it, not the regex
  engine.)
- **set**: `` `aeiou` `` matches any one of those chars.

DESIGN DECISION FOR LARS, not yet locked: range inclusivity and whether the
separator is `-` (char-class style) or something else. Default proposal: `a-z` is
inclusive, both ends. Do not invent a new operator for this — it is just characters
inside the opaque string.

## What the transform emits

The transform replaces the dispatch with a Zig `switch` on the dispatched value:

```
switch (ch) {
    'a' => { ...arm body... },
    'b' => { ...arm body... },
    else => { ...no-match body... },
}
```

- A range arm `` `a-z` `` emits a Zig range prong: `'a'...'z' => { ... }`.
- A set arm `` `aeiou` `` emits a multi-value prong: `'a', 'e', 'i', 'o', 'u' => { ... }`.
- The `no-match` arm emits the `else` prong.

This is the entire payoff vs regex: one indexed switch, zero transition tables, zero
per-char loop.

## How to build it (mirror the existing regex transform)

The reference implementation to copy the SHAPE of is `koru_std/regex.kz`. Read it.
The switch transform has the same structure, only the string interpretation and the
emitted code differ.

1. **Declare the event + proc in a new file `koru_std/switch.kz`**, mirroring how
   `koru_std/regex.kz` declares `match`:
   - A `[comptime|transform]` event `char` whose payload is the value to dispatch on
     (a `u8` / codepoint — analogous to regex's `input: []const u8`, but a single
     char, not a string).
   - The catch-all branch declaration and the optional `no-match` branch, following
     the exact form regex uses for `` | `*` * `` and `| ?no-match`.
   - A `[transform]proc char|zig` that receives the invocation and its continuations,
     reads each arm's opaque backtick string and its binding, and emits the Zig
     `switch` shown above as inline code.

2. **The transform proc reuses the same machine interface as regex's proc** (the
   invocation / containing item / program / allocator convention, returning a
   SiteResult with a replacement inline_code item). Do not invent a new convention;
   copy regex's.

3. **No changes outside `koru_std/switch.kz`** except wiring the new stdlib module in
   wherever `koru_std/regex.kz` is registered/discovered. Grep for how `regex` is
   wired and do the same for `switch`. If a build graph lists stdlib modules, add
   `switch.kz` alongside `regex.kz`.

## Acceptance tests to write (pin these)

Mirror `tests/regression/600_STDLIB/640_REGEX/640_001_match_basic/` structure:

1. Single-char dispatch: a `std/switch:char(ch)` with two literal arms and `no-match`,
   asserting the right branch fires. Verify the emitted `output_emitted.zig` contains
   a Zig `switch` (not a transition table).
2. Range dispatch: one arm `` `a-z` `` binding the matched char, asserting it fires
   for a char in range and falls to `no-match` outside it.
3. Set dispatch: one arm `` `aeiou` `` over several inputs.
4. The day-8 escape scanner rewritten with `std/switch:char` instead of the nested
   `if`-tree, asserting identical output — this is the real-world proof it collapses
   the ugly code.

## Reference files

- Surface grammar to mirror: `tests/regression/600_STDLIB/640_REGEX/640_001_match_basic/input.k`
- Transform implementation to mirror: `koru_std/regex.kz`
- The if-tree being replaced (motivation + a port target): `tests/regression/810_AOC_2015/810_081_day08_part1/input.k`

## What NOT to do

- Do NOT add char-literal branch heads (e.g. an arm head written as a bare `'a'`).
  The head is the backtick opaque string. Char literals as heads are NOT legal
  branch-head grammar and would require parser work — which this spec forbids.
- Do NOT add a range operator to the branch grammar. Ranges live inside the opaque
  string and are parsed by the transform.
- Do NOT escape the backticks. The arm head is three things: a backtick, the opaque
  content, a backtick. There is no backslash anywhere in this syntax.
