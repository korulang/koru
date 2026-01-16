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
import { execSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REGRESSION_PATH = join(__dirname, '../tests/regression');
const RESULTS_DIR = join(__dirname, '../test-results');

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
async function findAllTestDirs(basePath, categoryPath = null, categorySkipped = false) {
	const tests = [];
	const entries = await readdir(basePath);

	for (const entry of entries) {
		const fullPath = join(basePath, entry);
		const stats = await stat(fullPath);

		if (!stats.isDirectory()) continue;

		const isTestDir = /^\d+[a-z]?_/.test(entry);

		// Check for input file and markers (matching bash logic)
		const hasInput = await fileExists(join(fullPath, 'input.kz'));
		const todo = await fileExists(join(fullPath, 'TODO'));
		const skip = await fileExists(join(fullPath, 'SKIP'));
		const broken = await fileExists(join(fullPath, 'BROKEN'));

		// Match bash script filtering - only count valid tests
		// if [ ! -f "$test_dir/input.kz" ] && [ ! -f "$test_dir/TODO" ] && [ ! -f "$test_dir/SKIP" ] && [ ! -f "$test_dir/BROKEN" ]; then continue; fi
		const isValidTest = isTestDir && (hasInput || todo || skip || broken);

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

			const todoDesc = todo ? await readFirstLine(join(fullPath, 'TODO')) : '';
			const skipReason = skip ? await readFirstLine(join(fullPath, 'SKIP')) : '';
			const brokenReason = broken ? await readFirstLine(join(fullPath, 'BROKEN')) : '';

			// Determine status with proper precedence (matching bash script)
			let status = 'untested';
			if (todo) {
				status = 'todo';
			} else if (categorySkipped) {
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
				skipReason: categorySkipped && !skip ? 'Category skipped' : skipReason,
				brokenReason
			});
		}

		// Recurse into subdirectories (matching bash recursive behavior)
		// Build full category path when entering a category directory
		const isCategoryDir = /^\d+_/.test(entry);
		const subCategorySkipped = categorySkipped || await fileExists(join(fullPath, 'SKIP'));
		const subCategoryPath = isCategoryDir
			? (categoryPath ? `${categoryPath}/${entry}` : entry)
			: categoryPath;
		const subTests = await findAllTestDirs(
			fullPath,
			subCategoryPath,
			subCategorySkipped
		);
		tests.push(...subTests);
	}

	return tests;
}

async function saveSnapshot() {
	try {
		// Ensure results directory exists
		await mkdir(RESULTS_DIR, { recursive: true });

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
			categorySkipped: tests.some(t => t.skipReason === 'Category skipped'),
			tests
		}));

		categories.sort((a, b) => a.slug.localeCompare(b.slug));

		// Calculate aggregate counts
		const passedTests = allTests.filter(t => t.status === 'success').length;
		const failedTests = allTests.filter(t => t.status === 'failure').length;
		const todoTests = allTests.filter(t => t.status === 'todo').length;
		const skippedTests = allTests.filter(t => t.status === 'skipped').length;
		const brokenTests = allTests.filter(t => t.status === 'broken').length;
		const untestedTests = allTests.filter(t => t.status === 'untested').length;
		const totalTests = allTests.length;

		// Create snapshot
		const timestamp = new Date().toISOString();
		const snapshot = {
			timestamp,
			gitCommit: commit,
			commandFlags: flags,
			summary: {
				total: totalTests,
				passed: passedTests,
				failed: failedTests,
				todo: todoTests,
				skipped: skippedTests,
				broken: brokenTests,
				untested: untestedTests,
				passRate: totalTests > 0 ? ((passedTests / totalTests) * 100).toFixed(1) : '0.0'
			},
			categories
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
		console.log(`  ${passedTests}/${totalTests} passed (${snapshot.summary.passRate}%)`);
		console.log(`  Failed: ${failedTests}, TODO: ${todoTests}, Skipped: ${skippedTests}, Broken: ${brokenTests}`);

	} catch (error) {
		console.error('Error saving snapshot:', error);
		process.exit(1);
	}
}

saveSnapshot();
