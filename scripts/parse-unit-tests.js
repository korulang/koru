#!/usr/bin/env node
/**
 * Koru Unit Test Parser
 *
 * Parses `zig build test` output and extracts per-suite pass/fail counts.
 * Saves results to test-results/unit-tests.json for inclusion in status reports.
 */

import { readFile, writeFile, mkdir } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const RESULTS_DIR = join(__dirname, '../test-results');

async function parseUnitTests(logPath) {
	const content = await readFile(logPath, 'utf-8');

	// Use a Map to deduplicate suites by name
	const suiteMap = new Map();
	let totalPassed = 0;
	let totalFailed = 0;
	let totalCompileErrors = 0;

	// Parse the Build Summary section at the end
	// Example: "Build Summary: 22/77 steps succeeded; 29 failed; 91/112 tests passed; 21 failed; 8 leaked"
	const summaryMatch = content.match(
		/Build Summary:.*?(\d+)\/(\d+) tests passed(?:; (\d+) failed)?/
	);

	if (summaryMatch) {
		totalPassed = parseInt(summaryMatch[1], 10);
		const totalTests = parseInt(summaryMatch[2], 10);
		totalFailed = summaryMatch[3] ? parseInt(summaryMatch[3], 10) : totalTests - totalPassed;
	}

	// Parse individual test suite results
	// Example: "+- run test flow_parser_tests 3/19 passed, 16 failed"
	// Example: "+- run test lexer_tests 3/4 passed, 1 failed"
	// Example: "+- run test phantom_checker_integration_tests 2/3 passed, 1 failed"
	const suitePattern = /\+- run test (\S+)\s+(\d+)\/(\d+) passed(?:, (\d+) failed)?/g;
	let match;

	while ((match = suitePattern.exec(content)) !== null) {
		const name = match[1];
		const passed = parseInt(match[2], 10);
		const total = parseInt(match[3], 10);
		const failed = match[4] ? parseInt(match[4], 10) : total - passed;

		// Only keep the first occurrence (or update if this has more info)
		if (!suiteMap.has(name)) {
			suiteMap.set(name, {
				name,
				passed,
				failed,
				total,
				status: failed > 0 ? 'failure' : 'success'
			});
		}
	}

	// Parse compile failures (transitive failures)
	// Example: "+- run test tap_collector_tests transitive failure"
	// Example: "|  +- compile test tap_collector_tests Debug native 3 errors"
	const compileFailPattern = /\+- compile test (\S+) Debug native (\d+) errors?/g;

	while ((match = compileFailPattern.exec(content)) !== null) {
		const name = match[1];
		const errorCount = parseInt(match[2], 10);

		// Only add if we don't already have this suite
		if (!suiteMap.has(name)) {
			suiteMap.set(name, {
				name,
				passed: 0,
				failed: 0,
				total: 0,
				compileErrors: errorCount,
				status: 'compile_error'
			});
			totalCompileErrors++;
		}
	}

	// Convert map to sorted array
	const suites = Array.from(suiteMap.values()).sort((a, b) => a.name.localeCompare(b.name));

	const result = {
		timestamp: new Date().toISOString(),
		summary: {
			passed: totalPassed,
			failed: totalFailed,
			compileErrors: totalCompileErrors,
			total: totalPassed + totalFailed,
			suiteCount: suites.length,
			status: totalFailed > 0 || totalCompileErrors > 0 ? 'failure' : 'success'
		},
		suites
	};

	// Ensure results directory exists
	await mkdir(RESULTS_DIR, { recursive: true });

	// Write results
	const outputPath = join(RESULTS_DIR, 'unit-tests.json');
	await writeFile(outputPath, JSON.stringify(result, null, 2));

	console.log(
		`✓ Unit test results: ${totalPassed} passed, ${totalFailed} failed, ${totalCompileErrors} compile errors`
	);

	return result;
}

// Main
const logPath = process.argv[2];
if (!logPath) {
	console.error('Usage: parse-unit-tests.js <log-file>');
	process.exit(1);
}

parseUnitTests(logPath).catch((err) => {
	console.error('Error parsing unit tests:', err.message);
	process.exit(1);
});
