#!/usr/bin/env python3
"""Time the Portfolio 2 workload and compare runs.

  python3 benchmark.py run <label>              -> evidence/benchmark_<label>.csv
  python3 benchmark.py compare <before> <after> -> markdown table on stdout

`run` executes sql/02_workload.sql once as a warm-up (so every query is
measured with the data already in memory), then RUNS more times in
EXPLAIN (ANALYZE, TIMING OFF) mode. It records the median server-side
"Execution Time" of each query. TIMING OFF avoids the overhead of timing
every plan node, so the totals are closer to normal execution.
"""
import csv
import re
import statistics
import subprocess
import sys
from pathlib import Path

RUNS = 5
HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / "evidence"
PSQL = [
    "docker", "exec", "owotrust-pg", "psql", "-X", "-U", "owotrust", "-d", "owotrust_bank",
    "-v", "ON_ERROR_STOP=1",
    "-v", "EXPLAIN=EXPLAIN (ANALYZE, TIMING OFF)",
    "-f", "/portfolio/portfolio-2-query-optimisation/sql/02_workload.sql",
]


def run_workload_once():
    """Return {query_id: (title, execution_ms)} for one pass of the workload."""
    out = subprocess.run(PSQL, check=True, capture_output=True, text=True).stdout
    results, current = {}, None
    for line in out.splitlines():
        marker = re.match(r"### (Q\w+)\s+(.*)", line)
        if marker:
            current = marker.group(1), marker.group(2).strip()
            continue
        timing = re.search(r"Execution Time: ([\d.]+) ms", line)
        if timing and current:
            results[current[0]] = (current[1], float(timing.group(1)))
    return results


def run(label):
    run_workload_once()                                   # warm-up, not recorded
    samples = [run_workload_once() for _ in range(RUNS)]
    path = EVIDENCE / f"benchmark_{label}.csv"
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["query", "title", "median_ms", "min_ms", "max_ms", "runs"])
        for qid, (title, _) in samples[0].items():
            times = [s[qid][1] for s in samples]
            writer.writerow([qid, title, f"{statistics.median(times):.3f}",
                             f"{min(times):.3f}", f"{max(times):.3f}", RUNS])
    print(f"wrote {path}")


def load(label):
    with (EVIDENCE / f"benchmark_{label}.csv").open() as f:
        return {row["query"]: row for row in csv.DictReader(f)}


def compare(before_label, after_label):
    before, after = load(before_label), load(after_label)
    print(f"| Query | Purpose | {before_label} (ms) | {after_label} (ms) | Speed-up |")
    print("|---|---|---:|---:|---:|")
    for qid, row in before.items():
        b = float(row["median_ms"])
        a = float(after[qid]["median_ms"])
        print(f"| {qid} | {row['title']} | {b:,.3f} | {a:,.3f} | {b / a:,.1f}x |")
    print(f"\nMedian of {before[next(iter(before))]['runs']} runs after one warm-up run; "
          "server-side execution time from EXPLAIN (ANALYZE, TIMING OFF).")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "run":
        run(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
