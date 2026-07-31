#!/usr/bin/env node
/**
 * Koru Test Snapshot Saver
 *
 * Captures the exact state of all regression tests after a full run.
 * Saves timestamped snapshot to test-results/ for regression detection.
 *
 * This CANNOT lie - it captures actual SUCCESS/FAILURE markers from disk.
 */

import { readdir, stat, access, writeFile, readFile, mkdir, symlink, unlink } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync, spawnSync } from 'child_process';
import { countLOC } from './count-loc.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REGRESSION_PATH = join(__dirname, '../tests/regression');
const RESULTS_DIR = join(__dirname, '../test-results');
const UNIT_TESTS_PATH = join(RESULTS_DIR, 'unit-tests.json');

// Parse command line args
const args = process.argv.slice(2);
const getArg = (name) => {
	const arg = args.find(a => a.startsWith(`--${name}=`));
	return arg ? arg.split('=')[1] : null;
};

const passed = parseInt(getArg('passed') || '0');
const total = parseInt(getArg('total') || '0');
const flags = getArg('flags') || '';
const commit = getArg('commit') || 'unknown';

async function fileExists(path) {
	try {
		await access(path);
		return true;
	} catch {
		return false;
	}
}

async function readFirstLine(path) {
	try {
		const content = await readFile(path, 'utf-8');
		return content.split('\n')[0].trim();
	} catch {
		return '';
	}
}

/**
 * Recursively find all test directories, matching bash script behavior
 * Bash: find tests/regression -mindepth 1 -type d
 *
 * categoryPath is the full hierarchy path, e.g. "000_CORE_LANGUAGE/010_BASIC_SYNTAX"
 */
// A test's entry source is any of the three facet extensions — pure-Koru
// tests have only input.k (the AoC purity flip made a whole cluster so;
// input.kz-only discovery silently dropped them from snapshots).
async function hasInputFile(dir) {
	return (await fileExists(join(dir, 'input.kz'))) ||
		(await fileExists(join(dir, 'input.k'))) ||
		(await fileExists(join(dir, 'input.kjs')));
}

