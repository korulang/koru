#!/usr/bin/env node
// membrane + worldmodel — commit-msg enforcement (the pit-of-success gate).
//
// Two disciplines, two sectioned formats, one hook. The commit body carries
// `## World Model` and/or `## Membrane` markdown sections; each tool parses ONLY
// its own section, so the two formats never collide.
//
//   ## World Model   — UNIVERSAL gate. EVERY commit must declare a faucet signal
//                      or consciously acknowledge none. "Did a belief about Koru
//                      change here?" is always a cheap, honest, answerable
//                      question — `acknowledged-none` is a true, common answer.
//
//   ## Membrane      — UNIVERSAL gate, OKF-AWARE contents. Every commit answers
//                      "did a belief change?" — silence is rejected here too. What
//                      the answer must CONTAIN is what varies: a commit that stages
//                      concept files owes full lineage (the five verbs); one that
//                      stages none discharges with `Evolution: acknowledged-none`.
//                      So the QUESTION is asked everywhere and the OBLIGATION is
//                      triggered by an OKF change — a code commit is never forced
//                      into a meaningless "null evolution", only into saying so.
//
// Reject-by-default with a CONSCIOUS opt-out (`acknowledged-none`, never silence),
// so a discipline can't be skipped by inertia — only by a deliberate, recorded
// act. The failure messages TEACH the correct shape: they are the pit-of-success
// walls. A good wall doesn't just block — it guides into the pit.
//
// Install:  hooks/install.sh   (or: cp hooks/commit-msg .git/hooks/ && chmod +x)

const fs = require("fs");
const { execFileSync } = require("child_process");

let msg = fs.readFileSync(process.argv[2], "utf8");

