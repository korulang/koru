#!/usr/bin/env node
/**
 * Koru Test Snapshot Diff Tool
 *
 * Compares two test snapshots to detect regressions and improvements.
 * Default: compares current state vs last snapshot.
 *
 * Exit codes:
 *   0 - No regressions (improvements are OK)
 *   1 - Regressions detected or error
 */

import { readFile, access } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const RESULTS_DIR = join(__dirname, '../test-results');

// Parse command line args
const args = process.argv.slice(2);

async function fileExists(path) {
	try {
		await access(path);
		return true;
	} catch {
		return false;
	}
}

async function loadSnapshot(path) {
	try {
		const content = await readFile(path, 'utf-8');
		return JSON.parse(content);
	} catch (error) {
		throw new Error(`Failed to load snapshot: ${path}\n${error.message}`);
	}
}

async function getCurrentState() {
	// Load current state by reading generate-status.js output
	// This is a bit hacky but avoids duplicating the scanning logic
	const { execSync } = await import('child_process');
	const statusJson = execSync('node scripts/generate-status.js --format=json 2>&1', {
		cwd: join(__dirname, '..'),
		encoding: 'utf-8'
	});

	// The script writes to status.json, so read it
	const statusPath = join(__dirname, '../status.json');
	const data = await loadSnapshot(statusPath);

	// Normalize format to match snapshot format
	// generate-status.js uses: totalTests, passedTests, etc.
	// save-snapshot.js uses: summary { total, passed, etc. }
	if (!data.summary && data.totalTests !== undefined) {
		data.summary = {
			total: data.totalTests,
			passed: data.passedTests,
			failed: data.failedTests,
			todo: data.todoTests,
			skipped: data.skippedTests,
			broken: data.brokenTests,
			untested: data.untestedTests,
			passRate: data.totalTests > 0 ? ((data.passedTests / data.totalTests) * 100).toFixed(1) : '0.0'
		};
		data.timestamp = data.generatedAt;
		data.gitCommit = 'current';
		data.commandFlags = '';
	}

	return data;
}

function formatTimestamp(iso) {
	const date = new Date(iso);
	return date.toLocaleString('en-US', {
		month: 'short',
		day: 'numeric',
		hour: 'numeric',
		minute: '2-digit',
		hour12: true
	});
}