async function findAllTestDirs(basePath, categoryPath = null, categorySkipped = false, categoryTodo = false, categoryTodoDesc = '', categoryBenchmark = false, categoryBenchmarkDesc = '', categorySkippedDesc = '') {
	const tests = [];
	const entries = await readdir(basePath);

	// Category-level TODO marker on this dir (propagates to all tests below).
	const ownTodo = await fileExists(join(basePath, 'TODO'));
	const ownInput = await hasInputFile(basePath);
	const ownTodoIsCategory = ownTodo && !ownInput;
	const ownTodoDesc = ownTodoIsCategory ? await readFirstLine(join(basePath, 'TODO')) : '';
	const effectiveCategoryTodo = categoryTodo || ownTodoIsCategory;
	const effectiveCategoryTodoDesc = categoryTodoDesc || ownTodoDesc;

	// Category-level SKIP marker on this dir (propagates to all tests below).
	// Previously this only tracked a boolean and reported every inherited skip
	// as the synthesised literal 'Category skipped' — never reading whatever
	// authored reason actually sat in the category's own SKIP file. Mirrors the
	// TODO/BENCHMARK propagation above so a real reason, if written, is used.
	const ownSkip = await fileExists(join(basePath, 'SKIP'));
	const ownSkipIsCategory = ownSkip && !ownInput;
	const ownSkipDesc = ownSkipIsCategory ? await readFirstLine(join(basePath, 'SKIP')) : '';
	const effectiveCategorySkipped = categorySkipped || ownSkipIsCategory;
	const effectiveCategorySkippedDesc = categorySkippedDesc || ownSkipDesc;

	// Category-level BENCHMARK marker (propagates to all tests below) — mirrors
	// run_single_test.sh / regression_lib.sh, which treat a BENCHMARK file on the
	// category dir as opting EVERY test beneath it out of the standard run (no
	// koruc invocation, no SUCCESS/FAILURE ever written). Without this mirror, a
	// category-wide BENCHMARK silently produced 14 'untested' tests instead of a
	// 'benchmark' verdict — the harness's own exclusion was invisible here.
	const ownBenchmark = await fileExists(join(basePath, 'BENCHMARK'));
	const ownBenchmarkIsCategory = ownBenchmark && !ownInput;
	const ownBenchmarkDesc = ownBenchmarkIsCategory ? await readFirstLine(join(basePath, 'BENCHMARK')) : '';
	const effectiveCategoryBenchmark = categoryBenchmark || ownBenchmarkIsCategory;
	const effectiveCategoryBenchmarkDesc = categoryBenchmarkDesc || ownBenchmarkDesc;

	for (const entry of entries) {
		if (entry === '_archive') continue;

		const fullPath = join(basePath, entry);
		const stats = await stat(fullPath);

		if (!stats.isDirectory()) continue;

		const isTestDir = /^\d+[a-z]?_/.test(entry);

		// Check for input file and markers (matching bash logic)
		const hasInput = await hasInputFile(fullPath);
		const todo = await fileExists(join(fullPath, 'TODO'));
		const skip = await fileExists(join(fullPath, 'SKIP'));
		const broken = await fileExists(join(fullPath, 'BROKEN'));
		const benchmark = await fileExists(join(fullPath, 'BENCHMARK'));

		// A TEST has input.kz (or, for stub tests, only TODO/SKIP/BROKEN/BENCHMARK
		// markers next to no input.kz). A CATEGORY has no input.kz and may carry a
		// category-level TODO/SKIP/BENCHMARK marker for its children. We
		// disambiguate by checking whether this dir contains any test-pattern
		// children — if it does, the marker here is category-level, not test-level.
		let hasTestPatternChild = false;
		if (!hasInput && (todo || skip || broken || benchmark)) {
			try {
				const children = await readdir(fullPath);
				hasTestPatternChild = children.some(c => /^\d+[a-z]?_/.test(c));
			} catch {}
		}
		const isCategoryMarker = !hasInput && (todo || skip || broken || benchmark) && hasTestPatternChild;
		const isValidTest = isTestDir && (hasInput || ((todo || skip || broken || benchmark) && !isCategoryMarker));

		if (isValidTest) {
			// This is a test directory!
			const mustRun = await fileExists(join(fullPath, 'MUST_RUN'));
			const success = await fileExists(join(fullPath, 'SUCCESS'));
			const failure = await fileExists(join(fullPath, 'FAILURE'));

			// Read reasons/descriptions from markers
			let failureReason = '';
			if (failure) {
				failureReason = await readFirstLine(join(fullPath, 'FAILURE'));
			}

			const todoDesc = todo
				? await readFirstLine(join(fullPath, 'TODO'))
				: (effectiveCategoryTodo ? effectiveCategoryTodoDesc : '');
			const skipReason = skip ? await readFirstLine(join(fullPath, 'SKIP')) : '';
			const brokenReason = broken ? await readFirstLine(join(fullPath, 'BROKEN')) : '';
			const benchmarkReason = benchmark
				? await readFirstLine(join(fullPath, 'BENCHMARK'))
				: (effectiveCategoryBenchmark ? effectiveCategoryBenchmarkDesc : '');

			// Determine status with proper precedence. BENCHMARK sits above
			// TODO/SKIP/BROKEN because that's the harness's own precedence
			// (regression_lib.sh checks BENCHMARK before TODO/SKIP): a test under a
			// benchmark category never gets a koruc invocation at all, so it can
			// never validly resolve to any of the other statuses.
			let status = 'untested';
			if (benchmark) {
				status = 'benchmark';
			} else if (effectiveCategoryBenchmark) {
				status = 'benchmark';
			} else if (todo) {
				status = 'todo';
			} else if (effectiveCategoryTodo) {
				status = 'todo';
			} else if (effectiveCategorySkipped) {
				status = 'skipped';
			} else if (skip) {
				status = 'skipped';
			} else if (broken) {
				status = 'broken';
			} else if (success && failure) {
				status = 'unknown';
			} else if (success) {
				status = 'success';
			} else if (failure) {
				status = 'failure';
			}

			tests.push({
				name: entry.replace(/^\d+_/, '').replace(/_/g, ' '),
				directory: entry,
				categorySlug: categoryPath,
				mustRun,
				status,
				failureReason,
				todoDesc,
				skipReason: effectiveCategorySkipped && !skip
					? (effectiveCategorySkippedDesc || 'Category skipped')
					: skipReason,
				// Distinct from skipReason's text (which may now carry an authored
				// reason instead of the literal 'Category skipped') — this is what
				// the category summary below actually needs to know.
				categoryLevelSkip: effectiveCategorySkipped && !skip,
				brokenReason,
				benchmarkReason
			});
		}

		// Recurse into subdirectories (matching bash recursive behavior)
		// Build full category path when entering a category directory
		const isCategoryDir = /^\d+_/.test(entry);
		const subCategoryPath = isCategoryDir
			? (categoryPath ? `${categoryPath}/${entry}` : entry)
			: categoryPath;
		const subTests = await findAllTestDirs(
			fullPath,
			subCategoryPath,
			effectiveCategorySkipped,
			effectiveCategoryTodo,
			effectiveCategoryTodoDesc,
			effectiveCategoryBenchmark,
			effectiveCategoryBenchmarkDesc,
			effectiveCategorySkippedDesc
		);
		tests.push(...subTests);
	}

	return tests;
}

