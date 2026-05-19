# Diagnostic Gaps — Parser & Frontend

**Surfaced while fixing 220_022_combined_continuation_bugs.** Three places where the user gets a worse error than they should — two are missing Koru diagnostics that fall through to raw Zig errors against machine-generated code; one is an existing diagnostic whose hint is incomplete.

---

## 1. Field access on branch binding falls through to Zig

**Today**

```koru
~event ready { resource: *Resource[active!] }
...
| ready r |> work_done(r: r.resource)   // r is *Resource, no .resource field
```

User sees:

```
output_emitted.zig:113:82: error: no field named 'resource' in struct
  'output_emitted.main_module.Resource'
            const each0_result_1 = main_module.work_done_event.handler(.{ .r = r.resource });
                                                                                 ^~~~~~~~
```

The error points at the machine-emitted `output_emitted.zig`, not the user's `.kz` source. There's no Koru error code.

**Should be**

A KORU0xx error against the `.kz` source pointing at `r.resource`, e.g.:

```
error[KORU0xx]: no field 'resource' on '*Resource'
  --> input.kz:85:30
     |
  85 |    work_done(r: r.resource)
     |                 ^^^^^^^^^^
     hint: branch bindings carry the branch's payload type directly.
           `r` here is `*Resource`; available fields are `id`, `data`.
```

**Where the work lives:** unknown — needs investigation of the type-check pass on branch-binding field expressions.

---

## 2. `| done |>` after a void event falls through to Zig

**Today**

```koru
~event work_void { r: *Resource }   // void event, no branches
~proc work_void { ... }
...
work_void(r) | done |> next_step(r)   // wrong — work_void has no branches
```

User sees:

```
output_emitted.zig:115:55: error: type 'void' does not support field access
            const each0_result_1_done = each0_result_1.done;
                                        ~~~~~~~~~~~~~~^~~~~
```

Again no Koru diagnostic; the user has to know that the emitter generates a `.done` access on the void return.

**Should be**

A KORU0xx error against the `.kz` source pointing at the `| done` after the void call, e.g.:

```
error[KORU0xx]: branch handler on void event
  --> input.kz:85:23
     |
  85 |    work_void(r) | done |> next_step(r)
     |                 ^^^^^^^
     hint: 'work_void' is a void event (no branches declared).
           Chain void events with bare '|>': `work_void(r) |> next_step(r)`.
```

**Where the work lives:** unknown — needs investigation of where continuation-branch validation happens vs. the void-chaining emitter path.

---

## 3. KORU010 hint is incomplete

**Today**

```
error[KORU010]: '|>' cannot start a line
  hint: '|>' is inline glue only — it joins a body to its branch handler,
  or chains void events on one line. Three legal layouts:
    (1) fold inline `~A() |> B()`;
    (2) split into separate top-level statements `~A()` then `~B()`;
    (3) delete the redundant `|> _` if the head suffices.
```

The hint covers simple proc calls but doesn't mention two patterns that exist in passing tests:

- **Void chains:** `a() |> b() |> c()` on one line (220_021).
- **Block-body chains:** `} |> std.kernel:self { ... }` — `|>` glued to a closing brace, chaining two block-bodied calls (390_090, after fix).

**Should be**

Hint extended with these two layouts so users hitting KORU010 from either pattern get a complete picture.

**Where the work lives:** the KORU010 hint string itself. Small.

---

## Priority order (cheapest first)

1. **Patch KORU010 hint** — string change, biggest payoff per line. Anyone hitting `|>` rules today gets misled.
2. **Add KORU0xx for `| branch |>` on void event** — every user trying to chain void events the wrong way hits this.
3. **Add KORU0xx for invalid field access on branch binding** — broader scope (needs the type-checker to know branch-binding payload types).