async function diffSnapshots(oldPathOrData, newPathOrData) {
	try {
		// Load snapshots (or use provided data)
		const oldSnap = typeof oldPathOrData === 'string' ? await loadSnapshot(oldPathOrData) : oldPathOrData;
		const newSnap = typeof newPathOrData === 'string' ? await loadSnapshot(newPathOrData) : newPathOrData;

		// Build test lookup maps
		const oldTests = new Map();
		const newTests = new Map();

		for (const cat of oldSnap.categories) {
			for (const test of cat.tests) {
				oldTests.set(test.directory, { ...test, category: cat.slug });
			}
		}

		for (const cat of newSnap.categories) {
			for (const test of cat.tests) {
				newTests.set(test.directory, { ...test, category: cat.slug });
			}
		}

		// Detect changes
		const regressions = [];
		const improvements = [];
		const newTestsList = [];
		const removedTests = [];
		const statusChanges = [];

		// Check all tests in new snapshot
		for (const [testName, newTest] of newTests) {
			const oldTest = oldTests.get(testName);

			if (!oldTest) {
				// New test added
				newTestsList.push(newTest);
			} else {
				// Test existed before - check for status change
				if (oldTest.status !== newTest.status) {
					const change = {
						name: testName,
						category: newTest.category,
						oldStatus: oldTest.status,
						newStatus: newTest.status,
						failureReason: newTest.failureReason
					};

					// Classify as regression or improvement
					const wasGood = oldTest.status === 'success';
					const isBad = newTest.status === 'failure';
					const isGood = newTest.status === 'success';
					const wasBad = oldTest.status === 'failure';

					if (wasGood && isBad) {
						regressions.push(change);
					} else if (wasBad && isGood) {
						improvements.push(change);
					} else {
						statusChanges.push(change);
					}
				}
			}
		}

		// Check for removed tests
		for (const [testName, oldTest] of oldTests) {
			if (!newTests.has(testName)) {
				removedTests.push(oldTest);
			}
		}

		// Display results
		console.log('═══════════════════════════════════════════════════════════');
		console.log('TEST SNAPSHOT COMPARISON');
		console.log('═══════════════════════════════════════════════════════════');
		console.log('');

		console.log(`OLD: ${oldSnap.summary.passed}/${oldSnap.summary.total} passed (${oldSnap.summary.passRate}%)`);
		console.log(`     ${formatTimestamp(oldSnap.timestamp)}, commit ${oldSnap.gitCommit}`);
		console.log('');

		console.log(`NEW: ${newSnap.summary.passed}/${newSnap.summary.total} passed (${newSnap.summary.passRate}%)`);
		console.log(`     ${formatTimestamp(newSnap.timestamp)}, commit ${newSnap.gitCommit}`);
		console.log('');

		// Calculate net change
		const passedDelta = newSnap.summary.passed - oldSnap.summary.passed;
		const totalDelta = newSnap.summary.total - oldSnap.summary.total;
		const passRateDelta = (parseFloat(newSnap.summary.passRate) - parseFloat(oldSnap.summary.passRate)).toFixed(1);

		const deltaSign = passedDelta >= 0 ? '+' : '';
		const rateSign = passRateDelta >= 0 ? '+' : '';
		console.log(`NET: ${deltaSign}${passedDelta} passed, ${deltaSign}${totalDelta} total (${rateSign}${passRateDelta}%)`);
		console.log('');

		// Show regressions (most important!)
		if (regressions.length > 0) {
			console.log(`⚠️  REGRESSIONS (${regressions.length}):`);
			for (const reg of regressions.sort((a, b) => a.name.localeCompare(b.name))) {
				const reason = reg.failureReason ? ` (${reg.failureReason})` : '';
				console.log(`  ❌ ${reg.name}${reason}`);
			}
			console.log('');
		}

		// Show improvements
		if (improvements.length > 0) {
			console.log(`✅ IMPROVEMENTS (${improvements.length}):`);
			for (const imp of improvements.sort((a, b) => a.name.localeCompare(b.name))) {
				console.log(`  ✅ ${imp.name}`);
			}
			console.log('');
		}

		// Show other status changes
		if (statusChanges.length > 0) {
			console.log(`📝 OTHER CHANGES (${statusChanges.length}):`);
			for (const change of statusChanges.sort((a, b) => a.name.localeCompare(b.name))) {
				console.log(`  📝 ${change.name}: ${change.oldStatus} → ${change.newStatus}`);
			}
			console.log('');
		}

		// Show new tests
		if (newTestsList.length > 0) {
			console.log(`🆕 NEW TESTS (${newTestsList.length}):`);
			for (const test of newTestsList.sort((a, b) => a.directory.localeCompare(b.directory))) {
				const status = test.status === 'success' ? '✅' :
				              test.status === 'failure' ? '❌' :
				              test.status === 'todo' ? '📝' : '❔';
				console.log(`  ${status} ${test.directory}`);
			}
			console.log('');
		}

		// Show removed tests
		if (removedTests.length > 0) {
			console.log(`🗑️  REMOVED TESTS (${removedTests.length}):`);
			for (const test of removedTests.sort((a, b) => a.directory.localeCompare(b.directory))) {
				console.log(`  🗑️  ${test.directory}`);
			}
			console.log('');
		}

		// Summary
		if (regressions.length === 0 && improvements.length === 0 &&
		    newTestsList.length === 0 && removedTests.length === 0 && statusChanges.length === 0) {
			console.log('✅ No changes detected');
		}

		// Exit with error if there are regressions
		if (regressions.length > 0) {
			console.log('❌ REGRESSIONS DETECTED - tests that used to pass now fail');
			process.exit(1);
		}

	} catch (error) {
		console.error('Error comparing snapshots:', error.message);
		process.exit(1);
	}
}

async function main() {
	// Determine which snapshots to compare
	let oldPath, newPath;

	if (args.length === 0) {
		// Default: compare latest snapshot vs current state
		oldPath = join(RESULTS_DIR, 'latest.json');

		if (!await fileExists(oldPath)) {
			console.error('❌ No previous snapshot found');
			console.error('   Run a full test suite first: ./run_regression.sh');
			process.exit(1);
		}

		// Generate current state (returns normalized data)
		console.log('Scanning current test state...');
		newPath = await getCurrentState(); // Returns data object, not path

	} else if (args.length === 2) {
		// Compare two specific snapshots
		oldPath = args[0];
		newPath = args[1];

		if (!await fileExists(oldPath)) {
			console.error(`❌ Snapshot not found: ${oldPath}`);
			process.exit(1);
		}
		if (!await fileExists(newPath)) {
			console.error(`❌ Snapshot not found: ${newPath}`);
			process.exit(1);
		}

	} else {
		console.error('Usage:');
		console.error('  node scripts/diff-snapshots.js              # Compare current vs last snapshot');
		console.error('  node scripts/diff-snapshots.js <old> <new>  # Compare two specific snapshots');
		process.exit(1);
	}

	await diffSnapshots(oldPath, newPath);
}

main();
