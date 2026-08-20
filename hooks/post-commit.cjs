#!/usr/bin/env node
// membrane + worldmodel — post-commit faucet (the cross-repo link).
//
// After a commit lands in a CONSUMER repo (koru, koru-libs, …), if its
// `## World Model` section declared a BELIEF-CLASS signal — contradiction,
// regime-change, or correction — then a belief about Koru just changed and it
// must reach the shared corpus. This faucet does NOT silently write the corpus
// (no magic daemon mutating another repo behind your back). It QUEUES the
// obligation durably into the corpus inbox and surfaces it, so an AGENT closes
// the loop by recording the belief. A human is never in this loop.
//
// Routine commits (mechanical signals, or `Signals: acknowledged-none`) produce
// nothing here — the link only fires when YOU declared a belief changed.

// A Signal: entry runs until the NEXT Signal: line — not until the next newline.
// FIXED 2026-08-08: both readers below used /^Signal:\s*(.+)$/gim, and `.` does not
// match a newline, so every note was cut wherever the author's editor happened to
// wrap. Measured at ~3/4 of authored signal text destroyed before reaching the bus.
// Worse than data loss: a correction is written setup-first (what was believed, THEN
// what is true instead), so a cut at the first wrap systematically PRESERVES THE
// ERROR AND DELETES ITS CORRECTION. Found by the first autonomous gardening run of
// the `claude` seat (6digit-claude/concepts/frag-the-bus-keeps-the-error-and-drops-the-correction.md).
const signalEntries = (body) =>
  body.split(/^Signal:[ \t]*/im).slice(1)
    .map((chunk) => chunk.split(/^#/m)[0].replace(/\s*\n\s*/g, " ").trim())
    .filter(Boolean);

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const git = (a) => execFileSync("git", a, { encoding: "utf8" }).trim();

// Routing is registry-driven, NOT a hardcoded list: a signal reaches the corpus
// iff its interface file declares `membrane: true`. The interface decides what is
// a belief worth recording — never a value-judgment baked into this hook.
function isMembrane(name) {
  try { return /^membrane:\s*true\b/im.test(fs.readFileSync(`signals/${name}.signal`, "utf8")); }
  catch { return false; }
}

function sectionBody(text, name) {
  let cur = null, buf = [];
  for (const line of text.split("\n")) {
    const h = line.match(/^##\s+(.*\S)\s*$/);
    if (h) { if (cur === name) break; cur = h[1].toLowerCase(); continue; }
    if (cur === name) buf.push(line);
  }
  return cur === null && !buf.length ? "" : buf.join("\n");
}

const msg = git(["log", "-1", "--format=%B"]);
const sha = git(["rev-parse", "--short", "HEAD"]);

// THE AUTHOR DATE, NOT NOW, AND NOT THE COMMITTER DATE.
//
// A card used to be stamped `new Date()` at publish time, which is the committer
// clock by another name. A commit that gets amended or rebased — the normal path
// here, since `~/src/CLAUDE.md` names `git worktree add` as the standard move and
// worktree branches land on main by rebase — fires this hook again on every
// rewrite, and each firing stamped a DIFFERENT time. So one belief arrived as N
// cards with N timestamps and nothing tying them together.
//
// Measured 2026-08-08: koru `43e5b5e9` published the same fifty-three characters
// four times over six hours (14:53:24Z, 16:39:14Z, 20:18:20Z, 20:53:54Z) — its
// author date plus two seconds, then its committer date to the second, with two
// rewrites in between. A fifth card from the same worktree pointed at a commit
// two hours away from its own stamp. Ruling:
// 6digit-claude/concepts/frag-a-bus-card-carries-no-commit-identity.md.
//
// `%at` is the AUTHOR date, which amend and rebase both preserve. It is therefore
// stable across every rewrite of the same work, so the N cards of one belief now
// share one timestamp and a consumer can fold them. The sha below is the other
// half — it is what makes a card reach BACK to the commit for the full note text —
// but a rewrite mints a new sha, so the sha identifies the firing and the author
// date identifies the belief. Both go on the card; neither substitutes for the other.
const authoredAt = new Date(Number(git(["log", "-1", "--format=%at"])) * 1000).toISOString();

// --- Surface pass: every Signal: line the gate sealed into this commit — measured
// AND inferred — slides onto the Cordial signals surface (:6285) as a live card. This
// is the git-log → live-bus bridge: what the commit body carries becomes something you
// WATCH arrive. Best-effort and non-blocking — the surface may be down; a commit never
// waits on it. Mesh-wide by construction: any repo posts to the one central surface.
function surfaceSignals() {
  // THE BUS MOVED AND THIS DID NOT. Until 2026-08-08 this posted to the Cordial HTTP
  // surface on :6285, which was retired — nothing has listened there since. Every
  // belief-class signal from every commit in the constellation was DROPPED at the
  // door, with a warning nobody was reading, so the corpora were starved at the
  // source and a broken bus was indistinguishable from a quiet week.
  //
  // The live bus is NATS JetStream: stream SIGNALS, subjects world.signal.<family>
  // (6digit-world/host/signalbus.ts). Still best-effort and non-blocking — a commit
  // never waits on the bus — and still LOUD on failure, because a signal that never
  // reached the bus is a dropped signal and this system exists to make faults seen.
  const server = process.env.CLAUDE_NATS || process.env.NATS_URL || "127.0.0.1:4222";
  const repo = path.basename(git(["rev-parse", "--show-toplevel"]));
  const sigMeta = (name) => {
    try {
      const f = fs.readFileSync(`signals/${name}.signal`, "utf8");
      const g = (k) => (f.match(new RegExp("^" + k + ":\\s*(\\S+)", "im")) || [])[1];
      return { kind: g("kind"), face: g("face") };
    } catch { return {}; }
  };
  const lines = signalEntries(sectionBody(msg, "world model"));
  for (const line of lines) {
    const name = (line.match(/^(\S+)/) || [])[1];
    if (!name) continue;
    const meta = sigMeta(name);
    const vm = line.match(/value=(\S+)/);
    const value = vm ? (Number.isFinite(Number(vm[1])) ? Number(vm[1]) : vm[1]) : undefined;
    const note = line.replace(/^\S+\s*/, "").replace(/value=\S+/, "").replace(/\b(measured|stall)\b/g, "").replace(/^[—\-\s]+/, "").trim();
    // `repo` and `source` are DIFFERENT fields on the bus and the difference is
    // load-bearing: source is "which instrument/faucet raised it" (a footer),
    // repo is "which application the card is about" — the schema's own words are
    // "the declared join ... instead of string-guessing from source". Stamping
    // only source left every commit card un-joinable, so a consumer either
    // guessed the repo from an instrument name or dropped the card into an
    // unattributed bucket. Court does the latter, loudly, by design.
    // source keeps carrying the repo name for now — existing footers read it —
    // but the join is `repo`, and it is declared here rather than inferred there.
    // `sha` is the card's way back to the commit it came from. Without it the only
    // documented recovery route was "take the timestamp and the source repo and go
    // find the commit" — which stops working the instant the commit is rewritten,
    // and fails SILENTLY, returning nothing, which looks exactly like a commit that
    // was garbage-collected. The note on the wire is a one-line squash of a multi-line
    // Signal:, so back-filling the full text needs the commit, so the card must name it.
    const body = { name, kind: meta.kind || (/\bmeasured\b/.test(line) ? "measured" : "inferred"), value, face: meta.face, note: note || undefined, source: repo, repo, sha };
    try {
      execFileSync("nats", ["--server", server, "pub", `world.signal.${name}`, JSON.stringify({ ...body, at: authoredAt })], { stdio: ["ignore", "ignore", "pipe"], timeout: 4000 });
    } catch (e) {
      // Do NOT swallow. A signal that never reached the bus is a DROPPED signal.
      // A valid commit must not block on a down surface — but the loss is a fault,
      // and this whole system exists to make faults SEEN, not hidden. Loud, named,
      // non-blocking: the commit lands, the drop screams.
      process.stderr.write(
        `\n⚠ faucet: signal '${name}' did NOT reach the bus (nats ${server}) — card DROPPED ` +
          `(surface down?). ${String(e.stderr || e.message || "").trim()}\n`,
      );
    }
  }
}
surfaceSignals();

// A recording (a commit that writes concept files) is a belief LANDING in the
// corpus, not a source belief needing routing. Skip it — this is what lets the
// faucet be installed uniformly everywhere (even on a self-contained repo that is
// its own corpus) without the recording re-queuing itself into an endless loop.
const touched = git(["show", "--name-only", "--format=", "HEAD"]).split("\n").filter(Boolean);
if (touched.some((f) => /(^|\/)concepts\/[^/]+\.md$/.test(f))) process.exit(0);

const wm = sectionBody(msg, "world model");
const signals = signalEntries(wm)
  .map((entry) => ({ type: ((entry.match(/^(\S+)/) || [])[1] || "").toLowerCase(), line: entry }))
  .filter((s) => isMembrane(s.type));
if (!signals.length) process.exit(0); // routine commit — nothing to route

// THE STORE POINTER, resolved the one documented way. This used to read a bare
// `.membrane` file and, failing to find one, print a note and exit 0 — so a
// belief-class signal silently stopped reaching the inbox, and the advice it
// printed named a store repo that has since been retired.
//
// `.membrane` was the FOURTH site of a mechanism the skill, `snap.mjs`,
// `install.sh` and this file each read differently. The first three were
// converged on 2026-08-04; this one would have been left resolving a file the
// installer no longer writes. Absence is not an error — no pointer means the
// corpus is IN-REPO, which is the documented default.
const top = git(["rev-parse", "--show-toplevel"]);
const ptr = path.join(top, ".claude", "membrane.json");
let store = top;
if (fs.existsSync(ptr)) {
  try {
    const declared = JSON.parse(fs.readFileSync(ptr, "utf8")).store;
    if (declared) store = path.resolve(top, declared);
  } catch (e) {
    console.error(`\n● ${ptr} is not valid JSON — routing this signal in-repo instead.`);
    console.error(`  ${String(e.message).trim()}\n`);
  }
}
const repo = path.basename(top);
const inbox = path.join(store, "inbox");
fs.mkdirSync(inbox, { recursive: true });
const pendingFile = path.join(inbox, "pending.jsonl");

for (const s of signals) {
  const rec = { ts: new Date().toISOString(), repo, sha, subject: msg.split("\n")[0], type: s.type, signal: s.line };
  fs.appendFileSync(pendingFile, JSON.stringify(rec) + "\n");
}
const n = fs.readFileSync(pendingFile, "utf8").trim().split("\n").filter(Boolean).length;

console.error(`\n● belief signal fired — a Koru belief changed and must reach the corpus.`);
console.error(`    repo:   ${repo} @ ${sha}`);
for (const s of signals) console.error(`    signal: ${s.line}`);
console.error(`    queued → ${pendingFile}  (${n} pending)`);
console.error(`  An agent drains the inbox into the corpus. You never run anything.\n`);
