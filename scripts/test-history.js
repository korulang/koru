#!/usr/bin/env node
import { readdir, readFile } from 'fs/promises';
import { join } from 'path';

const RESULTS_DIR = 'test-results';

/**
 * Parses a test identifier like "123", "608b", "608b_profile_metatype", "9100/456", or "9100_BUGS/456_my_test"
 * Returns { category, number, full } where:
 * - category: "0000_EXAMPLES" or "9100_BUGS" or null
 * - number: "123" or "456" or "608b"
 * - full: "0000_EXAMPLES/123_test_name" or "9100_BUGS/456_bug_name" or null
 * - directory: "608b_profile_metatype" (test directory name without category)
 */
function parseTestIdentifier(identifier) {
    // Handle full path like "9100_BUGS/456_my_test" or "1200_OPTIMIZATIONS/918b_optional_handled"
    const fullPathMatch = identifier.match(/^(\d+_[A-Z_]+)\/(\d+[a-z]?)_/);
    if (fullPathMatch) {
        return {
            category: fullPathMatch[1],
            number: fullPathMatch[2],
            full: identifier,
            directory: null
        };
    }

    // Handle test directory name like "608b_profile_metatype" or "918g_when_guards"
    const directoryMatch = identifier.match(/^(\d+[a-z]?)_[a-z_]+$/);
    if (directoryMatch) {
        return {
            category: null,
            number: directoryMatch[1],
            full: null,
            directory: identifier // Exact directory name
        };
    }

    // Handle category/number like "9100/456" or "1200/918b"
    const categoryMatch = identifier.match(/^(\d+)\/(\d+[a-z]?)$/);
    if (categoryMatch) {
        const categoryNum = categoryMatch[1];
        const testNum = categoryMatch[2];
        // Find actual category directory name (e.g., "9100_BUGS")
        return {
            category: categoryNum, // Will match partial
            number: testNum,
            full: null,
            directory: null
        };
    }

    // Handle simple number like "123" or "608b" or "918g"
    const numberMatch = identifier.match(/^(\d+[a-z]?)$/);
    if (numberMatch) {
        return {
            category: null,
            number: numberMatch[1],
            full: null,
            directory: null
        };
    }

    throw new Error(`Invalid test identifier: ${identifier}`);
}

/**
 * Check if a test matches the parsed identifier
 */
function testMatches(test, parsed) {
    // Extract test number with optional letter suffix (e.g., "608b", "918g")
    const testNumber = test.directory.match(/^(\d+[a-z]?)_/)?.[1];

    if (parsed.full) {
        // Exact match on full path
        return test.directory === parsed.full ||
               `${test.categorySlug}/${test.directory}` === parsed.full;
    }

    if (parsed.directory) {
        // Exact match on directory name (e.g., "608b_profile_metatype")
        return test.directory === parsed.directory;
    }

    if (parsed.category) {
        // Category + number match
        const categoryMatches = test.categorySlug.startsWith(parsed.category + '_') ||
                               test.categorySlug === parsed.category;
        return categoryMatches && testNumber === parsed.number;
    }

    // Just number match
    return testNumber === parsed.number;
}

/**
 * Load all snapshots sorted by timestamp
 */
async function loadSnapshots() {
    try {
        const files = await readdir(RESULTS_DIR);
        const snapshotFiles = files
            .filter(f => f.endsWith('.json') && f !== 'latest.json')
            .sort(); // Chronological order (ISO timestamps sort correctly)

        const snapshots = [];
        for (const file of snapshotFiles) {
            const content = await readFile(join(RESULTS_DIR, file), 'utf-8');
            const snapshot = JSON.parse(content);
            snapshots.push({
                filename: file,
                ...snapshot
            });
        }

        return snapshots;
    } catch (error) {
        if (error.code === 'ENOENT') {
            return [];
        }
        throw error;
    }
}

/**
 * Find test history across all snapshots
 */
function findTestHistory(snapshots, testIdentifier) {
    const parsed = parseTestIdentifier(testIdentifier);
    const history = [];

    for (const snapshot of snapshots) {
        // Search through all categories
        for (const category of snapshot.categories || []) {
            for (const test of category.tests || []) {
                if (testMatches(test, parsed)) {
                    history.push({
                        timestamp: snapshot.timestamp,
                        gitCommit: snapshot.gitCommit || 'unknown',
                        category: category.name,
                        directory: test.directory,
                        status: test.status,
                        fullPath: `${category.slug}/${test.directory}`
                    });
                }
            }
        }
    }

    return history;
}

/**
 * Format status with color
 */
function formatStatus(status) {
    const colors = {
        success: '\x1b[32m✓ PASS\x1b[0m',
        failure: '\x1b[31m✗ FAIL\x1b[0m',
        todo: '\x1b[34m● TODO\x1b[0m',
        skipped: '\x1b[33m○ SKIP\x1b[0m',
        broken: '\x1b[35m✕ BROKEN\x1b[0m',
        untested: '\x1b[90m? UNTESTED\x1b[0m'
    };
    return colors[status] || status;
}

/**
 * Analyze history for key transitions
 */
