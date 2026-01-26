#!/usr/bin/env node
/**
 * Koru Regression Viewer
 *
 * Shows NEW regressions - tests that broke recently (last 48 hours).
 * Focused, actionable view for catching fresh breakage.
 *
 * Usage:
 *   node scripts/show-regressions.js
 *   ./run_regression.sh --regressions
 *
 * Categorizes failures into:
 * - NEW regressions (broke in last 48 hours) - PRIORITY
 * - Long-standing failures (broke >48 hours ago) - may be architectural work
 * - Never passed (no passing snapshot found)
 */

import { readdir, readFile } from "fs/promises";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const RESULTS_DIR = join(__dirname, "../test-results");
const RECENT_THRESHOLD_HOURS = 48; // Tests broken within this time window are "new regressions"

async function loadSnapshots() {
  try {
    const files = await readdir(RESULTS_DIR);
    const snapshotFiles = files
      .filter((f) => f.endsWith(".json") && f !== "latest.json")
      .sort() // Chronological order (ISO timestamps sort correctly)
      .reverse(); // Most recent first

    const snapshots = [];
    for (const file of snapshotFiles) {
      const content = await readFile(join(RESULTS_DIR, file), "utf-8");
      const snapshot = JSON.parse(content);
      snapshots.push({
        filename: file,
        ...snapshot,
      });
    }

    return snapshots;
  } catch (error) {
    if (error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

async function getCurrentState() {
  // Use generate-status.js to scan current test state from disk markers
  const statusJson = execSync(
    "node scripts/generate-status.js --format=json 2>&1",
    {
      cwd: join(__dirname, ".."),
      encoding: "utf-8",
    },
  );

  const statusPath = join(__dirname, "../status.json");
  const data = JSON.parse(await readFile(statusPath, "utf-8"));

  // Normalize format to match snapshot format
  if (!data.summary && data.totalTests !== undefined) {
    data.summary = {
      total: data.totalTests,
      passed: data.passedTests,
      failed: data.failedTests,
      todo: data.todoTests,
      skipped: data.skippedTests,
      broken: data.brokenTests,
      untested: data.untestedTests,
      passRate:
        data.totalTests > 0
          ? ((data.passedTests / data.totalTests) * 100).toFixed(1)
          : "0.0",
    };
    data.timestamp = data.generatedAt;
    data.gitCommit = "current";
  }

  return data;
}

function formatTimestamp(iso) {
  const date = new Date(iso);
  return date.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  });
}

function formatDuration(milliseconds) {
  const hours = Math.floor(milliseconds / (1000 * 60 * 60));
  const days = Math.floor(hours / 24);

  if (days > 0) {
    return `~${days} day${days > 1 ? "s" : ""}`;
  } else if (hours > 0) {
    return `~${hours} hour${hours > 1 ? "s" : ""}`;
  } else {
    return "<1 hour";
  }
}

/**
 * Find when a test last passed by searching backwards through snapshots.
 * Matches on test.directory alone since it's unique across the suite
 * (tests are numbered with their subcategory prefix, e.g., 010_001_hello_world).
 */
function findLastPassingState(testDirectory, categorySlug, snapshots) {
  for (let i = 0; i < snapshots.length; i++) {
    const snapshot = snapshots[i];

    // Search all categories for this test directory
    // (directory is unique due to numbering scheme)
    for (const category of snapshot.categories || []) {
      for (const test of category.tests || []) {
        if (test.directory === testDirectory) {
          if (test.status === "success") {
            return {
              snapshot: snapshot,
              snapshotsAgo: i,
              test: test,
            };
          }
          // Found test but not passing - keep searching older snapshots
          break;
        }
      }
    }
  }

  return null; // Never found a passing state
}

async function main() {
  console.log("Loading current test state...");
  const currentState = await getCurrentState();

  console.log("Loading snapshots...");
  const snapshots = await loadSnapshots();

  if (snapshots.length === 0) {
    console.log("\x1b[33m⚠ No snapshots found\x1b[0m");
    console.log("Run a full test suite first: ./run_regression.sh");
    process.exit(1);
  }

  console.log(`Found ${snapshots.length} snapshot(s)`);
  console.log("");

  // Collect all currently-failing tests
  const failingTests = [];
  for (const category of currentState.categories || []) {
    for (const test of category.tests || []) {
      if (test.status === "failure") {
        failingTests.push({
          directory: test.directory,
          categorySlug: category.slug,
          categoryName: category.name,
          failureReason: test.failureReason || "unknown",
        });
      }
    }
  }

  if (failingTests.length === 0) {
    console.log("═══════════════════════════════════════════════════════════");
    console.log("🎉 NO FAILURES - All tests passing!");
    console.log("═══════════════════════════════════════════════════════════");
    process.exit(0);
  }

  // For each failing test, find when it last passed
  const recentRegressions = [];
  const longStandingFailures = [];
  const neverPassed = [];

  for (const failingTest of failingTests) {
    const lastPassing = findLastPassingState(
      failingTest.directory,
      failingTest.categorySlug,
      snapshots,
    );

    if (lastPassing) {
      const timeSinceBroke =
        Date.now() - new Date(lastPassing.snapshot.timestamp).getTime();
      const hoursSinceBroke = timeSinceBroke / (1000 * 60 * 60);
      const regression = {
        ...failingTest,
        lastPassedAt: lastPassing.snapshot.timestamp,
        lastPassedCommit: lastPassing.snapshot.gitCommit,
        snapshotsAgo: lastPassing.snapshotsAgo,
        timeSinceBroke: timeSinceBroke,
        // Breaking commit is the NEXT snapshot after the last passing one
        breakingCommit:
          lastPassing.snapshotsAgo > 0
            ? snapshots[lastPassing.snapshotsAgo - 1].gitCommit
            : "current",
      };

      if (hoursSinceBroke < RECENT_THRESHOLD_HOURS) {
        recentRegressions.push(regression);
      } else {
        longStandingFailures.push(regression);
      }
    } else {
      neverPassed.push(failingTest);
    }
  }

  // Sort by recency (most recently broken first)
  recentRegressions.sort((a, b) => a.snapshotsAgo - b.snapshotsAgo);
  longStandingFailures.sort((a, b) => a.snapshotsAgo - b.snapshotsAgo);
  neverPassed.sort((a, b) => a.directory.localeCompare(b.directory));

  // Display results
  console.log("═══════════════════════════════════════════════════════════");
  console.log("NEW REGRESSIONS - Recently broken tests");
  console.log("═══════════════════════════════════════════════════════════");
  console.log("");
  console.log(`Currently failing: \x1b[31m${failingTests.length} tests\x1b[0m`);
  if (recentRegressions.length > 0) {
    console.log(
      `NEW regressions: \x1b[1m\x1b[31m${recentRegressions.length} tests\x1b[0m (broke in last ${RECENT_THRESHOLD_HOURS} hours)`,
    );
  }
  console.log("");

  // Show recent regressions (highest priority)
  if (recentRegressions.length > 0) {
    console.log(`\x1b[1m🔥 NEW REGRESSIONS\x1b[0m (most recent first):`);
    console.log("");

    for (const reg of recentRegressions) {
      // Extra emphasis for tests that just broke in the last snapshot
      const justBroke =
        reg.snapshotsAgo === 0 ? " \x1b[1m\x1b[41m JUST BROKE \x1b[0m" : "";
      console.log(`\x1b[31m❌ ${reg.directory}\x1b[0m${justBroke}`);
      console.log(
        `   Last passed: ${formatTimestamp(reg.lastPassedAt)} (commit ${reg.lastPassedCommit})`,
      );
      console.log(
        `   Broken for: ${reg.snapshotsAgo + 1} snapshot${reg.snapshotsAgo > 0 ? "s" : ""} (${formatDuration(reg.timeSinceBroke)})`,
      );
      console.log(`   Failure: ${reg.failureReason}`);
      if (reg.breakingCommit !== "current") {
        console.log(`   \x1b[1mBreaking commit: ${reg.breakingCommit}\x1b[0m`);
      }
      console.log("");
    }
  }

  // Show long-standing failures (lower priority - might be architectural work)
  if (longStandingFailures.length > 0) {
    console.log(
      `\x1b[1m📅 LONG-STANDING FAILURES\x1b[0m (broke >${RECENT_THRESHOLD_HOURS} hours ago - may indicate architectural changes):`,
    );
    console.log("");

    for (const failure of longStandingFailures) {
      console.log(`\x1b[33m⚠️  ${failure.directory}\x1b[0m`);
      console.log(
        `   Last passed: ${formatTimestamp(failure.lastPassedAt)} (commit ${failure.lastPassedCommit})`,
      );
      console.log(
        `   Broken for: ${failure.snapshotsAgo + 1} snapshots (${formatDuration(failure.timeSinceBroke)})`,
      );
      console.log(`   Failure: ${failure.failureReason}`);
      console.log("");
    }
  }

  // Show tests that never passed
  if (neverPassed.length > 0) {
    console.log(`\x1b[1m🆕 NEVER PASSED\x1b[0m (${neverPassed.length} tests):`);
    console.log("");

    for (const test of neverPassed) {
      console.log(
        `   \x1b[33m❔\x1b[0m ${test.directory} (${test.failureReason})`,
      );
    }
    console.log("");
  }

  // Summary and recommendations
  console.log("═══════════════════════════════════════════════════════════");
  console.log("\x1b[1mRECOMMENDATIONS:\x1b[0m");
  console.log("");

  if (recentRegressions.length > 0) {
    const mostRecent = recentRegressions[0];
    console.log(
      `\x1b[1m🔥 PRIORITY: Fix NEW regressions (${recentRegressions.length} tests)\x1b[0m`,
    );
    console.log(`   Start with: ${mostRecent.directory}`);
    console.log(
      `   Use git bisect between ${mostRecent.lastPassedCommit} (good) and ${mostRecent.breakingCommit} (bad)`,
    );
    console.log("");
  }

  if (longStandingFailures.length > 0) {
    console.log(
      `📅 Long-standing failures (${longStandingFailures.length} tests)`,
    );
    console.log(
      "   May indicate ongoing architectural changes - lower priority",
    );
    console.log("");
  }

  if (neverPassed.length > 0) {
    console.log(`🆕 Never-passed tests (${neverPassed.length} tests)`);
    console.log("   Might be new features or test setup issues");
    console.log("");
  }

  // Exit with error if NEW regressions exist (focus on recent breakage)
  if (recentRegressions.length > 0) {
    console.log(
      `\x1b[31m⚠️  ${recentRegressions.length} NEW regression${recentRegressions.length > 1 ? "s" : ""} need attention!\x1b[0m`,
    );
    process.exit(1);
  } else if (longStandingFailures.length > 0 || neverPassed.length > 0) {
    console.log(
      `\x1b[33m⚠️  No NEW regressions, but ${longStandingFailures.length + neverPassed.length} old failure${longStandingFailures.length + neverPassed.length > 1 ? "s" : ""} remain\x1b[0m`,
    );
    process.exit(1);
  } else {
    // No failures at all (shouldn't reach here due to earlier check)
    process.exit(0);
  }
}

main().catch((error) => {
  console.error("\x1b[31mError:\x1b[0m", error.message);
  process.exit(1);
});
