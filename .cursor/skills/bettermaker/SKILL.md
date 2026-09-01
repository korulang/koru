---
name: bettermaker
description: >-
  Close the last mile on ONE thing and prove it from where it is actually used.
  Replayable pass: one real user path, one increment — fix the obvious defect,
  envision better, or close a frame-shelf mile. Oracle-gated, never invent damage.
  Use for /bettermaker, "make this better", "another pass", or "close the last mile".
disable-model-invocation: true
---

# bettermaker

Most things here are 90% built and silently broken at the last mile. The gap is
almost never capability — it is that nobody ever ran the thing **from where it is
used**. One pass closes one last mile. Replay forever; there is always another.

**A pass never dead-ends.** The register runs diffuse nudge first: if the obvious
defect is there, close it. If it isn't, stand in the ideal user's seat and
**envision** what better looks like — not seeing it is a fact about your looking,
not about the thing, and "nothing to do here" is almost always a day that searched
for damage and found none. Damage is the easy half. The other half is the distance
between *working* and *good*, and that half is invisible until someone says out
loud what good would feel like. So when the obvious defect isn't there, do not stop
and do not go hunting for a smaller defect: name what better would feel like, and
close one increment toward it. And if even envisioning yields nothing concrete —
no mile in sight, no "better" that lands — go to the frame shelf and close one
pre-written mile there. This is what makes the pass replayable:
the supply of lies runs out, the supply of envisioned better does not — and the
recipe shelf is never empty. And because every register runs on a **confidence
gate** — an oracle, not a feel — a run can ship unattended, close a mile or pass a
benchmark, and feed the flywheel. Only when no oracle exists does it stop for the
human's taste-gate.

## The loop

