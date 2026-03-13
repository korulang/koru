#!/usr/bin/env node
/**
 * Koru Test Index Generator
 *
 * Generates a flat, grep-friendly index of all regression tests.
 * Each line contains: test_id | category | name | status
 *
 * This makes it easy to find working examples:
 *   grep "pairwise" test-index.txt | grep "pass"
 *   grep "KERNELS" test-index.txt
 *
 * Run automatically at the end of each regression run, or standalone:
 *   node scripts/generate-test-index.js
 */

import { readdir, stat, access, writeFile, readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const REGRESSION_PATH = join(__dirname, '../tests/regression');
const OUTPUT_PATH = join(__dirname, '../test-index.txt');

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
 * Recursively find all test directories and their metadata
 */
async function findTests(basePath, categoryPath = '', categoryName = '', categorySkipped = false) {
	const tests = [];
	let entries;
	
	try {
		entries = await readdir(basePath);
	} catch {
		return tests;
	}

	for (const entry of entries) {
		const fullPath = join(basePath, entry);
		const stats = await stat(fullPath);

		// Only process numbered directories
		if (!stats.isDirectory() || !/^\d+[a-z]?_/.test(entry)) {
			continue;
		}

		const hasInput = await fileExists(join(fullPath, 'input.kz'));
		const hasTodo = await fileExists(join(fullPath, 'TODO'));
		const hasSkip = await fileExists(join(fullPath, 'SKIP'));
		const hasBroken = await fileExists(join(fullPath, 'BROKEN'));
		const hasBenchmark = await fileExists(join(fullPath, 'BENCHMARK'));

		// Is this a test directory or a category directory?
		const isTest = hasInput || hasTodo || hasSkip || hasBroken || hasBenchmark;

		if (isTest) {
			// Extract test name from directory (strip numeric prefix)
			const match = entry.match(/^(\d+[a-z]?)_(.*)$/);
			const testName = match ? match[2].replace(/_/g, ' ') : entry;

			// Determine status from marker files
			let status = 'untested';
			if (hasTodo) {
				status = 'todo';
			} else if (hasBenchmark) {
				status = 'benchmark';
			} else if (categorySkipped || hasSkip) {
				status = 'skip';
			} else if (hasBroken) {
				status = 'broken';
			} else {
				const hasSuccess = await fileExists(join(fullPath, 'SUCCESS'));
				const hasFailure = await fileExists(join(fullPath, 'FAILURE'));
				if (hasSuccess && !hasFailure) {
					status = 'pass';
				} else if (hasFailure) {
					status = 'FAIL';
				}
			}

			tests.push({
				id: entry,  // Use full directory name (e.g., "010_000_hello_world_koru")
				category: categoryName || 'UNCATEGORIZED',
				name: testName,
				status,
				directory: entry,
				fullPath: categoryPath ? `${categoryPath}/${entry}` : entry,
			});
		} else {
			// This is a category directory - recurse into it
			const subCategorySkipped = categorySkipped || hasSkip;
			const newCategoryPath = categoryPath ? `${categoryPath}/${entry}` : entry;
			
			// Extract category name (strip numeric prefix, convert underscores)
			const catMatch = entry.match(/^\d+[a-z]?_(.*)$/);
			const catName = catMatch ? catMatch[1].replace(/_/g, ' ').toUpperCase() : entry.toUpperCase();
			
			// Build hierarchical category name
			const fullCategoryName = categoryName ? `${categoryName} / ${catName}` : catName;

			const subTests = await findTests(fullPath, newCategoryPath, fullCategoryName, subCategorySkipped);
			tests.push(...subTests);
		}
	}

	return tests;
}

/**
 * Format a single test line for the index
 */
function formatTestLine(test) {
	// Pad fields for alignment and readability
	const id = test.id.padEnd(40);
	const category = test.category.padEnd(35);
	const status = test.status;
	
	return `${id} | ${category} | ${status}`;
}

async function generateIndex() {
	try {
		const tests = await findTests(REGRESSION_PATH);
		
		// Sort by full path to maintain logical ordering
		tests.sort((a, b) => a.fullPath.localeCompare(b.fullPath));

		// Generate the index content
		const lines = [
			'# Koru Regression Test Index',
			'# Generated: ' + new Date().toISOString(),
			'# Format: test_directory | category | status',
			'# Status: pass, FAIL, todo, skip, broken, benchmark, untested',
			'#',
			'# Usage:',
			'#   grep "pairwise" test-index.txt          # Find pairwise tests',
			'#   grep "| pass$" test-index.txt           # All passing tests',
			'#   grep "KERNEL" test-index.txt            # All kernel tests',
			'#   grep "FAIL" test-index.txt              # All failing tests',
			'#',
			'# Run a test: ./run_regression.sh 390_003   # Runs pairwise_basic',
			'#',
			'',
		];

		// Group by top-level category for visual separation
		let currentTopCategory = '';
		for (const test of tests) {
			const topCategory = test.category.split(' / ')[0];
			if (topCategory !== currentTopCategory) {
				currentTopCategory = topCategory;
				lines.push(`# ${currentTopCategory}`);
			}
			lines.push(formatTestLine(test));
		}

		// Add summary
		const passed = tests.filter(t => t.status === 'pass').length;
		const failed = tests.filter(t => t.status === 'FAIL').length;
		const todo = tests.filter(t => t.status === 'todo').length;
		const skip = tests.filter(t => t.status === 'skip').length;
		const broken = tests.filter(t => t.status === 'broken').length;
		const benchmark = tests.filter(t => t.status === 'benchmark').length;
		const untested = tests.filter(t => t.status === 'untested').length;

		lines.push('');
		lines.push(`# Total: ${tests.length} tests`);
		lines.push(`# Pass: ${passed} | Fail: ${failed} | Todo: ${todo} | Skip: ${skip} | Broken: ${broken} | Benchmark: ${benchmark} | Untested: ${untested}`);

		await writeFile(OUTPUT_PATH, lines.join('\n') + '\n');

		console.log(`✓ Generated test-index.txt: ${tests.length} tests (${passed} pass, ${failed} fail)`);

	} catch (error) {
		console.error('Error generating test index:', error);
		process.exit(1);
	}
}

generateIndex();
