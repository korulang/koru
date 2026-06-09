// Test the load-bearing core of the koru.regression faucet: computeFlips. Pure
// logic, no Convex, no fs. Run: `bun wm/producer/regression.test.ts`.
//
// The guarantees pinned here:
//   - baseline (empty prior) emits NOTHING and records all tests
//   - success→failure emits ONE regression carrying prevGreenCommit = last-green
//   - failure→success emits ONE recovery
//   - stable / pending transitions (success→success, success→todo, todo→failure)
//     emit nothing — only success↔failure is a flip
//   - every test always produces a state upsert (so lastSeenCommit tracks)
//   - the WRITE-BAN rides in the signal: protectedPaths = [the test dir]

import assert from "node:assert/strict";
import {
  computeFlips,
  runFromLatest,
  testIdOf,
  testDirOf,
  type CurrentRun,
  type PrevState,
  type RawTest,
} from "./regression.ts";

function mkTest(o: Partial<RawTest> & { directory: string; categorySlug: string; status: string }): RawTest {
  return {
    name: o.name ?? o.directory,
    directory: o.directory,
    categorySlug: o.categorySlug,
    mustRun: o.mustRun ?? true,
    status: o.status,
    failureReason: o.failureReason ?? "",
  };
}

function prevMap(rows: PrevState[]): Map<string, PrevState> {
  return new Map(rows.map((r) => [r.testId, r]));
}

const CAT = "000_CORE_LANGUAGE/010_BASIC_SYNTAX";
const DIR = "010_000_hello_world_koru";
const ID = `${CAT}/${DIR}`;
const TESTDIR = `tests/regression/${CAT}/${DIR}`;

let passed = 0;
function ok(name: string, fn: () => void) {
  fn();
  passed++;
  console.log(`  ✓ ${name}`);
}

console.log("computeFlips:");

ok("baseline: empty prior emits nothing, records every test", () => {
  const run: CurrentRun = {
    gitCommit: "aaaa",
    ts: 1000,
    tests: [
      mkTest({ directory: DIR, categorySlug: CAT, status: "success" }),
      mkTest({ directory: "020_x", categorySlug: CAT, status: "failure" }),
    ],
  };
  const { signals, upserts, baseline } = computeFlips(prevMap([]), run);
  assert.equal(baseline, true);
  assert.equal(signals.length, 0, "baseline must not fire — there is no prior green to regress from");
  assert.equal(upserts.length, 2);
  assert.deepEqual(
    upserts.map((u) => u.lastSeenCommit),
    ["aaaa", "aaaa"],
  );
});

ok("green→red emits ONE regression with prevGreenCommit = last-green commit", () => {
  const prev = prevMap([{ testId: ID, status: "success", lastSeenCommit: "green1" }]);
  const run: CurrentRun = {
    gitCommit: "red2",
    ts: 2000,
    tests: [mkTest({ directory: DIR, categorySlug: CAT, status: "failure", failureReason: "exit 1: boom" })],
  };
  const { signals } = computeFlips(prev, run);
  assert.equal(signals.length, 1);
  const s = signals[0];
  assert.equal(s.type, "regression");
  assert.equal(s.value, 1);
  assert.equal(s.tags.direction, "green->red");
  assert.equal(s.payload.testId, ID);
  assert.equal(s.payload.gitCommit, "red2", "symptom commit = this run");
  assert.equal(s.payload.prevGreenCommit, "green1", "diff start = the last commit it was green at");
  assert.equal(s.payload.failureReason, "exit 1: boom");
});

ok("the write-ban rides in the signal: protectedPaths = [testDir]", () => {
  const prev = prevMap([{ testId: ID, status: "success", lastSeenCommit: "green1" }]);
  const run: CurrentRun = {
    gitCommit: "red2",
    ts: 2000,
    tests: [mkTest({ directory: DIR, categorySlug: CAT, status: "failure" })],
  };
  const { signals } = computeFlips(prev, run);
  assert.equal(signals[0].payload.testDir, TESTDIR);
  assert.deepEqual(signals[0].payload.protectedPaths, [TESTDIR]);
});

ok("red→green emits ONE recovery (value 0)", () => {
  const prev = prevMap([{ testId: ID, status: "failure", lastSeenCommit: "red1" }]);
  const run: CurrentRun = {
    gitCommit: "green2",
    ts: 3000,
    tests: [mkTest({ directory: DIR, categorySlug: CAT, status: "success" })],
  };
  const { signals } = computeFlips(prev, run);
  assert.equal(signals.length, 1);
  assert.equal(signals[0].type, "recovery");
  assert.equal(signals[0].value, 0);
  assert.equal(signals[0].tags.direction, "red->green");
});

ok("stable + pending transitions emit nothing (only success↔failure is a flip)", () => {
  const prev = prevMap([
    { testId: `${CAT}/a`, status: "success", lastSeenCommit: "c1" }, // success→success
    { testId: `${CAT}/b`, status: "success", lastSeenCommit: "c1" }, // success→todo (parked)
    { testId: `${CAT}/c`, status: "todo", lastSeenCommit: "c1" }, // todo→failure (never green)
    { testId: `${CAT}/d`, status: "failure", lastSeenCommit: "c1" }, // failure→failure
  ]);
  const run: CurrentRun = {
    gitCommit: "c2",
    ts: 4000,
    tests: [
      mkTest({ directory: "a", categorySlug: CAT, status: "success" }),
      mkTest({ directory: "b", categorySlug: CAT, status: "todo" }),
      mkTest({ directory: "c", categorySlug: CAT, status: "failure" }),
      mkTest({ directory: "d", categorySlug: CAT, status: "failure" }),
    ],
  };
  const { signals, upserts } = computeFlips(prev, run);
  assert.equal(signals.length, 0, "none of these are success↔failure flips");
  assert.equal(upserts.length, 4, "but every test still updates its lastSeenCommit");
  assert.ok(upserts.every((u) => u.lastSeenCommit === "c2"));
});

ok("a brand-new test failing on first sight does NOT regress (no prior green)", () => {
  const prev = prevMap([{ testId: ID, status: "success", lastSeenCommit: "green1" }]);
  const run: CurrentRun = {
    gitCommit: "c2",
    ts: 5000,
    tests: [
      mkTest({ directory: DIR, categorySlug: CAT, status: "success" }),
      mkTest({ directory: "999_new", categorySlug: CAT, status: "failure" }), // never seen
    ],
  };
  const { signals } = computeFlips(prev, run);
  assert.equal(signals.length, 0);
});

console.log("\nrunFromLatest:");

ok("flattens categories[].tests[] and stamps categorySlug + ts", () => {
  const run = runFromLatest({
    timestamp: "2026-06-06T12:00:00.000Z",
    gitCommit: "b203f6cb",
    categories: [
      {
        slug: CAT,
        tests: [{ name: "hello", directory: DIR, mustRun: true, status: "success", failureReason: "" } as any],
      },
    ],
  });
  assert.equal(run.gitCommit, "b203f6cb");
  assert.equal(run.tests.length, 1);
  assert.equal(run.tests[0].categorySlug, CAT);
  assert.equal(testIdOf(run.tests[0]), ID);
  assert.equal(testDirOf(run.tests[0]), TESTDIR);
  assert.equal(run.ts, Date.parse("2026-06-06T12:00:00.000Z"));
});

console.log(`\n${passed} assertions passed.`);
