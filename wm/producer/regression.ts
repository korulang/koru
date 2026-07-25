// Producer/bridge: koru's regression suite ──▶ world `signals` faucet (WORK).
//
// LIVES IN KORU (moved 2026-06-10 from 6digit-world host/producers/): the world's
// source stays target-agnostic; the adapter that knows koru's file layout belongs
// to koru. It pushes to the world host's generic Convex intake (signals:push +
// regression:getState/syncState) — the world knows flips, not koru.
//
// The cleanest faucet in the zoo: it's PURE EXHAUST. `./run_regression.sh` already
// writes `test-results/latest.json` with per-test {status, failureReason} and a
// top-level gitCommit — the runner stays dumb and learns nothing about this loop.
// This adapter reads that file, diffs it against durable per-test state
// (regression_state, host-owned), and pushes ONLY the FLIPS — not the 600+ greens,
// just success↔failure transitions. A green→red flip is a high-magnitude surprise
// `{magnitude, why:"regression", where:<testId>}`; the fix TARGET is the diff
// `prevGreenCommit..gitCommit`, not a static file (a regression names a symptom, not
// a location — docs/test_faucet_design.md).
//
// THE WRITE-BAN IS IN THE SIGNAL. The koru suite is self-authored-explicit
// (METHODOLOGY.md): the danger is a fix agent making the red test green by editing
// the TEST instead of the cause (the fraud CLAUDE.md forbids). The frozen test is
// the oracle the fix must satisfy, so the faucet hands the consumer the path the
// agent must NOT touch: `payload.protectedPaths = [testDir]`. The dispatch consumer
// enforces `filesTouched ∩ protectedPaths = ∅`; the faucet's job is to carry it.
//
// The emitted envelope, per FLIP:
//   { source:"koru.regression", type:"regression"|"recovery", ts, value,
//     tags:{ testId, direction, mustRun, category },
//     payload:{ testId, name, testDir, protectedPaths, gitCommit, prevGreenCommit,
//               failureReason } }
// `payload.testId` is the claim_id a wake derefs to; `gitCommit`+`prevGreenCommit`
// bracket the diff a fix agent bisects.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { ConvexClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

const WORLD_URL =
  process.env.CONVEX_URL ?? process.env.PUBLIC_CONVEX_URL ?? "https://strong-frog-99.convex.cloud";
// This file lives in <koru>/wm/producer/ — the repo it reads is two levels up.
const KORU_REPO = process.env.KORU_REPO ?? resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

const pushSignal = makeFunctionReference<"mutation">("signals:push");
const getState = makeFunctionReference<"query">("regression:getState");
const syncState = makeFunctionReference<"mutation">("regression:syncState");

// ── The shapes (a slice of latest.json — see koru tests/regression runner) ──────

/** One test as it appears in latest.json `categories[].tests[]`. */
export interface RawTest {
  name: string;
  directory: string; // e.g. "010_000_hello_world_koru"
  categorySlug: string; // e.g. "000_CORE_LANGUAGE/010_BASIC_SYNTAX"
  mustRun: boolean;
  status: string; // success | failure | todo | skipped | untested
  failureReason: string;
}

/** The current run, flattened from latest.json. */
export interface CurrentRun {
  gitCommit: string;
  ts: number;
  tests: RawTest[];
}

/** A prior per-test row (from regression_state). */
export interface PrevState {
  testId: string;
  status: string;
  lastSeenCommit: string;
}

export interface FlipSignal {
  source: "koru.regression";
  type: "regression" | "recovery";
  ts: number;
  value: number; // magnitude: 1 = regression (broke), 0 = recovery
  tags: { testId: string; direction: string; mustRun: boolean; category: string };
  payload: {
    testId: string;
    name: string;
    testDir: string;
    protectedPaths: string[];
    gitCommit: string;
    prevGreenCommit: string;
    failureReason: string;
  };
}

export interface StateUpsert {
  testId: string;
  status: string;
  lastSeenCommit: string;
}

// ── The pure core: prior state + this run → flips + new state ───────────────────
// No Convex, no fs — this is the load-bearing logic and the unit under test.

const isGreen = (s: string) => s === "success";
const isRed = (s: string) => s === "failure";

export function testIdOf(t: { categorySlug: string; directory: string }): string {
  return `${t.categorySlug}/${t.directory}`;
}

export function testDirOf(t: { categorySlug: string; directory: string }): string {
  // The on-disk test directory in the koru repo — the path the fix agent must NOT
  // touch (it holds the frozen oracle: input.kz + expected.txt / MUST_ERROR).
  return `tests/regression/${t.categorySlug}/${t.directory}`;
}

