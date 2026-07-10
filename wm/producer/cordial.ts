// Producer/bridge: koru's regression suite ──▶ the CORDIAL signals bus (world model).
//
// Sibling of regression.ts. That one is the WORK faucet — it pushes per-test FLIPS
// to the Convex intake so a dispatch consumer can wake a fix agent. THIS one is the
// WORLD-MODEL faucet: it surfaces the same regression suite onto the Cordial signals
// bus (`:6285/signal` → router → surface / wmfx spool / wake), so the suite is
// VISIBLE the whole way to Cordial — individual tests AND the run verdict as cards.
//
// Two families reach the bus, split by the standing razor (dumb signal, smart engine):
//   - `koru.regression.test`  — RAW per-test telemetry, one card per per-test FLIP
//     (green↔red) between consecutive runs. value = the new status; note carries the
//     test id + failure reason. Declared `route: surface, wmfx=regression_shape` — it
//     feeds the shape engine; it never wakes anyone (a per-test flood must not page).
//   - `test-health`           — the FINAL run verdict, ONE card per run: green | red |
//     regression. Declared `route: surface, wake` — the run's verdict is flinch-class.
//
// Self-contained to Cordial: prior per-test state lives in a local file at the bus
// home (`~/.6digit-cordial/koru-regression-state.json`), NOT in Convex — so the whole
// path (suite → producer → bus → surface) runs with only the Cordial signals surface
// up. The flip logic is the same pure, unit-tested core regression.ts uses
// (computeFlips) — no second state machine to drift.
//
// Usage:
//   bun wm/producer/cordial.ts                 # read latest.json, fire flips + verdict
//   bun wm/producer/cordial.ts <snapshot.json> # use an explicit snapshot as the run
//   CORDIAL_SIGNALS_URL=http://127.0.0.1:6285 bun wm/producer/cordial.ts

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { computeFlips, runFromLatest, type CurrentRun, type FlipSignal, type PrevState } from "./regression.ts";

const BUS = (process.env.CORDIAL_SIGNALS_URL ?? "http://127.0.0.1:6285").replace(/\/$/, "") + "/signal";
// This file lives in <koru>/wm/producer/ — the repo it reads is two levels up.
const KORU_REPO = process.env.KORU_REPO ?? resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const STATE_PATH = process.env.KORU_REGRESSION_STATE ?? join(homedir(), ".6digit-cordial", "koru-regression-state.json");

// ── The run summary — the numbers the verdict card carries ──────────────────────

/** The `summary` block of latest.json — the counts behind the verdict. */
export interface RunSummary {
  inScope: number;
  passed: number;
  failed: number;
  passRate: string | number;
}

export type Verdict = "green" | "red" | "regression";

/** green if nothing red; regression if a green→red flip happened this run; else red. */
export function verdictOf(summary: RunSummary, regressions: number): Verdict {
  if (regressions > 0) return "regression";
  if (summary.failed > 0) return "red";
  return "green";
}

// ── Card shapes — what lands on the bus ─────────────────────────────────────────

export interface Card {
  name: string;
  kind: "measured";
  value: number | string;
  face: "in";
  note: string;
  source: "koru.regression";
  repo: "koru";
}

/** One per-test flip → one raw telemetry card (value = the NEW status). */
export function flipCard(flip: FlipSignal): Card {
  const status = flip.type === "regression" ? "failure" : "success";
  const reason = flip.payload.failureReason ? ` — ${flip.payload.failureReason}` : "";
  return {
    name: "koru.regression.test",
    kind: "measured",
    value: status,
    face: "in",
    note: `${flip.tags.direction}  ${flip.payload.testId}${reason}`,
    source: "koru.regression",
    repo: "koru",
  };
}

/** The whole-run verdict → one card. */
export function verdictCard(verdict: Verdict, summary: RunSummary, regressions: number, gitCommit: string): Card {
  const regressed = regressions > 0 ? `, ${regressions} REGRESSED` : "";
  return {
    name: "test-health",
    kind: "measured",
    value: verdict,
    face: "in",
    note: `${summary.passed}/${summary.inScope} green, ${summary.failed} red${regressed} — @${gitCommit}`,
    source: "koru.regression",
    repo: "koru",
  };
}

/** Build the full ordered card list for a run (flips first, verdict last). Pure. */
export function cardsFor(
  flips: FlipSignal[],
  summary: RunSummary,
  gitCommit: string,
): { cards: Card[]; verdict: Verdict } {
  const regressions = flips.filter((f) => f.type === "regression").length;
  const verdict = verdictOf(summary, regressions);
  const cards = [...flips.map(flipCard), verdictCard(verdict, summary, regressions, gitCommit)];
  return { cards, verdict };
}

// ── Local prior-state store (bus-home JSON; NOT Convex) ──────────────────────────

interface StoredState {
  [testId: string]: { status: string; commit: string };
}

export function stateToPrev(state: StoredState): Map<string, PrevState> {
  const m = new Map<string, PrevState>();
  for (const [testId, row] of Object.entries(state)) {
    m.set(testId, { testId, status: row.status, lastSeenCommit: row.commit });
  }
  return m;
}

function loadState(): Map<string, PrevState> {
  try {
    return stateToPrev(JSON.parse(readFileSync(STATE_PATH, "utf-8")) as StoredState);
  } catch {
    return new Map(); // first run → baseline
  }
}

function saveState(run: CurrentRun): void {
  const state: StoredState = {};
  for (const t of run.tests) {
    state[`${t.categorySlug}/${t.directory}`] = { status: t.status, commit: run.gitCommit };
  }
  mkdirSync(dirname(STATE_PATH), { recursive: true });
  writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

// ── The runner ──────────────────────────────────────────────────────────────────

async function post(card: Card): Promise<boolean> {
  try {
    const r = await fetch(BUS, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(card) });
    if (r.ok) return true;
    console.error(`cordial faucet: bus POST ${r.status} for ${card.name}`);
    return false;
  } catch (e) {
    console.error(`cordial faucet: bus unreachable at ${BUS} — is the Cordial signals surface up? (${(e as Error).message})`);
    process.exit(1);
  }
}

async function main() {
  const arg = process.argv[2];
  const latestPath = arg ? resolve(arg) : resolve(KORU_REPO, "test-results/latest.json");
  console.log(`koru.regression → Cordial: ${latestPath} -> ${BUS}`);

  const json = JSON.parse(readFileSync(latestPath, "utf-8")) as {
    gitCommit: string;
    timestamp?: string;
    summary: RunSummary;
    categories: { slug: string; tests: any[] }[];
  };
  const run = runFromLatest(json);
  const prev = loadState();
  const { signals, baseline } = computeFlips(prev, run);
  const { cards, verdict } = cardsFor(signals, json.summary, run.gitCommit);

  if (baseline) console.log(`  BASELINE: no prior state — recording ${run.tests.length} tests, 0 flips (verdict still fires).`);
  console.log(`  run @ ${run.gitCommit}: ${run.tests.length} tests, ${signals.length} flip(s), verdict = ${verdict}`);

  let posted = 0;
  for (const card of cards) {
    if (await post(card)) {
      posted++;
      console.log(`  → bus  ${card.name} = ${card.value}  — ${card.note}`);
    }
  }
  saveState(run);
  console.log(`  posted ${posted}/${cards.length} card(s); state saved → ${STATE_PATH}`);
}

// Guard so the test can import the pure helpers without a network call.
if (import.meta.main) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
