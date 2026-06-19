#!/usr/bin/env bash
# wm native PROBE — koru perf-promise watcher (first cut).
#
# The REUSABLE shape: PROMISE → MEASUREMENT → WORLD-vs-MODEL. Koru-specifics live at the
# edges (which CSV, which promise); the shape in the middle is general enough to extract.
#
#   PROMISE (model/setpoint): korulang.org homepage — koru runs "within 10% of the host
#     language" (Zig) for glue, and outperforms abstractions by orders of magnitude.
#   MEASUREMENT (faucet): benchmarks/results/*.csv  (wall_ms per language per workload).
#   WORLD-vs-MODEL: where a Zig host baseline exists, is koru within 10%? Where it does NOT
#     exist, the host-parity promise is UNBACKED — that gap is the first surprise this fires.
#
# Exit speaks for the INSTRUMENT (could we read the results?); signals speak for the WORLD.
set -u
cd "$(dirname "$0")/../.."  # repo root
[ -d benchmarks/results ] || { echo "probe_perf_promise: FAIL — no benchmarks/results (instrument fault)" >&2; exit 2; }

node -e '
  const fs = require("fs");
  const dir = "benchmarks/results";
  const wl = {}; // workload -> { lang: fastest wall_ms }
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith(".csv"))) {
    for (const ln of fs.readFileSync(dir + "/" + f, "utf8").split("\n").slice(1)) {
      if (!ln.trim()) continue;
      const c = ln.split(",");            // first 4 cols are simple; quoted output comes after
      const [workload, lang, , wall] = c;
      const ms = parseFloat(wall);
      if (!workload || !lang || isNaN(ms)) continue;
      (wl[workload] ??= {});
      if (wl[workload][lang] === undefined || ms < wl[workload][lang]) wl[workload][lang] = ms;
    }
  }
  const workloads = Object.keys(wl);
  let withHost = 0, kept = 0, broken = 0, fastest = 0;
  for (const w of workloads) {
    const langs = wl[w], koru = langs.koru;
    if (koru === undefined) continue;
    const others = Object.entries(langs).filter(([l]) => l !== "koru").map(([,v]) => v);
    if (others.length && koru <= Math.min(...others)) fastest++;
    if (langs.zig !== undefined) { withHost++; if (koru <= langs.zig * 1.10) kept++; else broken++; }
  }
  const unbacked = workloads.length - withHost;
  console.log(`signal workloads ${workloads.length}`);
  console.log(`signal koru_fastest ${fastest}`);
  console.log(`signal host_baseline ${withHost}`);
  console.log(`signal promise_unbacked ${unbacked}`);
  console.log(`signal within_10pct_of_host ${kept}`);
  console.log(`signal host_promise_broken ${broken}`);
  console.log(`probe_perf_promise: ${workloads.length} workloads — koru fastest in ${fastest}. ` +
    `Zig host baseline on only ${withHost}, so "within 10% of host" is UNBACKED on ${unbacked} (the surprise). ` +
    `Of the ${withHost} measured: ${kept} within 10%, ${broken} broke it.`);
'
exit 0