export function computeFlips(
  prev: Map<string, PrevState>,
  run: CurrentRun,
): { signals: FlipSignal[]; upserts: StateUpsert[]; baseline: boolean } {
  const signals: FlipSignal[] = [];
  const upserts: StateUpsert[] = [];
  const baseline = prev.size === 0; // first sighting of the whole suite

  for (const t of run.tests) {
    const testId = testIdOf(t);
    // Always record post-run state, so lastSeenCommit tracks the latest run a test
    // appeared in — that's what makes it the last-green commit on a later flip.
    upserts.push({ testId, status: t.status, lastSeenCommit: run.gitCommit });

    const p = prev.get(testId);
    if (!p) continue; // never seen before → no prior to flip from (baseline)

    // Only success↔failure is a flip. todo/skipped/untested are pending states, not
    // red: success→todo is a test being parked, not a regression; todo→failure was
    // never passing. Neither emits.
    if (isGreen(p.status) && isRed(t.status)) {
      const testDir = testDirOf(t);
      signals.push({
        source: "koru.regression",
        type: "regression",
        ts: run.ts,
        value: 1,
        tags: { testId, direction: "green->red", mustRun: t.mustRun, category: t.categorySlug },
        payload: {
          testId,
          name: t.name,
          testDir,
          protectedPaths: [testDir],
          gitCommit: run.gitCommit, // the red commit (the symptom)
          prevGreenCommit: p.lastSeenCommit, // last green commit (diff start)
          failureReason: t.failureReason,
        },
      });
    } else if (isRed(p.status) && isGreen(t.status)) {
      const testDir = testDirOf(t);
      signals.push({
        source: "koru.regression",
        type: "recovery",
        ts: run.ts,
        value: 0,
        tags: { testId, direction: "red->green", mustRun: t.mustRun, category: t.categorySlug },
        payload: {
          testId,
          name: t.name,
          testDir,
          protectedPaths: [testDir],
          gitCommit: run.gitCommit,
          prevGreenCommit: p.lastSeenCommit,
          failureReason: "",
        },
      });
    }
  }

  return { signals, upserts, baseline };
}

// ── Read latest.json → CurrentRun ───────────────────────────────────────────────

interface LatestJson {
  timestamp?: string;
  gitCommit: string;
  categories: { slug: string; tests: Omit<RawTest, "categorySlug">[] }[];
}

export function runFromLatest(json: LatestJson): CurrentRun {
  const ts = json.timestamp ? Date.parse(json.timestamp) : Date.now();
  const tests: RawTest[] = [];
  for (const cat of json.categories) {
    for (const t of cat.tests) {
      tests.push({
        name: t.name,
        directory: t.directory,
        categorySlug: cat.slug,
        mustRun: t.mustRun,
        status: t.status,
        failureReason: t.failureReason ?? "",
      });
    }
  }
  return { gitCommit: json.gitCommit, ts: Number.isNaN(ts) ? Date.now() : ts, tests };
}

// ── The runner ──────────────────────────────────────────────────────────────────

async function main() {
  const latestPath = resolve(KORU_REPO, "test-results/latest.json");
  console.log(`koru.regression faucet: ${latestPath} -> ${WORLD_URL}/signals`);

  const json = JSON.parse(readFileSync(latestPath, "utf-8")) as LatestJson;
  const run = runFromLatest(json);
  console.log(`  run @ ${run.gitCommit}: ${run.tests.length} tests`);

  const world = new ConvexClient(WORLD_URL);
  const prevRows = (await world.query(getState, {})) as PrevState[];
  const prev = new Map<string, PrevState>(prevRows.map((r) => [r.testId, r]));

  const { signals, upserts, baseline } = computeFlips(prev, run);

  if (baseline) {
    console.log(`  BASELINE: no prior state — recording ${upserts.length} tests, emitting 0 flips.`);
  }
  for (const sig of signals) {
    await world.mutation(pushSignal, sig);
    console.log(`  → ${sig.type} ${sig.tags.direction} ${sig.payload.testId} (green@${sig.payload.prevGreenCommit})`);
  }
  await world.mutation(syncState, { upserts });
  console.log(`  state synced (${upserts.length} tests); ${signals.length} flip(s) pushed.`);

  await world.close();
}

// Guard so the test can `import { computeFlips }` without triggering a network call.
if (import.meta.main) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
