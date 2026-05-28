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

	return { passed, failed, skipped, leaked, total };
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
				totalFailed > 0 || totalCompileErrors > 0 || totalLeaked > 0 ? 'failure' : 'success'
		},
		suites
	};

	await mkdir(RESULTS_DIR, { recursive: true });

	const outputPath = join(RESULTS_DIR, 'unit-tests.json');
	await writeFile(outputPath, JSON.stringify(result, null, 2));

	const skipPart = totalSkipped > 0 ? `, ${totalSkipped} skipped` : '';
	const leakPart = totalLeaked > 0 ? `, ${totalLeaked} leaked` : '';
	console.log(
		`✓ Unit test results: ${totalPassed} passed, ${totalFailed} failed${skipPart}${leakPart}, ${totalCompileErrors} compile errors`
	);

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
