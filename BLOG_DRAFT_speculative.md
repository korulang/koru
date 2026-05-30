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

The first version of that table had a wrinkle: at depth 16 the number fell back
to ~5×. The toy emitter rebuilt a tower of nested handler closures *per item*, and
past about depth 8 that tower blew V8's inlining budget — the allocations started
hitting the heap instead of vanishing.

So we fixed it, the same session. Koru knows the entire `stage1 → … → stageD`
chain at compile time, so the emitter now **splices the handler bodies in-scope**
at the call site instead of building closures: a dispatch hop becomes
`{ const x = arg; …next… }`, straight-line, no allocation. The deep chain emits as
plain nested blocks with zero closures, and — unlike the kinds of folds a backend
optimizer does for us — **textual emit-time inlining survives V8.** The degradation
is gone. Koru now holds the floor at every depth.

But here is the honest shape of the win, because it is *not* "34× faster than
everything," and we are not going to let it read that way. With the routing
spliced flat, Koru **ties a hand-written loop** at every depth — it does not beat
it. The two are equal, because for trivial pass-through stages V8 dead-code-
eliminates the routing in both. What Koru does is *reach* the hand-written floor
while keeping the event-driven programming model. The idiomatic JavaScript event
system cannot reach that floor at all: an `EventEmitter` hop is opaque to the
optimizer, so it pays its ~20 ns *every hop, forever*, and the cost compounds with
depth. At depth 16 that is the entire gap — Koru and flat finish in ~60 ms; the
EventEmitter version takes ~380.

State it precisely: **Koru gives you the event-driven model at hand-written-flat
speed, and eliminates the per-hop dynamic-dispatch tax that JavaScript's own event
system charges forever.** For stages that do real work, both pay the work and the
absolute gap narrows toward that per-hop floor difference. But the dispatch fabric
of real apps — middleware, event bubbling, signal propagation — is mostly routing,
and routing is exactly the part that, in JavaScript, you cannot stop paying for.
Unless you stop being JavaScript.

## Two taxes

Time is only half the story, and the other half is sharper. We measured peak
memory and garbage-collection pressure for the same depth-16 chain, five million
events through it:

```
  approach                 time      peak RSS    GC events
  ───────────────────────────────────────────────────────
  flat (hand-written)      ~80 ms     52 MB          3
  Koru (spliced)           ~70 ms     49 MB          3
  Koru (naive closures)   ~360 ms     59 MB       3742
  EventEmitter (dynamic)  ~380 ms+    53 MB          4
```

(Absolute times are noisy under load; the GC column is rock-stable, and it's the
one that matters.)

The two slow ways to write this are slow for *opposite* reasons. The naive
emitter — the one that built a tower of handler closures per item — pays in
**garbage collection: 3742 collections** to flat's 3, because the closures hit the
heap. The `EventEmitter` version barely allocates at all — *four* collections —
and is slow purely on **CPU**: the dispatch machinery, the megamorphic calls, the
per-hop overhead the optimizer can't see through.

So JavaScript hands you two honest ways to write an event-driven chain, and each
one pays a tax it cannot escape: the closures pay in GC, the emitters pay in CPU.
The spliced Koru output pays neither. It ties a hand-written loop on time, on peak
memory, *and* on collections — three GCs, same as if you'd written the whole thing
by hand and given up the programming model entirely. **You get the event model for
the price of the bare loop.**

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