function analyzeHistory(history) {
    if (history.length === 0) {
        return { lastPassing: null, lastFailing: null, regressions: [], fixes: [] };
    }

    let lastPassing = null;
    let lastFailing = null;
    const regressions = [];
    const fixes = [];

    for (let i = 0; i < history.length; i++) {
        const current = history[i];
        const prev = i > 0 ? history[i - 1] : null;

        // Track last known passing/failing state
        if (current.status === 'success') {
            lastPassing = current;
        }
        if (current.status === 'failure') {
            lastFailing = current;
        }

        // Detect transitions
        if (prev) {
            const wasGood = prev.status === 'success';
            const isBad = current.status === 'failure';
            const isGood = current.status === 'success';
            const wasBad = prev.status === 'failure';

            if (wasGood && isBad) {
                regressions.push({
                    from: prev,
                    to: current,
                    transition: 'REGRESSION: passed → failed'
                });
            } else if (wasBad && isGood) {
                fixes.push({
                    from: prev,
                    to: current,
                    transition: 'FIX: failed → passed'
                });
            }
        }
    }

    return { lastPassing, lastFailing, regressions, fixes };
}

/**
 * Main function
 */
async function main() {
    const args = process.argv.slice(2);

    if (args.length === 0 || args[0] === '--help') {
        console.log('Usage: node scripts/test-history.js <test-identifier>');
        console.log('');
        console.log('Examples:');
        console.log('  node scripts/test-history.js 123                     # Find test 123_* in any category');
        console.log('  node scripts/test-history.js 608b                    # Find test 608b_* with letter suffix');
        console.log('  node scripts/test-history.js 608b_profile_metatype   # Exact directory name match');
        console.log('  node scripts/test-history.js 9100/456                # Find test 456 in category 9100_*');
        console.log('  node scripts/test-history.js 1200/918g               # Find test 918g in category 1200_*');
        console.log('  node scripts/test-history.js 9100_BUGS/456_my_test  # Full path exact match');
        console.log('');
        console.log('Shows the history of a test across all captured snapshots.');
        process.exit(0);
    }

    const testIdentifier = args[0];

    console.log(`Loading snapshots from ${RESULTS_DIR}/...`);
    const snapshots = await loadSnapshots();

    if (snapshots.length === 0) {
        console.log('\x1b[33m⚠ No snapshots found\x1b[0m');
        console.log('Run a full regression test to create snapshots: ./run_regression.sh');
        process.exit(1);
    }

    console.log(`Found ${snapshots.length} snapshot(s)`);
    console.log('');

    const history = findTestHistory(snapshots, testIdentifier);

    if (history.length === 0) {
        console.log(`\x1b[33m⚠ Test not found: ${testIdentifier}\x1b[0m`);
        process.exit(1);
    }

    // Show test info
    const firstEntry = history[0];
    console.log(`\x1b[1mTest: ${firstEntry.fullPath}\x1b[0m`);
    console.log('');

    // Analyze for key insights
    const analysis = analyzeHistory(history);

    // Show key findings first
    if (analysis.lastPassing) {
        console.log(`\x1b[32m✓ Last passing:\x1b[0m ${analysis.lastPassing.timestamp}`);
        console.log(`  Git commit: ${analysis.lastPassing.gitCommit}`);
        console.log('');
    }

    if (analysis.lastFailing && (!analysis.lastPassing ||
        analysis.lastFailing.timestamp > analysis.lastPassing.timestamp)) {
        console.log(`\x1b[31m✗ Currently failing since:\x1b[0m ${analysis.lastFailing.timestamp}`);
        console.log(`  Git commit: ${analysis.lastFailing.gitCommit}`);
        console.log('');
    }

    // Show regressions (most important)
    if (analysis.regressions.length > 0) {
        console.log(`\x1b[1m\x1b[31m❌ REGRESSIONS (${analysis.regressions.length}):\x1b[0m`);
        for (const reg of analysis.regressions) {
            console.log(`  ${reg.from.timestamp} (${reg.from.gitCommit}): ✓ PASS`);
            console.log(`  ${reg.to.timestamp} (${reg.to.gitCommit}): ✗ FAIL`);
            console.log(`  \x1b[1m→ BROKE AT: ${reg.to.gitCommit}\x1b[0m`);
            console.log('');
        }
    }

    // Show fixes
    if (analysis.fixes.length > 0) {
        console.log(`\x1b[1m\x1b[32m✓ FIXES (${analysis.fixes.length}):\x1b[0m`);
        for (const fix of analysis.fixes) {
            console.log(`  ${fix.from.timestamp} (${fix.from.gitCommit}): ✗ FAIL`);
            console.log(`  ${fix.to.timestamp} (${fix.to.gitCommit}): ✓ PASS`);
            console.log(`  \x1b[1m→ FIXED AT: ${fix.to.gitCommit}\x1b[0m`);
            console.log('');
        }
    }

    // Full history
    console.log(`\x1b[1mFull History (${history.length} snapshots):\x1b[0m`);
    for (const entry of history) {
        console.log(`  ${entry.timestamp} | ${entry.gitCommit.padEnd(7)} | ${formatStatus(entry.status)}`);
    }

    // Git bisect hint
    if (analysis.regressions.length > 0) {
        const mostRecent = analysis.regressions[analysis.regressions.length - 1];
        console.log('');
        console.log('\x1b[1mGit bisect hint:\x1b[0m');
        console.log(`  git bisect start`);
        console.log(`  git bisect bad ${mostRecent.to.gitCommit}  # Test fails here`);
        console.log(`  git bisect good ${mostRecent.from.gitCommit}  # Test passed here`);
        // Extract test number with optional letter suffix
        const testNum = testIdentifier.match(/(\d+[a-z]?)(?:_|\/|$)/)?.[1] || testIdentifier;
        console.log(`  # Then run: ./run_regression.sh ${testNum} (test and mark good/bad)`);
    }
}

main().catch(error => {
    console.error('\x1b[31mError:\x1b[0m', error.message);
    process.exit(1);
});