async function loadUnitTests() {
	try {
		const content = await readFile(UNIT_TESTS_PATH, 'utf-8');
		return JSON.parse(content);
	} catch {
		// No unit test results available
		return null;
	}
}

async function saveSnapshot() {
	try {
		// Ensure results directory exists
		await mkdir(RESULTS_DIR, { recursive: true });

		// Load unit test results if available
		const unitTests = await loadUnitTests();

		// Count lines of code per language across tracked files. Fail-soft: a
		// counting error must never block the test snapshot from saving. We
		// only persist the language buckets on the snapshot — excluded counts
		// are logged below for debug visibility but not surfaced on /status.
		let loc = null;
		let locExcludedFiles = 0;
		let locExcludedLines = 0;
		try {
			const result = await countLOC();
			loc = result.buckets;
			locExcludedFiles = result.excludedFiles;
			locExcludedLines = result.excludedLines;
		} catch (err) {
			console.log(`  ⚠ LOC count failed: ${err.message}`);
		}

		// Scan all tests recursively (matching bash script behavior)
		const allTests = await findAllTestDirs(REGRESSION_PATH);
		allTests.sort((a, b) => a.directory.localeCompare(b.directory));

		// Group tests by category for structured output
		const categoryMap = new Map();
		for (const test of allTests) {
			if (!categoryMap.has(test.categorySlug)) {
				categoryMap.set(test.categorySlug, []);
			}
			categoryMap.get(test.categorySlug).push(test);
		}

		const categories = Array.from(categoryMap.entries())
				.filter(([slug]) => slug !== null) // Filter out any tests without valid categories
				.map(([slug, tests]) => ({
				name: slug.replace(/^\d+_/, '').replace(/_/g, ' '),
				slug,
			categorySkipped: tests.some(t => t.categoryLevelSkip),
			tests
		}));

		categories.sort((a, b) => a.slug.localeCompare(b.slug));

		// Calculate aggregate counts
		const passedTests = allTests.filter(t => t.status === 'success').length;
		const failedTests = allTests.filter(t => t.status === 'failure').length;
		const todoTests = allTests.filter(t => t.status === 'todo').length;
		const skippedTests = allTests.filter(t => t.status === 'skipped').length;
		const brokenTests = allTests.filter(t => t.status === 'broken').length;
		const benchmarkTests = allTests.filter(t => t.status === 'benchmark').length;
		const untestedTests = allTests.filter(t => t.status === 'untested').length;
		const totalTests = allTests.length;
		// inScope: tests that should be executed and contribute to pass rate.
		// Excludes TODO/SKIP/BROKEN/BENCHMARK (explicitly sidelined — a benchmark
		// never gets a koruc invocation, so it can never carry a pass/fail verdict
		// either). Includes untested (those *should* have run — if they didn't
		// it's a real gap).
		const inScopeTests = totalTests - todoTests - skippedTests - brokenTests - benchmarkTests;

		// Create snapshot
		const timestamp = new Date().toISOString();
		const snapshot = {
			timestamp,
			gitCommit: commit,
			commandFlags: flags,
			summary: {
				total: totalTests,
				inScope: inScopeTests,
				passed: passedTests,
				failed: failedTests,
				todo: todoTests,
				skipped: skippedTests,
				broken: brokenTests,
				benchmark: benchmarkTests,
				untested: untestedTests,
				passRate: inScopeTests > 0 ? ((passedTests / inScopeTests) * 100).toFixed(1) : '0.0'
			},
			categories,
			unitTests: unitTests ? {
				summary: unitTests.summary,
				suites: unitTests.suites
			} : null,
			loc
		};

		// Save timestamped snapshot
		const filename = timestamp.replace(/:/g, '-').replace(/\..+$/, '') + '.json';
		const snapshotPath = join(RESULTS_DIR, filename);
		await writeFile(snapshotPath, JSON.stringify(snapshot, null, 2));

		// Update latest.json symlink
		const latestPath = join(RESULTS_DIR, 'latest.json');
		try {
			await unlink(latestPath);
		} catch {
			// Ignore if doesn't exist
		}
		await symlink(filename, latestPath);

		console.log(`✓ Saved test snapshot: ${filename}`);
		console.log(`  Regression: ${passedTests}/${inScopeTests} in-scope passed (${snapshot.summary.passRate}%)  [${totalTests} total on disk]`);
		console.log(`  Failed: ${failedTests}, TODO: ${todoTests}, Skipped: ${skippedTests}, Broken: ${brokenTests}, Benchmark: ${benchmarkTests}`);
		if (unitTests) {
			const us = unitTests.summary;
			const skipPart = us.skipped > 0 ? `, ${us.skipped} skipped` : '';
			console.log(
				`  Unit tests: ${us.passed}/${us.total} passed${skipPart}, ${us.compileErrors} compile errors`
			);
		}
		if (loc) {
			const parts = Object.entries(loc)
				.sort(([, a], [, b]) => b.lines - a.lines)
				.map(([lang, info]) => `${lang} ${info.lines.toLocaleString()}`);
			console.log(`  LOC: ${parts.join(', ')}`);
			if (locExcludedLines > 0) {
				console.log(`  LOC excluded (generated): ${locExcludedLines.toLocaleString()} lines across ${locExcludedFiles} files`);
			}
		}

		pushToBrain(snapshot);

	} catch (error) {
		console.error('Error saving snapshot:', error);
		process.exit(1);
	}
}

