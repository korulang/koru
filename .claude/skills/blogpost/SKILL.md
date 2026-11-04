---
name: blogpost
description: Draft a short korulang.org blog post announcing a newly-landed Koru feature, grounded in its regression tests and using the site's bespoke RegressionTestLink component. Use when Lars says "write a blog post", "pen a blog post", "blog this feature", or asks to describe recent work as a post for korulang_org. Produces a DRAFT for Lars to read — never publishes.
---

# Write a korulang.org blog post

Lars asks for these because writing the post is how he reads a just-landed
feature for the first time — through your prose. So the post is a draft he
reviews, not a thing you ship. **The terminal step is always: hand it to Lars.
Never push, never run the ceremony, never announce.**

Repo: `/Users/larsde/src/korulang_org` (adjacent to koru). Posts live at
`src/routes/blog/<kebab-slug>/+page.svx`.

## The one hard rule

**Write it as `draft: true` and stop.** Draft posts are kept out of the public
`/blog` index and out of every announcement; Lars reads them at the gated
`/blog/drafts` route. When he's happy he flips `draft: false` himself and the
next ceremony publishes it. You do not push, and you do not flip that flag.

**The flip is not the publish.** `draft: false` + `bun run blog:index` moves
the post into the published list in the site's SOURCE only. Nothing reaches
korulang.org until the reactor deploy runs (`pnpm deploy:prod` — the
ceremony's step 4.5, or standalone for a post-only publish). `git push` does
NOT deploy (the site's Git integration is disconnected; see
`korulang_org/DEPLOYMENT.md`). A flipped-and-committed post that was never
deployed is invisible on the live site — never report it as published.

## The title — say what the post is about, not a riddle

The title is the one line most readers ever see (the `/blog` index, social cards,
the browser tab). It must let a reader **know what the post covers from the title
alone.** Lead with the concrete subject — the feature or concept, by name.

- **Every past title has failed this, and it is the house's worst habit:**
  *"Doodle the Flow, Let the Events Catch Up"*, *"Open a Vocabulary, Shadow
  Nothing"*, *"A Grammar Is Two Glyphs"* — all evocative, none tell you the post is
  about **prototyping**, the **`[with]` vocabulary** feature, or **grammar**. Copy
  the past posts' prose *voice* (step 2) — never their *titles*.
- **The test:** could someone scanning `/blog` tell this post is about *<the
  feature>* from the title alone? If not, rewrite it.
- **There is no hook slot.** The title is a description of the contents and
  nothing else — `Orisha vs Actix and ASP.NET on SQLite`, not `Orisha: The
  Cold Path Is the Library`. A colon is allowed when what follows is still a
  plain description (`std/channel: Where Blocking Is a Branch`); an evocative
  riddle after the colon is not. `Introducing`/`Meet`/`Announcing`/
  `Presenting` are sanctioned lead-ins — "Introducing Koru Stack" names the
  subject at the front of the title and passes the gate (widened
  2026-10-05, when "Stack: Orchestration Is a Compile-Time Obligation" —
  compliant, subject-first, and completely obtuse — proved "descriptive"
  alone wasn't enough; the title must tell the reader WHAT the thing is,
  and an announcement does that better than a thesis). Wit lives in the
  `excerpt`, never the title.
- **Declare the subject in frontmatter; the commit gate enforces the rule
  against it.** `subject: "Orisha"` is required whenever a title or subject
  is written (new post, retitle, field change); `check:publication` refuses
  a title that does not open with the subject's name. `LARS_HAS_READ_IT`
  never forgives this one. A body-only edit to a subject-less legacy post
  passes untaxed; add the field when you touch the title. (Wall landed
  2026-09-18 after "The Judge Is a Phantom Type" was committed as a draft —
  a verdict that named no subject, the exact shape the ruling exists to
  kill.)
- **The slug is the subject's name — NOT the title kebab-cased.** The
  directory name is the post's permanent address and should be the shortest
  handle a reader would use for the thing itself: `stack`, `std-gate`,
  `orisha-vs-actix-and-aspnet-on-sqlite`. Deriving the slug from the title's
  own words is how you get `stack-orchestration-as-obligation` — a thesis
  statement wearing an address, obtuse by construction (Lars-ruled
  2026-10-05, after four consecutive thesis-slugs; the prior "title
  kebab-cased" rule was written to kill private-metaphor slugs like
  `the-cold-path-is-the-library` and overcorrected). Add a disambiguator
  only when the bare name collides (`stack-up` for a second stack post).
  `check:publication` refuses a slug whose tokens do not appear in the
  title or that does not name its subject — so the title still must name
  the thing — but the slug stops at the name.
- **Prefer plain-and-clear over clever-and-vague, every time.** "Prototype Mode:
  Running Incomplete Programs" beats "Doodle the Flow." When in doubt, name the
  feature and stop.

## Steps

1. **Ground the feature in real passing tests.** This is a post about the
   *language*, so its claims are backed by green regression tests. Find them in
   koru — `./run_regression.sh <cluster>` — and quote the real test directories.
   Never invent test ids or paths; if you name a test, you ran/read it this turn.

   **DIFF every code sample against the test it came from, before shipping.**
   Reading the test is not enough — a sample lifted with `head -N`, `sed -n`, or
   a grep that drops comment lines is a *truncated* citation, which is a
   fabrication wearing a footnote: it names a real green test and puts broken
   code on a public page. Run the check, don't eyeball it:

   ```bash
   diff <(sed -n '/^tor check/,/^| small s -> s/p' <post>.svx) \
        <(sed -n '/^tor check/,/^| small s -> s/p' <test>/input.k)
   ```

   (Earned 2026-07-24: the tor post shipped `classify = check(n) | big b -> …`
   with the `| small` arm sliced off by `head -10`. Non-exhaustive, wouldn't
   compile, and it contradicted the post's own claim two sections later that you
   cannot forget an outcome. Lars caught it on the live page.)

   **Samples are pure Koru — the tilde does not exist in a post.** The `~` is
   the host→Koru switch and has meaning only inside host-embedded (`.kz`)
   files; a post is a pure-Koru context, where the marker is rejected outright
   (PARSE003 — `frag-tilde-marks-the-host-boundary`). Write every sample in the
   pure surface — `pub tor`, `import`, `name -> { … }` impls, bare calls — even
   when the test you cite lives in a `.kz` (host) file. Prefer citing a pure
   `.k` test so sample and test are the same bytes with no normalization. Host
   residue (`proc x|zig { … }`) is the old spelling; rewrite it to a pure impl.
   The blog pipeline now FAILS on a tilde in code position (`bun run blog:index`
   runs the wall), so this rule is enforced, not aspirational.

   **A `|` inside a code span is `&#124;`, never `\|`.** GFM unescapes the
   pipe only outside code spans; inside backticks the backslash renders
   literally — `` `\|>` `` shows readers "\|>". Koru's branch glyph is `|`,
   so branch sets in tables hit this constantly. The commit gate refuses the
   broken spelling in ANY code span (`check:publication`, since 2026-09-18 —
   the convention had already drifted into seven posts before anything said
   no; widened past table cells the same day).

2. **Read the two or three most recent posts** in
   `src/routes/blog/*/+page.svx` (sort by `date` in frontmatter) before writing.
   They set the house voice and show the current component usage. The most
   recent feature post is the model to copy.

3. **Write `+page.svx`** with this frontmatter shape (strings, hand-parsed — not
   YAML):

   ```
   ---
   title: "Title Case, No Trailing Period"
   subject: "The Subject the Title Leads With"
   date: 2026-07-12
   excerpt: "One or two sentences that state what the feature IS. This is what shows in the index and social cards."
   readTime: 6 min read
   tags: [language design, koru, ...]
   ai_authored: mostly
   draft: true
   ---
   ```

   Then the body in Markdown/mdsvex. `koru` fenced code blocks highlight
   correctly (mapped to Zig).

4. **Link the tests with the bespoke component.** In a `<script>` block at the
   top of the body:

   ```svelte
   <script>
     import RegressionTestLink from '$lib/components/RegressionTestLink.svelte';
   </script>
   ```

   Then inline, where the prose makes a claim a test proves:

   ```svelte
   <RegressionTestLink
     tests={[
       { name: "641_001 the recursive flagship", directory: "641_001_parse_recursive_flagship", categorySlug: "600_STDLIB/641_PARSER", description: "One sentence on what this test pins." }
     ]}
   />
   ```

   `directory` = the exact test dir name; `categorySlug` = its category path
   (e.g. `600_STDLIB/641_PARSER`). The component keys into `status.json` as
   `${categorySlug}/${directory}` and renders the live pass/fail, so both must
   match a real test. A single test can use `test={{ ... }}` instead of
   `tests={[ ... ]}`.

5. **Regenerate the index:** from `korulang_org`, run `bun run blog:index`. This
   rewrites both `posts.generated.ts` (public) and `posts.drafts.generated.ts`
   (the gated drafts list) in one pass. Cheap — no full build.

6. **Stop and hand it to Lars.** Tell him it's at `/blog/drafts` (gated by the
   same login as present/share — `bun run dev` locally to read). Do not push, do
   not build:local, do not ceremony. He reads; the flip is his call.