1. **Ask what good it is — from the inputs, not from you.** Four sources, no one of
   them the verdict:
   - **The ideal scene** — `SCENE.md` at the repo root. Slow and sticky: north
     star, ideal user, beds, refusals. **One input, never the answer.** It says what
     the garden *wants to become*, not what this pass should do.
   - **The in-flight layer** — `prose`. Current smoke: `snap`/`whisper` in this cwd
     and the project family, `prose grep` for a complaint a human dropped (last
     miles with a witness), the latest `baton` ("you are here"). The scene is cold;
     prose is live.
   - **The repo read fresh** — the code, README, tests, as they are now, never from
     memory.
   - **The forward nudge** — a loose, diffuse read of the standing generators, to
      see if one names an *obvious* mile. Run the challenge registry and glance at
      each brief's `yields`. For a repo whose fleet is under `~/src`, it lives at
      `6digit-skills/scripts/challenges.mjs` — it walks every repo and prints the
      menu; a repo keeps its own `challenges/` dir of briefs on top of that. If the
      registry is absent, scan the repo's `challenges/` for briefs instead. This is
      the one input that answers *what should we do next*, not *what's wrong*.
      The one-shot form of this is `6digit-skills/scripts/flywheel.sh`: run
      `6digit-skills/scripts/flywheel.sh --repo "$PWD"` from the repository being
      improved. It holds the registry oracle (`verify`, regenerating a merely-stale
      `CHALLENGES.md`) and prints only that repository's frame shelf — the genuine
      last-miles. Omit `--repo` only when you deliberately want the fleet-wide
      morning menu. An unknown repository refuses; it never widens silently to the
      fleet. **Exit 1 means the scoped shelf is empty and the honest move is to
      halt, not to invent a mile**; exit 2 means the registry cannot be trusted.
      Invoke it once, pick one frame off the shelf, close it, prove it, stop — the
      loop is a discrete pass, not a coroutine.
      Boundary: a `frame` brief naming a **last mile** (a defect to pin, a fix to
      prove from where it's used) reads as an obvious thing to just do — those are
      bettermaker increments in disguise; a `generator` brief naming a **catalog**
      (variance is the product) is the broad register — note it and only run it on
      a **confidence gate**, never folding a divergent full commission into one
      convergent increment.

   Name the bed you are standing in. Test the candidate **scene-relative, never
   codebase-relative**: *does closing this pull toward the ideal scene?* "Is it
   broken?" says yes to almost anything, exactly the way "does it fit the codebase?"
   does — an honest path that fights the scene is a **deletion**, not a pass. Then
   pick ONE path **the scene's ideal user** traverses. Not a subsystem, not a
   component — a path: *Lars opens the room and types to a seat*, *an agent runs the
   CLI and reads the output*.

   **If the scene names no ideal user — or there is no scene at all — envision one,
   and mark it a seed.** First run the worth test on whatever the garden does hold:
   a north star, a bed, a no-list will each tell you plainly whether a candidate
   pulls or fights, and a garden missing only the person is nearly whole. Then write
   the missing line yourself — one or two sentences, in the human's own words
   wherever you have them — and carry on with the pass.

   The guard that makes this safe is **seed, not settlement**. Doctrine bans
   *author-and-present*: an agent synthesising a whole felt vision and collecting a
   nod produces something the human ratified but never committed to, which is a
   corrupted instrument for every reader after. It does not ban planting. So keep
   what you envision small on purpose, write it into the scene file as an explicitly
   unratified seed naming the pass that planted it, and say the same thing in your
   report. A thin honest seed is a working scene; a seed padded out to look finished
   is the thing doctrine actually forbids. Never let an envisioned user be described
   as one the human chose.

   **If nothing concrete comes up — no obvious last mile, no silent step, no
   "better" that names a mile — do not invent damage, do not manufacture a vision.
   Go to the frame shelf.** This is not giving up; it is the front door to the
   recipe-rich register. Run the challenge registry and read the `frame` briefs —
   those are bettermaker-shaped increments someone already wrote down: one pinned
   defect, one falsifiable doc claim, one uncovered feature combination. Pick the
   one whose yield is the last mile you couldn't find, and close it as your own
   pass: same provenance, same proof from the point of use. That is the honest rest
   of the diffuse register. A generator — divergent, catalog-shaped — is the broad
   register and asks a different question, so **run it only on a confidence gate**:
   if its yield is oracle-checkable, gate on a mechanical closer and ship; if its
   yield is truly aesthetic and the human's taste is irreducible, hold. Either way,
   say in the report which register you fell into, what gate you met, and whether
   the run shipped unattended or stopped for the human.
2. **Stand where they stand.** Use the same door they use. The browser page, not the
   endpoint under it. The published command, not the function it calls. **The layer
   beneath is not the point of use, and a green there proves nothing about the path.**
3. **Find the lie, the silence — or the gap.** Three shapes:
   - **It lies** — claims something untrue about itself (says delivered, wasn't;
     says healthy, isn't; says done, didn't).
   - **It goes quiet** — works, but shows nothing while working, so working and dead
     look identical to whoever is waiting.
   - **It is merely adequate** — nothing is broken, nothing is mute; it simply is
     not yet what the scene wants. This shape does not announce itself. The first
     two you *find*; this one you have to **envision** before you can see it at all.
     Stand in the ideal user's seat, say in one plain sentence what better would
     feel like from there, and take the smallest step toward it.

   Once the obvious damage is gone, the third shape is the only one left — which is
   exactly when a pass is most tempted to either quit or redesign. Neither. Envision
   as large as you like; **close as small as you can.** The one-increment law binds
   hardest here, because a vision you just wrote is the most persuasive possible
   argument for rebuilding something that already works.
4. **Close ONE increment.** The smallest change that makes the path honest — or,
   for the third shape, the smallest change that moves it toward what you
   envisioned. Not a redesign. A pass that redesigns has stopped being replayable.
5. **Prove it from the same seat.** Re-run the path from step 2 — not the layer you
   edited. Print what you ran and what came back.
6. **Leave the proof.** Commit it, with the command and its actual output in the
   message. A claim with no run behind it is worth nothing.

## The four laws

**Verify at the point of use.** A green one layer down is not a green. The corpus
already ruled it: *the copy that RUNS is not the copy that looks canonical.* If the
path failed in the room, curling the service is not a test — it is a different test
that happens to pass.

**Silence is a defect.** If a step takes longer than the user will sit staring at
nothing, it must say it is working before it is done. An immediate honest "heard
you — this takes about ninety seconds" is not decoration; it is the difference
between slow and broken, and only one of those gets switched off.

**Report the door you actually opened.** If you verified a different path than the
one that failed, say so in the same breath. "It works" and "it works when I call it
this other way" are different sentences and only one of them is usually true.

**One increment, then stop.** Finish the pass. Do not chain into the next finding —
write it down and replay.

## Confidence gates — running unattended

Bettermaker can run on a cron. What decides whether a run may ship without the
human is not a feel, it is a **gate**: a proof that the human wouldn't have found
anything to object to. Three registers, three honest answers:

1. **Convergent task** (a frame's one pinned defect) — the done-gate is objective
   and already enough: it builds, the defect is pinned, the diff is a mile. No
   taste remains. **Ship unattended.**
2. **Divergent but oracle-checkable** (a proof, a benchmark, a conformance) — the
   "taste" reduces to a mechanical closer: a diff, a suite delta, a reference
   match. **Ship unattended** *because* the oracle decides, not you. This is the
   `arbiters-gauntlet` leash in the challenge register — the gauntlet already runs
   blindly and exits on beating the bar, and a manual-cron bettermaker is the same
   rule applied to the recipe shelf.
3. **Truly-divergent aesthetic** (a beautiful synth, an evocative instrument) —
   no honest gate exists. The human's taste is irreducible. **Hold for the human.**
   No confidence-gate substitutes for it.

The one line that keeps all three honest: **a gate is an oracle outside the thing
being judged — never your own assessment.** "I'm confident this is good" is not a
gate; it is self-certification, and it is the "never manufacture a green" failure
wearing bettermaker's clothes. This is why the gauntlet demands a mechanical
closer and not the contestant's report, and it is why a cron-bettermaker may be
autonomous only as far as an oracle lets it. Beyond that — stop, hold, and say so.

The flywheel is the point: a cron run that closes a frame or passes an oracle
register feeds back as proof; a run that can't gate honestly stops rather than
fabricating a green — and the shelf stays full, so the wheel never starves.

## Tells that you are failing this skill

Each of these has actually happened; treat any of them as a stop:

- *"It works — I tested X"* where X is not the thing that failed.
- Proving a fix with the same tool that carried the bug. A recovery tool once
  inherited the exact defect it existed to repair and reported "nothing was lost."
- Diagnosing from a glance at output you did not read carefully, then editing a
  shared file on the strength of it.
- Saying what you committed without looking at what was staged.
- Declaring done while the user is still looking at a blank screen.
- Reporting something you envisioned alone as though the human had settled it —
  or planting a scene seed and not saying, in the file and in the report, that a
  pass planted it.
- Envisioning something large and then spending the pass on the redesign it
  implies. The vision is allowed to be big; the increment is not.
- Ending a pass with "nothing to improve here" and quitting. "Nothing concrete"
  is a real finding only if it lands in the next register: a frame-shelf mile, a
  gate-shipped generator, or a deliberate hold for the human's taste-gate. Saying
  it and stopping without one of those is the third shape going unseen, not an
  absence of work. And a "confidence gate" that is your own self-assessment,
  not an oracle, is the same failure — self-certification, not a gate.

## Honest outcomes

- **Closed** — the path is honest now, proven from the point of use.
- **Envisioned** — nothing lied and nothing went quiet, so you said what better
  looks like from the ideal user's seat and closed one increment toward it. Prove
  it from the same seat like any other pass, and separate the two halves in your
  report: which part the inputs already held (the scene, prose, the repo), and
  which part you envisioned. A reader must never have to guess which sentences
  came from the garden and which came from you.
- **Located** — the last mile is somewhere you must not touch (someone else's
  service, a live system, a decision above you). Name it exactly, with evidence,
  and stop. A precisely located gap beats a speculative fix.
- **Deeper** — the honest fix is structural, not incremental. Say so plainly, do the
  increment that is genuinely safe, and do not smuggle a redesign in behind it.
- **Closed from the frame shelf** — you hunted and found nothing concrete to
  close: no obvious defect, no silent step, no "better" that names a mile. So you
  pulled a `frame` brief off the shelf — a pre-written bettermaker increment — and
  closed its last mile as your own pass. Name the frame, and say so plainly. Same
  provenance, same point-of-use proof; it is a pass, not a hand-off.
- **Shipped on a gate** — you ran a divergent generator through a confidence gate,
  and an oracle (a diff, a suite delta, a reference match) cleared it. Name the
  oracle: it decided, not you. Unattended and honest.
- **Held for the human** — the yield was irreducibly aesthetic and no oracle
  exists, so you stopped rather than fabricate a green. Name the taste-gate the
  human still owes. A deliberate hold beats a manufactured green, and it is the one
  place a cron run is not allowed to decide.

Never manufacture a green. A pass that reports success it did not verify is worse
than no pass, because it certifies.

## Koru registers (repo-specific playbooks)

When the bed is **koru** and the path is compiler/stdlib observation (profiler,
taps, `--profile`, store transforms), read **`.claude/skills/bettermaker/koru-toolchain-join.md`**
and run the mechanical oracle:

```bash
./scripts/bettermaker_profiler_oracle.sh           # 8-test control set
./scripts/bettermaker_profiler_oracle.sh --scale   # + 10×10 loop trace probe
```

Frame shelf entry: `challenges/020_profiler_toolchain_join.md`.

## Replaying

Each pass is independent. Re-read this file, pick a different path, and go. Prefer
paths a human touched recently and complained about — those are last miles with a
witness. Prefer seams between two components, where each side trusts the other's
claim and neither owner sees it.

Replaying is what the third shape is for. The first few passes over anything find
lies and silences, because those were always there. Then they stop turning up, and
that is the point where a pass either quits or starts inventing damage to justify
itself. Neither is the job. When the defects run out, the pass changes register: it
stops asking *what is wrong here* and starts asking *what would make this good*.
That question never runs out, which is why you can replay forever.