// Push the snapshot to the koru brain via ctx. Local dev hits the local Convex
// backend through ~/.6digit/satellite.json; CI sets CTX_USER_KEY +
// CTX_CONVEX_URL + CTX_BRAIN_ID and skips the file. Fail-soft — a missing or
// broken ctx never fails the test run.
function pushToBrain(snapshot) {
	if (process.env.KORU_SKIP_BRAIN_PUSH) return;

	const s = snapshot.summary;
	const summary =
		`${s.passed}/${s.inScope} passed (${s.passRate}%) · ` +
		`failed: ${s.failed}, todo: ${s.todo}, broken: ${s.broken} · ` +
		`${snapshot.gitCommit} · ${snapshot.timestamp}`;

	const patch = JSON.stringify({ summary, data: snapshot });

	const result = spawnSync('ctx', ['patch', 'test-run', patch], {
		stdio: ['ignore', 'pipe', 'pipe'],
		encoding: 'utf-8'
	});

	if (result.error) {
		if (result.error.code === 'ENOENT') {
			console.log(`  (ctx not on PATH — skipping brain push)`);
		} else {
			console.log(`  ⚠ Brain push failed: ${result.error.message}`);
		}
		return;
	}
	if (result.status !== 0) {
		const msg = (result.stderr || '').trim().split('\n')[0] || `exit ${result.status}`;
		console.log(`  ⚠ Brain push failed: ${msg}`);
		return;
	}
	console.log(`  ✓ Pushed snapshot to brain (*test-run)`);
}

saveSnapshot();