7. **After the flip: say what IS and ISN'T live.** If Lars directed the flip,
   the handoff must name the post's state exactly — "committed, **not
   deployed**; live after `deploy:prod`" — never "published." Deployment is a
   separate act:
   - If Lars asked to get it live now: `cd ~/src/korulang_org && pnpm
     deploy:prod /blog/<slug>` (the slug doubles as a freshness probe; the
     script self-verifies the `x-orisha: reactor` header and the path's 200).
   - Otherwise: the next ceremony's step 4.5 publishes it. The test badges on
     the post's RegressionTestLinks stay blank until that same ceremony
     refreshes `status.json` with the new test rows.

   **Video:** when a post's story wants a film, production lives in
   `~/src/fframes-hello` (scene-pitch + Rust renderer, its own AGENTS.md) —
   storyboard via the `catalog-storyboard` skill. Commission after the
   verdict, not before: an honest-arc post whose ending is still unmeasured
   (a benchmark number, a merge) waits for it.

## Voice

- **Title opens with the subject by name and describes the post — no hooks.**
  A reader scanning the index must see WHAT the post is about from the title
  alone — "Orisha vs Actix and ASP.NET on SQLite", not "Doodle the Flow, Let
  the Events Catch Up". The slug is the subject's name, not the title
  kebab-cased. (Lars-ruled 2026-07-15 after a title that never named its
  feature; tightened 2026-10-03 — the hook half of the old form stayed
  cryptic; slug rule re-ruled 2026-10-05 — title-derived slugs produce
  thesis-statement addresses.)
- **Present tense, describe the feature — not the journey.** "A grammar is two
  glyphs" not "Today I added a parser." No changelog narration, no "we then…" —
  and no *design* journey either. The seductive form is the ruled-out road:
  "what I built first", "the road that got ruled out", objection arcs where
  each wrong version gets a section. The rejected shapes are not content the
  reader needs — justify the contract inside the design sections; the
  graveyard lives in commit messages and `concepts/`, not on the page.
  (Lars-ruled 2026-09-27: pump-verdicts shipped a three-subsection ruled-out
  appendix "because the journey is half of what these posts are for" — it
  isn't. None of them care about our journey; they care about the result.)
- **Short and synthesized.** State the idea and let the tests carry the proof.
- **Never print two numbers side by side when their gap is inside run-to-run
  jitter.** `99.9% vs 99.7%` reads as an ordering no matter how many caveats
  follow it — readers will assume the bigger number is the better implementation
  even when the difference is demonstrably noise. Either prove the gap survives
  variance (repeat the run, report the spread) or collapse the numbers to the
  claim the data supports ("both answered essentially everything") and put the
  real difference in the sentence instead — acceptance policy, architecture,
  the thing that isn't jitter. (Lars-ruled 2026-10-26: counterproductive
  precision is still precision-theater.)
- Match the register of the recent posts; don't invent a new house style.
- **Numbers worth seeing are a HyperFrame.** `~/.claude/skills/hyperframe/SKILL.md`
  — the site surface (`src/lib/hyperframes/`), not the War Room. A chart is a
  second copy of a table and must be gated. Leave `draft: true`.

## Never

- Never `git push`, `bun run build:local`, or run the status ceremony from this
  skill while the post is a draft. The flip is Lars's call, and the deploy is a
  separate act after it: `pnpm deploy:prod` is the only thing that puts the post
  on the live site, and a flipped-but-undeployed post is not published.
- Never write `draft: false` on your own authority. That flag is Lars's to
  flip — when he directs the flip, the husky gate's `LARS_HAS_READ_IT=1` is his
  explicit say-so, not a workaround.
- Never keep a "road that got ruled out" / "what I built first" / "how it
  went wrong" section because it explains why the design has its shape —
  that justification belongs inside the sections describing the result.
  The reader needs the destination, not the detour.
- Never cite a test you haven't read/run this session, and never invent a
  `directory`/`categorySlug` — a wrong one renders a dead link on the live site.
  Verify each pair resolves in `src/lib/data/status.json` under the key
  `${categorySlug}/${directory}` before publishing.
- Never ship a code sample you haven't **diffed** against its source test.
  "I read the test" is not the bar — reading ten lines of a twenty-six-line file
  satisfies it and still publishes broken code. The diff is the bar.
