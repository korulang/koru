---
title: "WebAssembly Solved the Wrong Problem"
date: 2026-05-30
draft: true
speculative: true
ai_authored: true
status: "SPIKE — one session of work. Numbers are preliminary, measured on real emitter output but not hardened. Do not ship as fact."
excerpt: "Every attempt to make JavaScript fast accepts that JavaScript is JavaScript. What happens when you don't — when you treat it as a backend, the way Koru treats Zig, and resolve the dispatch at compile time? An afternoon's spike, and the first real numbers."
tags: [koru, javascript, wasm, dispatch, speculative, spike]
---

> **This is a draft and a speculation.** Everything below comes from a single
> session of building. The numbers are real — measured on JavaScript that the
> Koru compiler actually emitted, not hand-written mockups — but they are
> preliminary, taken with coarse whole-process timing, and they describe a toy
> emitter, not a product. Read it as a hypothesis with early evidence, not a
> claim.

WebAssembly is fast. It is also, for the thing most web apps actually spend
their time on, beside the point.

WASM has no direct access to the DOM. Every DOM read, every DOM write, every
event, crosses the JavaScript⇄WASM boundary through glue code, and anything that
isn't a number gets marshalled across it. So for the workload that *is* most web
apps — an event fires, a reducer runs, state reconciles, the DOM mutates — WASM
puts the compute on the far side of a toll booth from the thing the compute
exists to manipulate. The bottleneck and the speedup end up on opposite sides of
a wall.

WASM earns its keep in a real niche: Figma's renderer, Photoshop on the web,
ffmpeg in the browser, in-browser ML. DOM-light, compute-heavy, boundary crossed
rarely. For that, it's the right tool. But it optimized the ten percent and
toll-boothed the ninety. **The web isn't slow because of compute. It's slow
because of dispatch — and all the dispatch lives on the JavaScript side of a
boundary WASM can't cross cheaply.**

## The premise nobody questions

Here is the thing every JavaScript performance project has in common, and it is
so deep in the water that it never gets said out loud: **they all accept that
JavaScript is JavaScript.**

They make the framework thinner. They kill the virtual DOM. They shrink the
runtime, sharpen the diff, compile the components. And they do all of it *inside*
JavaScript's execution model — a model where dispatch is resolved at runtime,
dependency graphs are discovered at runtime, composition is dynamic, and the
whole program is unknowable until it runs. They get as close to the ceiling as
the model allows, and the model is treated as a law of physics.

Svelte is the strongest version of this, which is exactly why it's the honest
one to name. It compiles the framework away. Its reactivity is genuinely
excellent. And it *still* can't get past the wall, because the signal graph is
**runtime auto-tracked**: you write a derivation and its dependencies are
discovered by *running* the code and watching which signals get read. When a
signal changes, a subscriber list gets walked and effects fire — dynamic
dispatch, discovered dynamically, fired dynamically. Svelte compiled away the
virtual DOM. It did not, and within the model could not, compile away the late
binding. It went as far as you can go while still being JavaScript, and then the
physics stopped it.

So the question almost nobody asks: what if you don't accept the premise? What
if you stop being JavaScript, and use it as a backend?

## Stop being JavaScript

This is what Koru is, pointed at a new target.

Koru already treats Zig as a backend — a language it emits, not a language it
lives inside. The proposal is to do the same to JavaScript: emit it, the way Elm
does, as a self-contained ecosystem that compiles *to* JS rather than slotting
*into* it. JavaScript becomes the paper you print on. The module system, npm —
those become an FFI escape hatch at the edges, the role C libraries play today,
never dynamic dispatch in a hot path.

And the one move that makes it worth doing: **the event model becomes static.**
In Koru the handler graph is declared, not discovered. The compiler knows, before
a line runs, which handler an event dispatches to. So it lowers to a direct call —
no subscriber list, no auto-tracking, no runtime notify. The late binding that
caps Svelte simply isn't there to cap.

That's the bet. Here's the first evidence.

## The floor nobody can lift

We built a toy Koru→JavaScript emitter in an afternoon and pointed it at the
shape that is the whole argument: a chain of events dispatching to other events,
at depth — the cascade that React's events→reducers→effects, Node's
EventEmitters, and every middleware stack are made of.

