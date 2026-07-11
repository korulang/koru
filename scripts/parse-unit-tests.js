#!/usr/bin/env node
/**
 * Koru Unit Test Parser
 *
 * Parses `zig build test --summary all` output and extracts per-suite pass/fail/skip counts.
 * Saves results to test-results/unit-tests.json for inclusion in status reports.
 */

import { readFile, writeFile, mkdir } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const RESULTS_DIR = join(__dirname, '../test-results');

function parseBuildSummary(content) {
	const summaryLine = content.match(/Build Summary:[^\n]*/);
	if (!summaryLine) {
		return null;
	}

	const line = summaryLine[0];
	const testsMatch = line.match(/(\d+)\/(\d+) tests passed/);
	if (!testsMatch) {
		return null;
	}

	const passed = parseInt(testsMatch[1], 10);
	const total = parseInt(testsMatch[2], 10);
	const afterTests = line.split('tests passed')[1] ?? '';

	const failedMatch = afterTests.match(/;\s*(\d+) failed/);
	const skippedMatch = afterTests.match(/;\s*(\d+) skipped/);
	const leakedMatch = afterTests.match(/;\s*(\d+) leaked/);

	const skipped = skippedMatch ? parseInt(skippedMatch[1], 10) : 0;
	const leaked = leakedMatch ? parseInt(leakedMatch[1], 10) : 0;
	const failed = failedMatch
		? parseInt(failedMatch[1], 10)
		: Math.max(0, total - passed - skipped);

	// Failed build STEPS ("79/81 steps succeeded; 1 failed") are a separate
	// tally from failed TESTS — a test binary that PANICS is a failed step
	// whose tests never reach the test tally at all. Without this signal a
	// panicking binary reads as "0 failed".
	const stepsMatch = line.match(/(\d+)\/(\d+) steps succeeded(?:;\s*(\d+) failed)?/);
	const failedSteps = stepsMatch && stepsMatch[3] ? parseInt(stepsMatch[3], 10) : 0;

	return { passed, failed, skipped, leaked, total, failedSteps };
}