// Mechanical, git-generated commits are not authored belief-changes — exempt them.
const firstLine = msg.split("\n").find((l) => l.trim()) || "";
if (/^(Merge |Revert "|fixup!|squash!|amend!|Rebase )/.test(firstLine)) process.exit(0);

// --- section split: each key is read only within its own `## Header` region ---
function sections(text) {
  const out = { _preamble: [] };
  let cur = "_preamble";
  for (const line of text.split("\n")) {
    const h = line.match(/^##\s+(.*\S)\s*$/);
    if (h) { cur = h[1].toLowerCase(); out[cur] = out[cur] || []; }
    else out[cur].push(line);
  }
  for (const k of Object.keys(out)) out[k] = out[k].join("\n");
  return out;
}
let secs = sections(msg);
const keyIn = (text, k) =>
  text == null ? undefined : (text.match(new RegExp("^" + k + ":\\s*(.+)$", "m")) || [])[1];

// A signal is belief-class iff its interface declares `membrane: true`. Registry-
// driven, never a hardcoded list — the same rule the post-commit faucet routes on.
const isMembraneSignal = (name) => {
  try { return /^membrane:\s*true\b/im.test(fs.readFileSync(`signals/${name}.signal`, "utf8")); }
  catch { return false; }
};

function fail(discipline, reason, help) {
  console.error(`\n✗ ${discipline}: commit rejected — ${reason}\n`);
  console.error(help.trimEnd());
  console.error(`\n(emergency bypass: git commit --no-verify — use sparingly; it skips the discipline)\n`);
  process.exit(1);
}

const WM_HELP = `  Every commit answers one question: did a belief about the system change here?
    ## World Model
    Signal: contradiction — <what flipped, and against which prior belief>
  If nothing here is belief-worthy, acknowledge it on purpose:
    ## World Model
    Signals: acknowledged-none`;

const MEM_HELP = `  Every commit answers a second question: did a durable belief change here?
  If YES — stage the concept edit and declare the lineage:
    ## Membrane
    Action: evolve                      # create | evolve | merge | split | correct
    Concept: frag-<id>
    Occludes: <prior-blob-sha>          # evolve   (auto-derived if you omit it)
    Parents: frag-<id>, frag-<id>       # merge | split
    Severs: frag-<id>@<blob-sha>        # correct  (auto-derived if you omit it)
    Reason: <why the prior belief was wrong>   # correct
  If NO — acknowledge it on purpose (a conscious "nothing to garden"):
    ## Membrane
    Evolution: acknowledged-none

  A concept = concepts/frag-<id>.md — ONE belief per file, prose body.
  Write the BELIEF: the ruling, the why, the open questions — what no tool
  can derive. NEVER prose-duplicate runnable code, tests, or probe results;
  reference them by name (they move; restated prose lies).
  Unsure evolve vs correct? It's evolve — correct means "was NEVER right".
  Blob shas by hand: git rev-parse HEAD:concepts/frag-<id>.md
  Full discipline: .claude/skills/membrane/SKILL.md`;

// ---------------------------------------------------------------------------
// 1. World Model gate — UNIVERSAL. Fires on every authored commit.
// ---------------------------------------------------------------------------
const wm = secs["world model"];
if (wm == null) fail("World Model", "missing the '## World Model' section", WM_HELP);
const wmAckNone = /^Signals:\s*acknowledged-none\b/im.test(wm);
const nSignals = (wm.match(/^Signal:\s*\S+/gim) || []).length;
if (!wmAckNone && nSignals === 0)
  fail("World Model", "declare a 'Signal: <type> ...' line, or 'Signals: acknowledged-none'", WM_HELP);

// --- coherence: every declared signal resolves to the repo's interface ---
// register-on-miss — the interface GROWS as you declare, never blocks. You can't
// make up a signal: declaring one that isn't defined defines it (as an orphan).
// That's the floatable local ontology accumulating on its own, statically checked.
//
// EXCEPT for near-misses. Register-on-miss cannot tell new vocabulary from a
// typo, and a typo'd signal silently becomes a second, near-identical entry in
// the very ontology this gate exists to keep coherent — drift introduced by the
// anti-drift mechanism. So a name within edit-distance 1 of an existing signal
// is rejected rather than minted. Deliberate neighbours are still reachable:
// create the .signal file yourself, which is the conscious act the rest of this
// hook already asks for everywhere else.
function editDistance1(a, b) {
  if (a === b) return false;
  const [s, l] = a.length <= b.length ? [a, b] : [b, a];
  if (l.length - s.length > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < s.length && j < l.length) {
    if (s[i] === l[j]) { i++; j++; continue; }
    if (++edits > 1) return false;
    if (s.length === l.length) { i++; j++; } else { j++; }
  }
  return true;
}
const knownSignals = (() => {
  try { return fs.readdirSync("signals").filter((f) => f.endsWith(".signal")).map((f) => f.slice(0, -7)); }
  catch { return []; }
})();
for (const nm of [...wm.matchAll(/^Signal:\s*(\S+)/gim)].map((m) => m[1])) {
  const sigPath = `signals/${nm}.signal`;
  if (fs.existsSync(sigPath)) continue;
  const near = knownSignals.find((k) => editDistance1(nm, k));
  if (near) {
    fail("World Model",
      `signal '${nm}' is one character from the existing '${near}' — refusing to mint a near-duplicate`,
      `  If '${nm}' is a typo, fix it to '${near}'.\n` +
      `  If it is genuinely a new signal, define it on purpose first:\n` +
      `    printf 'name: ${nm}\\nkind: inferred\\nshape: categorical\\nface: in\\nmembrane: false\\n' > signals/${nm}.signal\n` +
      `  Register-on-miss grows the ontology for clearly-new names; it will not\n` +
      `  quietly split an existing one in two.`);
  }
  try {
    fs.mkdirSync("signals", { recursive: true });
    fs.writeFileSync(sigPath,
      `name: ${nm}\nkind: inferred\nshape: categorical\nface: in\nmembrane: false\n` +
      `note: auto-registered orphan — declared before it was defined; refine me\n`);
    console.error(`  worldmodel: registered new signal → ${sigPath} (orphan; refine + commit it)`);
  } catch { /* signals/ not writable here — collection still lives in the log */ }
}

// ---------------------------------------------------------------------------
// 2. Membrane gate — UNIVERSAL. Every commit answers "did a belief change?":
//    either declare the lineage (with the concept staged) or a conscious
//    'Evolution: acknowledged-none'. Silence is rejected — same forced-attention
//    contract as the World Model gate. A belief-class signal (membrane: true)
//    forbids acknowledged-none: you said a belief changed, so garden it here.
// ---------------------------------------------------------------------------
const memFail = (m) => fail("Membrane", m, MEM_HELP);
let staged = [];
try {
  staged = execFileSync("git", ["diff", "--cached", "--name-only"], { encoding: "utf8" })
    .split("\n").filter(Boolean);
} catch { /* not in a repo / no index — skip OKF gate */ }
const okfStaged = staged.filter((f) => /(^|\/)concepts\/[^/]+\.md$/.test(f));
const touchesOKF = okfStaged.length > 0;

// A commit declares a belief changed iff it carries a Signal whose interface is
// membrane: true (contradiction / correction / regime-change). That declaration
// is a PROMISE to garden — the interlock below makes it non-skippable.
const beliefSignal = [...wm.matchAll(/^Signal:\s*(\S+)/gim)].map((m) => m[1]).some(isMembraneSignal);

// --- MECHANICAL SCAFFOLDING: derive the deterministic trailer fields from the
// staged diff so the agent supplies only judgment (the verb + the belief), never
// bookkeeping. Runs on every commit, in addition to explicit gardening walks.
// Only fires when unambiguous (exactly one staged concept file); writes the
// derived lines back into the message, exactly like the measured signal below.
if (okfStaged.length === 1 && secs["membrane"] != null) {
  const rel = okfStaged[0];
  const id = rel.replace(/^.*\//, "").replace(/\.md$/, "");
  const mem0 = secs["membrane"];
  const action0 = keyIn(mem0, "Action");
  const derived = [];
  if (!keyIn(mem0, "Concept")) derived.push(`Concept: ${id}`);
  if (action0 === "evolve" && !keyIn(mem0, "Occludes")) {
    // the prior belief is the file's blob at HEAD — an evolve target already exists
    try {
      const prior = execFileSync("git", ["rev-parse", `HEAD:${rel}`], { encoding: "utf8" }).trim();
      derived.push(`Occludes: ${prior}`);
    } catch { /* not in HEAD → not an evolve target; validation below reports it */ }
  }
  if (action0 === "correct" && !keyIn(mem0, "Severs")) {
    // the repudiated lineage point is the file's blob at HEAD — same derivation
    try {
      const prior = execFileSync("git", ["rev-parse", `HEAD:${rel}`], { encoding: "utf8" }).trim();
      derived.push(`Severs: ${id}@${prior}`);
    } catch { /* not in HEAD → nothing to sever; validation below reports it */ }
  }
  if (derived.length) {
    const lines = msg.split("\n");
    const h = lines.findIndex((l) => /^##\s+membrane\s*$/i.test(l));
    if (h >= 0) {
      lines.splice(h + 1, 0, ...derived);
      msg = lines.join("\n");
      fs.writeFileSync(process.argv[2], msg);
      secs = sections(msg);
      console.error(`  membrane: scaffolded ${derived.map((d) => d.split(":")[0]).join(", ")} from the staged diff`);
    }
  }
}

const mem = secs["membrane"];
const memAckNone = mem != null && /^Evolution:\s*acknowledged-none\b/im.test(mem);

// Interlock: a declared belief-change MUST be gardened in this same commit.
if (beliefSignal && !touchesOKF)
  memFail("a belief-class signal fired, but no concept file is staged — a changed belief must be gardened in the same commit (stage the concept + declare the Action), never queued away");

if (mem == null)
  memFail("every commit must declare a '## Membrane' section: a lineage Action (with the concept staged), or 'Evolution: acknowledged-none'");

if (touchesOKF) {
  // acknowledged-none is FALSE when you actually changed concept files.
  if (memAckNone)
    memFail("you staged concept files — 'Evolution: acknowledged-none' is false here; declare the lineage");

  // --- 2b. FRAGMENT SHAPE WALL -------------------------------------------
  // Every staged concepts/frag-*.md must be a well-formed OKF fragment:
  // frontmatter (type/id/provenance/ts, all non-empty), id == filename stem,
  // and a prose body after the frontmatter. The lineage trailer above walls the
  // COMMIT MESSAGE; this walls the FILE SHAPE the SKILL documents — the on-disk
  // frontmatter requirement that drifted unwalled until it was silently gone.
  // Read the STAGED blob (`git show :<path>`), never the working tree, so the
  // gate judges exactly what is being committed. Only frag-*.md is shaped —
  // other concept files (indexes, notes) keep their own conventions.
  const fragStaged = okfStaged.filter((f) => /(^|\/)concepts\/frag-[^/]+\.md$/.test(f));
  for (const rel of fragStaged) {
    const stem = rel.replace(/^.*\//, "").replace(/\.md$/, "");
    let text;
    try { text = execFileSync("git", ["show", `:${rel}`], { encoding: "utf8" }); }
    catch { continue; } // staged deletion / unreadable — no shape to check
    const flines = text.split("\n");
    if ((flines[0] || "").trim() !== "---")
      memFail(`${rel}: missing OKF frontmatter — open the file with a '---' line, then 'type/id/provenance/ts', a closing '---', then the belief body`);
    let fend = -1;
    for (let i = 1; i < flines.length; i++) if (flines[i].trim() === "---") { fend = i; break; }
    if (fend < 0)
      memFail(`${rel}: frontmatter is never closed — add a '---' line after the 'type/id/provenance/ts' block`);
    const fm = flines.slice(1, fend).join("\n");
    const fmField = (k) => { const m = fm.match(new RegExp("^" + k + ":\\s*(.*)$", "m")); return m ? m[1].trim() : null; };
    const eg = { type: "belief", id: stem, provenance: "<session / source of this belief>", ts: "<iso8601>" };
    for (const k of ["type", "id", "provenance", "ts"]) {
      const v = fmField(k);
      if (v == null || v === "")
        memFail(`${rel}: missing frontmatter field '${k}' — add '${k}: ${eg[k]}'`);
    }
    if (fmField("id") !== stem)
      memFail(`${rel}: frontmatter 'id: ${fmField("id")}' must equal the filename stem — set 'id: ${stem}' (id == filename)`);
    if (flines.slice(fend + 1).join("\n").trim() === "")
      memFail(`${rel}: no prose body after the frontmatter — an OKF fragment is frontmatter + a belief body`);
  }

  const need = { create: [], evolve: ["Occludes"], merge: ["Parents"], split: ["Parents"], correct: ["Severs", "Reason"] };
  const action = keyIn(mem, "Action");
  if (!action) memFail("declare an Action: (create/evolve/merge/split/correct)");
  if (!need[action]) memFail(`unknown Action '${action}' — want: ${Object.keys(need).join("/")}`);
  if (!keyIn(mem, "Concept")) memFail("missing Concept:");
  for (const k of need[action]) if (!keyIn(mem, k)) memFail(`Action ${action} requires ${k}:`);

  // --- resolve the references for real: merge/split must not dangle ---
  const objExists = (sha) => {
    try { execFileSync("git", ["cat-file", "-e", sha], { stdio: "ignore" }); return true; }
    catch { return false; }
  };
  const conceptExists = (id) =>
    fs.existsSync(`concepts/${id}.md`) || objExists(`:concepts/${id}.md`) || objExists(`HEAD:concepts/${id}.md`);

  if (action === "evolve") {
    const blob = keyIn(mem, "Occludes").trim();
    if (!objExists(blob)) memFail(`Occludes: '${blob}' is not a reachable git object — it must be the prior blob sha`);
  }
  if (action === "merge" || action === "split") {
    const parents = keyIn(mem, "Parents").split(",").map((s) => s.trim()).filter(Boolean);
    if (parents.length < 2) memFail(`Action ${action} needs ≥2 Parents: (got ${parents.length})`);
    for (const p of parents) if (!conceptExists(p)) memFail(`Parents: concept '${p}' does not exist in the corpus`);
  }
  if (action === "correct") {
    const sev = keyIn(mem, "Severs").trim();           // frag-<id>@<blob-sha>
    const at = sev.lastIndexOf("@");
    if (at < 0) memFail(`Severs: '${sev}' must be 'frag-<id>@<blob-sha>'`);
    const id = sev.slice(0, at), blob = sev.slice(at + 1);
    if (!conceptExists(id)) memFail(`Severs: concept '${id}' does not exist in the corpus`);
    if (!objExists(blob)) memFail(`Severs: blob '${blob}' is not a reachable git object`);
    if (nSignals === 0)
      fail("World Model", "Action correct is intrinsically attention-worthy — declare a 'Signal:', not acknowledged-none", WM_HELP);
  }
} else {
  // No concept files staged — the only legal declaration is a conscious opt-out.
  if (keyIn(mem, "Action"))
    memFail("you declared an Action but staged no concept file — stage the concept edit, or use 'Evolution: acknowledged-none'");
  if (!memAckNone)
    memFail("no concept staged and no lineage — declare 'Evolution: acknowledged-none' to consciously record that nothing here changed a durable belief");
}

// ---------------------------------------------------------------------------
// 3. MEASURED signals — run the WMFX ENGINE on THIS commit and seal its output
//    into the message. commit-msg can still edit the message, so the engine's
//    result becomes part of the commit. The git log is then ONE unified series:
//    inferred signals the agent declared above + measured signals the engine
//    computes here. We invoke the engine-COMPILED instrument binary (cc_live) —
//    NEVER a re-implementation of the model's rule. If the binary isn't built,
//    we skip silently (build at install) — the measured layer never blocks a commit.
// ---------------------------------------------------------------------------
const CC = "models/commit_cadence/cc_live";
if (fs.existsSync(CC)) {
  try {
    // gap_min = the silence before THIS commit = now − the parent commit's time
    let gap = 0;
    try {
      const ct = parseInt(execFileSync("git", ["log", "-1", "--format=%ct", "HEAD"], { encoding: "utf8" }).trim(), 10);
      gap = (Date.now() / 1000 - ct) / 60;
    } catch { gap = 0; } // first commit — no parent
    const [value, alarm] = execFileSync(CC, [gap.toFixed(1)], { encoding: "utf8" }).trim().split(/\s+/);
    const line = `Signal: commit-silence value=${value} measured${alarm === "1" ? " stall" : ""}`;
    const lines = msg.split("\n");
    const h = lines.findIndex((l) => /^##\s+world model\s*$/i.test(l));
    if (h >= 0) lines.splice(h + 1, 0, line);
    else lines.push("", "## World Model", line);
    fs.writeFileSync(process.argv[2], lines.join("\n"));
    console.error(`  worldmodel: engine ran → commit-silence=${value}${alarm === "1" ? " (STALL)" : ""} — sealed into the commit`);
  } catch { /* measured layer is best-effort — never block a commit on it */ }
} else if (fs.existsSync("models/commit_cadence")) {
  // The model is HERE but not BUILT. Skipping is still correct (the measured
  // layer never blocks), but skipping *silently* makes "this repo does not
  // measure cadence" and "this repo intends to and isn't" look identical — so
  // every commit quietly loses a signal the repo meant to collect. Say it.
  console.error(`  worldmodel: models/commit_cadence present but ${CC} is not built — commit-silence NOT measured (build: models/commit_cadence/build.sh)`);
}
