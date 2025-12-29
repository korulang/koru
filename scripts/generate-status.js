#!/usr/bin/env node
/**
 * Koru Regression Test Status Generator
 *
 * Scans tests/regression/ for test status markers and generates:
 * - status.json (for website/API consumption)
 * - Beautiful CLI output (when --format=cli)
 *
 * The regression tests are the source of truth - they cannot lie.
 */

import { readdir, stat, access, writeFile, readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REGRESSION_PATH = join(__dirname, '../tests/regression');
const OUTPUT_JSON_PATH = join(__dirname, '../status.json');

// Parse command line args
const args = process.argv.slice(2);
const format = args.find(arg => arg.startsWith('--format='))?.split('=')[1] || 'json';

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
 * Recursively gather all test cases with full hierarchy paths.
 * categorySlugPath is the full hierarchy, e.g. "000_CORE_LANGUAGE/010_BASIC_SYNTAX"
 */
async function getTestCases(categoryPath, categorySlugPath, categorySkipped = false) {
	const tests = [];
	const entries = await readdir(categoryPath);

	for (const entry of entries) {
		const testPath = join(categoryPath, entry);
		const stats = await stat(testPath);

		// Skip non-test directories (category dirs with README/SPEC)
		// Match test directories like "608_test_name" or "608b_test_name" (with optional letter suffix)
		if (stats.isDirectory() && /^\d+[a-z]?_/.test(entry)) {
			// Check for input file and markers
			const hasInput = await fileExists(join(testPath, 'input.kz'));
			const mustRun = await fileExists(join(testPath, 'MUST_RUN'));
			const success = await fileExists(join(testPath, 'SUCCESS'));
			const failure = await fileExists(join(testPath, 'FAILURE'));
			const todo = await fileExists(join(testPath, 'TODO'));
			const skip = await fileExists(join(testPath, 'SKIP'));
			const broken = await fileExists(join(testPath, 'BROKEN'));

			// CRITICAL: Match bash script filtering (run_regression.sh:257-260)
			// Only count this directory as a test if it has input.kz OR any marker
			if (!hasInput && !todo && !skip && !broken) {
				// This might be a subcategory - recurse into it
				// Build full hierarchy path: parent/child
				const subCategorySkipped = categorySkipped || skip;
				const subCategorySlugPath = categorySlugPath ? `${categorySlugPath}/${entry}` : entry;
				const subTests = await getTestCases(testPath, subCategorySlugPath, subCategorySkipped);
				tests.push(...subTests);
				continue;
			}

			// Read failure reason if present
			let failureReason = '';
			if (failure) {
				failureReason = await readFirstLine(join(testPath, 'FAILURE'));
			}

			// Read descriptions from marker files
			const todoDesc = todo ? await readFirstLine(join(testPath, 'TODO')) : '';
			const skipReason = skip ? await readFirstLine(join(testPath, 'SKIP')) : '';
			const brokenReason = broken ? await readFirstLine(join(testPath, 'BROKEN')) : '';

			// Determine status with proper precedence (matches bash script order)
			// 1. TODO (highest priority - run_regression.sh:302-309)
			// 2. Category-level SKIP (run_regression.sh:311-316)
			// 3. Individual SKIP (run_regression.sh:318-326)
			// 4. BROKEN (run_regression.sh:328-338)
			// 5. Test results (SUCCESS/FAILURE)
			let status = 'untested';
			if (todo) {
				status = 'todo';
			} else if (categorySkipped) {
				// Category is skipped - mark this test as skipped
				status = 'skipped';
			} else if (skip) {
				status = 'skipped';
			} else if (broken) {
				status = 'broken';
			} else if (success && failure) {
				status = 'unknown'; // Both exist - weird state
			} else if (success) {
				status = 'success';
			} else if (failure) {
				status = 'failure';
			}

			tests.push({
				name: entry.replace(/^\d+[a-z]?_/, '').replace(/_/g, ' '),
				directory: entry,
				categorySlug: categorySlugPath,
				mustRun,
				todo,
				skip: skip || categorySkipped, // Mark as skipped if category is skipped
				broken,
				status,
				failureReason,
				todoDesc,
				skipReason: categorySkipped && !skip ? 'Category skipped' : skipReason,
				brokenReason
			});
		}
	}

	return tests.sort((a, b) => a.directory.localeCompare(b.directory));
}

async function checkForSpec(categoryPath) {
	const hasSpec = await fileExists(join(categoryPath, 'SPEC.md'));
	const hasReadme = await fileExists(join(categoryPath, 'README.md'));
	return { hasSpec, hasReadme };
}

async function generateStatus() {
	try {
		// First, gather ALL tests recursively with their full category paths
		const allTests = [];
		const entries = await readdir(REGRESSION_PATH);

		for (const entry of entries) {
			const categoryPath = join(REGRESSION_PATH, entry);
			const stats = await stat(categoryPath);

			// Match category directories like "600_COMPTIME" (letter suffixes unlikely but supported)
			if (stats.isDirectory() && /^\d+[a-z]?_/.test(entry)) {
				// Check for category-level SKIP marker (run_regression.sh:283-297)
				const categorySkipped = await fileExists(join(categoryPath, 'SKIP'));

				const tests = await getTestCases(categoryPath, entry, categorySkipped);
				allTests.push(...tests);
			}
		}

		// Group tests by their categorySlug to build categories (matching save-snapshot.js)
		const categoryMap = new Map();
		for (const test of allTests) {
			if (!categoryMap.has(test.categorySlug)) {
				categoryMap.set(test.categorySlug, []);
			}
			categoryMap.get(test.categorySlug).push(test);
		}

		// Build category objects from the grouped tests
		const categories = Array.from(categoryMap.entries())
			.filter(([slug]) => slug !== null)
			.map(([slug, tests]) => ({
				name: slug.split('/').pop().replace(/^\d+[a-z]?_/, '').replace(/_/g, ' '),
				slug,
				hasSpec: false,  // TODO: could check for SPEC.md in category dir
				hasReadme: false,
				categorySkipped: tests.some(t => t.skipReason === 'Category skipped'),
				tests: tests.sort((a, b) => a.directory.localeCompare(b.directory))
			}));

		categories.sort((a, b) => a.slug.localeCompare(b.slug));

		// Calculate aggregates
		const totalTests = categories.reduce((sum, cat) => sum + cat.tests.length, 0);
		const passedTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'success').length,
			0
		);
		const failedTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'failure').length,
			0
		);
		const todoTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'todo').length,
			0
		);
		const skippedTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'skipped').length,
			0
		);
		const brokenTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'broken').length,
			0
		);
		const untestedTests = categories.reduce(
			(sum, cat) => sum + cat.tests.filter((t) => t.status === 'untested').length,
			0
		);

		const data = {
			categories,
			totalTests,
			passedTests,
			failedTests,
			todoTests,
			skippedTests,
			brokenTests,
			untestedTests,
			generatedAt: new Date().toISOString()
		};

		// Always write JSON
		await writeFile(OUTPUT_JSON_PATH, JSON.stringify(data, null, 2));

		// Output format
		if (format === 'cli') {
			outputCLI(data);
		} else {
			console.log(`✓ Generated status.json: ${categories.length} categories, ${totalTests} tests (${passedTests} passed, ${failedTests} failed)`);
		}
	} catch (error) {
		console.error('Error generating status:', error);
		process.exit(1);
	}
}

