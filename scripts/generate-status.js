#!/usr/bin/env node
/**
 * Koru Regression Test Status Generator
 *
 * Reads from test-results/latest.json (written by full regression runs) for
 * accurate counts, then outputs CLI or JSON. Falls back to filesystem scan
 * if no snapshot exists yet.
 */

import { readdir, stat, access, writeFile, readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REGRESSION_PATH = join(__dirname, '../tests/regression');
const SNAPSHOT_PATH = join(__dirname, '../test-results/latest.json');
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

// ---------------------------------------------------------------------------
// Snapshot-based path (preferred)
// ---------------------------------------------------------------------------

async function loadFromSnapshot() {
	const raw = await readFile(SNAPSHOT_PATH, 'utf-8');
	const snap = JSON.parse(raw);
	const { summary, categories, timestamp } = snap;

	return {
		categories,
		totalTests: summary.total,
		passedTests: summary.passed,
		failedTests: summary.failed,
		todoTests: summary.todo,
		skippedTests: summary.skipped,
		brokenTests: summary.broken,
		untestedTests: summary.untested,
		generatedAt: timestamp,
	};
}

// ---------------------------------------------------------------------------
// Filesystem fallback (used when no snapshot exists)
// ---------------------------------------------------------------------------

async function getTestCases(categoryPath, categorySlugPath, categorySkipped = false) {
	const tests = [];
	const entries = await readdir(categoryPath);

	for (const entry of entries) {
		const testPath = join(categoryPath, entry);
		const stats = await stat(testPath);

		if (stats.isDirectory() && /^\d+[a-z]?_/.test(entry)) {
			const hasInput = await fileExists(join(testPath, 'input.kz'));
			const mustRun = await fileExists(join(testPath, 'MUST_RUN'));
			const success = await fileExists(join(testPath, 'SUCCESS'));
			const failure = await fileExists(join(testPath, 'FAILURE'));
			const todo = await fileExists(join(testPath, 'TODO'));
			const skip = await fileExists(join(testPath, 'SKIP'));
			const broken = await fileExists(join(testPath, 'BROKEN'));

			if (!hasInput && !todo && !skip && !broken) {
				const subCategorySkipped = categorySkipped || skip;
				const subCategorySlugPath = categorySlugPath ? `${categorySlugPath}/${entry}` : entry;
				const subTests = await getTestCases(testPath, subCategorySlugPath, subCategorySkipped);
				tests.push(...subTests);
				continue;
			}

			let failureReason = '';
			if (failure) failureReason = await readFirstLine(join(testPath, 'FAILURE'));
			const todoDesc = todo ? await readFirstLine(join(testPath, 'TODO')) : '';
			const skipReason = skip ? await readFirstLine(join(testPath, 'SKIP')) : '';
			const brokenReason = broken ? await readFirstLine(join(testPath, 'BROKEN')) : '';

			let status = 'untested';
			if (todo) status = 'todo';
			else if (categorySkipped) status = 'skipped';
			else if (skip) status = 'skipped';
			else if (broken) status = 'broken';
			else if (success && failure) status = 'unknown';
			else if (success) status = 'success';
			else if (failure) status = 'failure';

			tests.push({
				name: entry.replace(/^\d+[a-z]?_/, '').replace(/_/g, ' '),
				directory: entry,
				categorySlug: categorySlugPath,
				mustRun,
				status,
				failureReason,
				todoDesc,
				skipReason: categorySkipped && !skip ? 'Category skipped' : skipReason,
				brokenReason,
			});
		}
	}

	return tests.sort((a, b) => a.directory.localeCompare(b.directory));
}

async function loadFromFilesystem() {
	const allTests = [];
	const entries = await readdir(REGRESSION_PATH);

	for (const entry of entries) {
		const categoryPath = join(REGRESSION_PATH, entry);
		const stats = await stat(categoryPath);
		if (stats.isDirectory() && /^\d+[a-z]?_/.test(entry)) {
			const categorySkipped = await fileExists(join(categoryPath, 'SKIP'));
			const tests = await getTestCases(categoryPath, entry, categorySkipped);
			allTests.push(...tests);
		}
	}

	const categoryMap = new Map();
	for (const test of allTests) {
		if (!categoryMap.has(test.categorySlug)) categoryMap.set(test.categorySlug, []);
		categoryMap.get(test.categorySlug).push(test);
	}

	const categories = Array.from(categoryMap.entries())
		.filter(([slug]) => slug !== null)
		.map(([slug, tests]) => ({
			name: slug.split('/').pop().replace(/^\d+[a-z]?_/, '').replace(/_/g, ' '),
			slug,
			categorySkipped: tests.some(t => t.skipReason === 'Category skipped'),
			tests: tests.sort((a, b) => a.directory.localeCompare(b.directory)),
		}));

	categories.sort((a, b) => a.slug.localeCompare(b.slug));

	const count = (status) => categories.reduce((s, c) => s + c.tests.filter(t => t.status === status).length, 0);

	return {
		categories,
		totalTests: allTests.length,
		passedTests: count('success'),
		failedTests: count('failure'),
		todoTests: count('todo'),
		skippedTests: count('skipped'),
		brokenTests: count('broken'),
		untestedTests: count('untested'),
		generatedAt: new Date().toISOString(),
		fromFilesystem: true,
	};
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function generateStatus() {
	try {
		let data;
		if (await fileExists(SNAPSHOT_PATH)) {
			data = await loadFromSnapshot();
		} else {
			data = await loadFromFilesystem();
		}

		await writeFile(OUTPUT_JSON_PATH, JSON.stringify(data, null, 2));

		if (format === 'cli') {
			outputCLI(data);
		} else {
			const { passedTests, totalTests, failedTests, categories } = data;
			console.log(`✓ Generated status.json: ${categories.length} categories, ${totalTests} tests (${passedTests} passed, ${failedTests} failed)`);
		}
	} catch (error) {
		console.error('Error generating status:', error);
		process.exit(1);
	}
}

function outputCLI(data) {
	const { categories, totalTests, passedTests, failedTests, todoTests, skippedTests, brokenTests, untestedTests, generatedAt, fromFilesystem } = data;

	console.log('═══════════════════════════════════════════════════════════');
	console.log('KORU REGRESSION TEST STATUS');
	const sourceLabel = fromFilesystem ? 'filesystem scan (no snapshot yet)' : `snapshot ${new Date(generatedAt).toLocaleString()}`;
	console.log(`Source: ${sourceLabel}`);
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

	console.log('BY CATEGORY:');
	for (const cat of categories) {
		const catPassed = cat.tests.filter(t => t.status === 'success').length;
		const catTotal = cat.tests.length;
		const catPercent = catTotal > 0 ? ((catPassed / catTotal) * 100).toFixed(0) : '0';
		const statusEmoji = catPercent >= 80 ? '✅' : catPercent >= 50 ? '⚠️' : '❌';
		console.log(`  ${statusEmoji} ${cat.slug.padEnd(50)} ${catPassed}/${catTotal} ${catPercent.padStart(3)}%`);
	}
	console.log('');

	const failedTestsList = categories.flatMap(cat =>
		cat.tests
			.filter(t => t.status === 'failure')
			.map(t => `${t.directory}${t.failureReason ? ` (${t.failureReason})` : ''}`)
	);

	if (failedTestsList.length > 0) {
		console.log('FAILED TESTS:');
		for (const test of failedTestsList) console.log(`  ❌ ${test}`);
		console.log('');
	}

	console.log('USAGE:');
	console.log('  ./run_regression.sh              Run all tests');
	console.log('  ./run_regression.sh <number>     Run specific test');
	console.log('  ./run_regression.sh --status     Show this status');
	console.log('  ./run_regression.sh --list       List all tests');
}

generateStatus();
