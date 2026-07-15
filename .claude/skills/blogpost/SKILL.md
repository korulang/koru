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
- A clever hook is allowed **only** when the subject still leads. Put the feature
  name first and let the hook ride behind it — `Prototype Mode: <hook>` — or park
  the color in the `excerpt`, never the title. The subject drives; wit is a
  passenger.
- **Prefer plain-and-clear over clever-and-vague, every time.** "Prototype Mode:
  Running Incomplete Programs" beats "Doodle the Flow." When in doubt, name the
  feature and stop.

## Steps

1. **Ground the feature in real passing tests.** This is a post about the
   *language*, so its claims are backed by green regression tests. Find them in
   koru — `./run_regression.sh <cluster>` — and quote the real test directories.
   Never invent test ids or paths; if you name a test, you ran/read it this turn.

2. **Read the two or three most recent posts** in
   `src/routes/blog/*/+page.svx` (sort by `date` in frontmatter) before writing.
   They set the house voice and show the current component usage. The most
   recent feature post is the model to copy.

3. **Write `+page.svx`** with this frontmatter shape (strings, hand-parsed — not
   YAML):

   ```
   ---
   title: "Title Case, No Trailing Period"
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
   not build:local, do not ceremony. He reads, then flips `draft: false` and
   regenerates to publish when he's satisfied.

## Voice

- **Present tense, describe the feature — not the journey.** "A grammar is two
  glyphs" not "Today I added a parser." No changelog narration, no "we then…".
- **Short and synthesized.** State the idea and let the tests carry the proof.
- Match the register of the recent posts; don't invent a new house style.

## Never

- Never `git push`, `bun run build:local`, or run the status ceremony from this
  skill. Publishing is Lars's call after he reads it.
- Never write `draft: false`. That flag is Lars's to flip.
- Never cite a test you haven't read/run this session, and never invent a
  `directory`/`categorySlug` — a wrong one renders a dead link on the live site.