The same pipeline, three ways. Koru-emitted static dispatch. The idiomatic
JavaScript version — real Node `EventEmitter`s, one dispatch per hop, written the
way you'd actually write it. And a flat hand-rolled loop with no dispatch at all,
as a floor. Identical results, checked. We swept the dispatch depth and measured
nanoseconds per hop.

```
   depth │ koru-static │ EventEmitter │  flat  │ EventEmitter / koru
  ───────┼─────────────┼──────────────┼────────┼─────────────────────
      1  │   2.4 ns    │   19.1 ns    │ 2.3 ns │       8.0×
      2  │   2.3 ns    │   20.5 ns    │ 1.5 ns │       8.8×
      4  │   2.1 ns    │   19.7 ns    │ 1.0 ns │       9.4×
      8  │   2.0 ns    │   19.5 ns    │ 0.5 ns │       9.5×
     16  │   3.7 ns    │   19.4 ns    │ 0.4 ns │       5.2×
```

Read the EventEmitter column first, because it is the whole point: **flat. ~19
nanoseconds per hop, from depth 1 to depth 16, dead constant.** V8 cannot fuse
across a dynamic dispatch hop — the binding was made at runtime, the optimizer
can't see through it. So every layer of dispatch depth is pure additive tax that
JavaScript will never optimize away. This is not a slow implementation. It is a
floor, and it is structural.

Koru's static dispatch starts ~8× under that floor and *widens* to ~9.5× by depth
8 — the static chain stays cheap while the dynamic one pays full freight at every
hop. That is the thesis, on emitted output, not a slide: **the deeper your app's
dispatch, the wider the structural gap.**

## The honest part

And then, at depth 16, our number falls back to ~5×. We are not going to bury
that.

The cause is real: the toy emitter rebuilds a tower of nested handler closures
*per item*, and past about depth 8 that tower blows V8's inlining and
escape-analysis budget — the allocations start hitting the heap instead of
vanishing. The flat floor keeps getting *cheaper* per hop as V8 fully inlines its
trivial direct calls; our naive output can't be collapsed the same way at depth.

But look at where the ceiling is. It's *ours*, not V8's. Koru knows the entire
`stage1 → … → stageD` chain at compile time. Fusing it textually at emit time —
collapsing the nested handlers into straight-line code, hoisting the closures out
of the hot loop — keeps it on the ~2 ns floor at any depth. And unlike the kinds
of folds a backend optimizer does for us, **textual emit-time inlining survives
V8.** The afternoon's emitter doesn't do it yet. The point is that nothing stops
it.

So the shape of the claim, stated as carefully as it deserves: against the
idiomatic JavaScript event system, on the workload JavaScript is structurally
worst at, Koru-emitted code runs **roughly 5–10× faster today and has headroom we
control** — while sitting within ~1.5× of a hand-rolled loop, never leaving
JavaScript, keeping native DOM access, and paying no WASM toll.

## What this would mean, if it holds

Speculate with me, because that's what this is.

If the dispatch fabric of an application — the part that is most of the code and
most of the time, the events and reducers and signal propagation and
reconciliation — collapses to static calls at compile time, then the thing that
makes large JavaScript apps slow doesn't get optimized. It gets *deleted before
it runs.* Not faster dynamic dispatch. No dynamic dispatch.

That's a different category of answer than "a leaner framework." It's the
category WASM reached for and missed, because it answered with compute when the
question was dispatch, and because it walled itself off from the DOM in the
process. Koru-on-JavaScript would answer dispatch with dispatch, in JavaScript,
with the DOM right there.

The graveyard for "stop being JavaScript" is real and it has Elm's name on it —
people will not give up npm for purity. So the honest question was never *can you*
get past the ceiling; the afternoon says you can. The question is *where the
wedge is* — which corner of the world values 5–10× on its dispatch and
compile-time resource safety more than it values staying in the ecosystem. That's
not answered here. Nothing here is answered. It's one session, a toy emitter, and
a floor we found that JavaScript can't lift.

But we found the floor. And the floor is exactly where the thesis said it would
be.