async function parseUnitTests(logPath) {
	const content = await readFile(logPath, 'utf-8');

	const suiteMap = new Map();
	let totalPassed = 0;
	let totalFailed = 0;
	let totalSkipped = 0;
	let totalLeaked = 0;
	let totalCompileErrors = 0;
	let totalTests = 0;

	const summary = parseBuildSummary(content);
	if (summary) {
		totalPassed = summary.passed;
		totalFailed = summary.failed;
		totalSkipped = summary.skipped;
		totalLeaked = summary.leaked;
		totalTests = summary.total;
	}

	// --summary all format: "+- run test visitor_emitter_tests 9 passed 2 skipped"
	const summaryAllPattern = /\+- run test (\S+) (\d+) passed(?: (\d+) skipped)?/g;
	let match;
	while ((match = summaryAllPattern.exec(content)) !== null) {
		const name = match[1];
		const passed = parseInt(match[2], 10);
		const skipped = match[3] ? parseInt(match[3], 10) : 0;
		const total = passed + skipped;

		if (!suiteMap.has(name)) {
			suiteMap.set(name, {
				name,
				passed,
				failed: 0,
				skipped,
				total,
				status: 'success'
			});
		}
	}

	// Legacy fraction format: "+- run test flow_parser_tests 3/19 passed, 16 failed"
	const legacySuitePattern = /\+- run test (\S+)\s+(\d+)\/(\d+) passed(?:, (\d+) failed)?/g;
	while ((match = legacySuitePattern.exec(content)) !== null) {
		const name = match[1];
		if (suiteMap.has(name)) continue;

		const passed = parseInt(match[2], 10);
		const total = parseInt(match[3], 10);
		const failed = match[4] ? parseInt(match[4], 10) : total - passed;

		suiteMap.set(name, {
			name,
			passed,
			failed,
			skipped: Math.max(0, total - passed - failed),
			total,
			status: failed > 0 ? 'failure' : 'success'
		});
	}

	// CRASHED suites: a test binary that panicked mid-run prints
	// "+- run test <name> failure" with NO counts — neither pattern above
	// matches, and Zig's "N/M tests passed" tally does not count the dead
	// binary's tests as failed. Without this branch a panicking suite
	// VANISHES from the JSON and the summary reads "0 failed, success"
	// while the build is red.
	const crashedSuitePattern = /\+- run test (\S+) failure/g;
	while ((match = crashedSuitePattern.exec(content)) !== null) {
		const name = match[1];
		if (suiteMap.has(name)) {
			const suite = suiteMap.get(name);
			suite.status = 'crashed';
			if (suite.failed === 0) {
				suite.failed = 1; // at least the test that died
				suite.total += 1;
			}
		} else {
			suiteMap.set(name, {
				name,
				passed: 0,
				failed: 1,
				skipped: 0,
				total: 1,
				status: 'crashed'
			});
		}
	}

	// Name the tests that died and why:
	// "error: while executing test '<full name>', the following command terminated with signal N"
	// plus the "thread N panic: <message>" line above it.
	const crashedTests = [];
	const executingPattern = /error: while executing test '([^']+)'/g;
	while ((match = executingPattern.exec(content)) !== null) {
		crashedTests.push(match[1]);
	}
	const panicMatch = content.match(/thread \d+ panic: ([^\n]*)/);

	// Compile failures: "+- compile test tap_collector_tests Debug native 3 errors"
	const compileFailPattern = /\+- compile test (\S+) Debug native (\d+) errors?/g;
	while ((match = compileFailPattern.exec(content)) !== null) {
		const name = match[1];
		const errorCount = parseInt(match[2], 10);

		if (!suiteMap.has(name)) {
			suiteMap.set(name, {
				name,
				passed: 0,
				failed: 0,
				skipped: 0,
				total: 0,
				compileErrors: errorCount,
				status: 'compile_error'
			});
			totalCompileErrors++;
		}
	}

	const suites = Array.from(suiteMap.values()).sort((a, b) => a.name.localeCompare(b.name));

	if (!summary && suites.length > 0) {
		for (const suite of suites) {
			totalPassed += suite.passed;
			totalFailed += suite.failed;
			totalSkipped += suite.skipped;
		}
		totalTests = totalPassed + totalFailed + totalSkipped;
	}

	// A crashed suite's dead tests are invisible to Zig's test tally — fold
	// them into the failed count so the headline can never say "0 failed"
	// over a panicking binary. failedSteps is the belt to that suspender:
	// even if every text pattern here rots, a failed build step forces
	// status: failure.
	const crashedFailed = suites
		.filter((s) => s.status === 'crashed')
		.reduce((acc, s) => acc + s.failed, 0);
	totalFailed += crashedFailed;
	totalTests = Math.max(totalTests, totalPassed + totalFailed + totalSkipped);
	const failedSteps = summary ? summary.failedSteps : 0;

	const result = {
		timestamp: new Date().toISOString(),
		summary: {
			passed: totalPassed,
			failed: totalFailed,
			skipped: totalSkipped,
			leaked: totalLeaked,
			compileErrors: totalCompileErrors,
			total: totalTests || totalPassed + totalFailed + totalSkipped,
			suiteCount: suites.length,
			status:
				totalFailed > 0 || totalCompileErrors > 0 || totalLeaked > 0 || failedSteps > 0
					? 'failure'
					: 'success'
		},
		suites
	};
	if (crashedTests.length > 0) {
		result.crashedTests = crashedTests.map((name) => ({
			name,
			reason: panicMatch ? panicMatch[1] : 'terminated by signal'
		}));
	}

	await mkdir(RESULTS_DIR, { recursive: true });

	const outputPath = join(RESULTS_DIR, 'unit-tests.json');
	await writeFile(outputPath, JSON.stringify(result, null, 2));

	const skipPart = totalSkipped > 0 ? `, ${totalSkipped} skipped` : '';
	const leakPart = totalLeaked > 0 ? `, ${totalLeaked} leaked` : '';
	const mark = result.summary.status === 'failure' ? '✗' : '✓';
	console.log(
		`${mark} Unit test results: ${totalPassed} passed, ${totalFailed} failed${skipPart}${leakPart}, ${totalCompileErrors} compile errors`
	);
	for (const crashed of result.crashedTests ?? []) {
		console.log(`  ✗ CRASHED: ${crashed.name} — ${crashed.reason}`);
	}

	return result;
}

const logPath = process.argv[2];
if (!logPath) {
	console.error('Usage: parse-unit-tests.js <log-file>');
	process.exit(1);
}

parseUnitTests(logPath).catch((err) => {
	console.error('Error parsing unit tests:', err.message);
	process.exit(1);
});