function outputCLI(data) {
	const { categories, totalTests, passedTests, failedTests, todoTests, skippedTests, brokenTests, untestedTests } = data;

	console.log('═══════════════════════════════════════════════════════════');
	console.log('KORU REGRESSION TEST STATUS');
	console.log(`Last generated: ${new Date(data.generatedAt).toLocaleString()}`);
	console.log('═══════════════════════════════════════════════════════════');
	console.log('');

	const percentage = totalTests > 0 ? ((passedTests / totalTests) * 100).toFixed(1) : '0.0';
	console.log(`OVERALL: ${passedTests}/${totalTests} passed (${percentage}%)`);
	console.log(`  ✅ ${passedTests} passing`);
	if (todoTests > 0) console.log(`  📝 ${todoTests} TODO`);
	if (skippedTests > 0) console.log(`  ⏭️  ${skippedTests} skipped`);
	if (brokenTests > 0) console.log(`  🔧 ${brokenTests} broken`);
	if (failedTests > 0) console.log(`  ❌ ${failedTests} failed`);
	if (untestedTests > 0) console.log(`  ❔ ${untestedTests} untested`);
	console.log('');

	// Show by category
	console.log('BY CATEGORY:');
	for (const cat of categories) {
		const catPassed = cat.tests.filter(t => t.status === 'success').length;
		const catTotal = cat.tests.length;
		const catPercent = catTotal > 0 ? ((catPassed / catTotal) * 100).toFixed(0) : '0';
		const docStatus = cat.hasSpec ? '[SPEC.md ✓]' : (cat.hasReadme ? '[README.md ℹ]' : '[no docs ✗]');
		const statusEmoji = catPercent >= 80 ? '✅' : catPercent >= 50 ? '⚠️' : '❌';

		console.log(`  ${statusEmoji} ${cat.slug.padEnd(30)} ${catPassed}/${catTotal} ${catPercent.padStart(3)}% ${docStatus}`);
	}
	console.log('');

	// Show failed tests
	const failedTestsList = [];
	for (const cat of categories) {
		for (const test of cat.tests) {
			if (test.status === 'failure') {
				failedTestsList.push(`${test.directory}${test.failureReason ? ` (${test.failureReason})` : ''}`);
			}
		}
	}

	if (failedTestsList.length > 0) {
		console.log('FAILED TESTS:');
		for (const test of failedTestsList) {
			console.log(`  ❌ ${test}`);
		}
		console.log('');
	}

	console.log('USAGE:');
	console.log('  ./run_regression.sh              Run all tests (~10 min)');
	console.log('  ./run_regression.sh <number>     Run specific test');
	console.log('  ./run_regression.sh --status     Show this status');
	console.log('  ./run_regression.sh --list       List all tests');
	console.log('');
	console.log('DOCUMENTATION:');
	console.log('  tests/regression/000_CORE_LANGUAGE/SPEC.md  - Core language');
	console.log('  tests/regression/100_IMPORTS/SPEC.md        - Module system');
	console.log('  See SPEC.md for full navigation');
}

generateStatus();
