// Test the pure core of the Cordial world-model faucet: verdict + card mapping.
// No fs, no network. Run: `bun wm/producer/cordial.test.ts`.
//
// The guarantees pinned here:
//   - verdict is `regression` iff a green→red flip happened this run, else `red`
//     iff anything is failing, else `green`
//   - each flip becomes ONE `koru.regression.test` card carrying the NEW status
//     and the test id + reason in the note
//   - the run always emits exactly ONE trailing `test-health` verdict card
//   - stateToPrev round-trips the local store into the shape computeFlips wants

import assert from "node:assert/strict";
import { verdictOf, flipCard, verdictCard, cardsFor, stateToPrev, type RunSummary } from "./cordial.ts";
import type { FlipSignal } from "./regression.ts";

const CAT = "000_CORE_LANGUAGE/010_BASIC_SYNTAX";
const ID = `${CAT}/010_000_hello_world_koru`;

function mkFlip(o: { type: "regression" | "recovery"; testId?: string; reason?: string }): FlipSignal {
  const direction = o.type === "regression" ? "green->red" : "red->green";
  return {
    source: "koru.regression",
    type: o.type,
    ts: 1000,
    value: o.type === "regression" ? 1 : 0,
    tags: { testId: o.testId ?? ID, direction, mustRun: true, category: CAT },
    payload: {
      testId: o.testId ?? ID,
      name: "hello",
      testDir: `tests/regression/${o.testId ?? ID}`,
      protectedPaths: [`tests/regression/${o.testId ?? ID}`],
      gitCommit: "red2",
      prevGreenCommit: "green1",
      failureReason: o.reason ?? "",
    },
  };
}

const SUMMARY: RunSummary = { inScope: 1012, passed: 916, failed: 85, passRate: "90.5" };

let passed = 0;
function ok(name: string, fn: () => void) {
  fn();
  passed++;
  console.log(`  ✓ ${name}`);
}

console.log("verdictOf:");
ok("green when nothing failed and no regression", () => {
  assert.equal(verdictOf({ inScope: 10, passed: 10, failed: 0, passRate: "100" }, 0), "green");
});
ok("red when failing but no NEW regression", () => {
  assert.equal(verdictOf(SUMMARY, 0), "red");
});
ok("regression when a green→red flip happened, even amid other reds", () => {
  assert.equal(verdictOf(SUMMARY, 3), "regression");
});

console.log("\nflipCard:");
ok("regression flip → card value 'failure' with direction + id + reason in note", () => {
  const c = flipCard(mkFlip({ type: "regression", reason: "exit 1: boom" }));
  assert.equal(c.name, "koru.regression.test");
  assert.equal(c.value, "failure");
  assert.equal(c.source, "koru.regression");
  assert.equal(c.repo, "koru");
  assert.ok(c.note.includes("green->red"));
  assert.ok(c.note.includes(ID));
  assert.ok(c.note.includes("exit 1: boom"));
});
ok("recovery flip → card value 'success'", () => {
  const c = flipCard(mkFlip({ type: "recovery" }));
  assert.equal(c.value, "success");
  assert.ok(c.note.includes("red->green"));
});

console.log("\nverdictCard:");
ok("carries counts + commit and names the regressed count when >0", () => {
  const c = verdictCard("regression", SUMMARY, 2, "abcd1234");
  assert.equal(c.name, "test-health");
  assert.equal(c.value, "regression");
  assert.ok(c.note.includes("916/1012 green"));
  assert.ok(c.note.includes("85 red"));
  assert.ok(c.note.includes("2 REGRESSED"));
  assert.ok(c.note.includes("@abcd1234"));
});

console.log("\ncardsFor:");
ok("N flips → N test cards + exactly ONE trailing verdict card", () => {
  const flips = [mkFlip({ type: "regression", testId: `${CAT}/a` }), mkFlip({ type: "recovery", testId: `${CAT}/b` })];
  const { cards, verdict } = cardsFor(flips, SUMMARY, "abcd1234");
  assert.equal(cards.length, 3);
  assert.equal(verdict, "regression"); // one of the flips is a green→red
  assert.equal(cards[0].name, "koru.regression.test");
  assert.equal(cards[1].name, "koru.regression.test");
  assert.equal(cards[2].name, "test-health", "verdict card is always last");
});
ok("no flips → just the verdict card", () => {
  const { cards, verdict } = cardsFor([], { inScope: 10, passed: 10, failed: 0, passRate: "100" }, "c0");
  assert.equal(cards.length, 1);
  assert.equal(cards[0].name, "test-health");
  assert.equal(verdict, "green");
});

console.log("\nstateToPrev:");
ok("round-trips the local store into computeFlips' prior shape", () => {
  const m = stateToPrev({ [ID]: { status: "success", commit: "green1" } });
  assert.equal(m.size, 1);
  assert.deepEqual(m.get(ID), { testId: ID, status: "success", lastSeenCommit: "green1" });
});

console.log(`\n${passed} assertions passed.`);
