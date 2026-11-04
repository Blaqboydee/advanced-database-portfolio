#!/usr/bin/env bash
# Rebuilds the Portfolio 2 experiment from scratch and regenerates every
# file in evidence/. Takes about 2-3 minutes.
# Requires the container from docker-compose.yml:  docker compose up -d
#
# NOTE: this replaces the small Portfolio 1 database with the large one.
# Run ../portfolio-1-database-design/run_all.sh to go back to the small one.
set -euo pipefail
cd "$(dirname "$0")"

PSQL=(docker exec owotrust-pg psql -X -U owotrust -d owotrust_bank)
P1=/portfolio/portfolio-1-database-design/sql
P2=/portfolio/portfolio-2-query-optimisation/sql
stamp() { echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; }
step()  { echo "==> $*"; }

step "1/9 Rebuild Portfolio 1 schema and seed data"
"${PSQL[@]}" -q -v ON_ERROR_STOP=1 -f "$P1/01_schema.sql" 2>&1 | grep -v NOTICE || true
"${PSQL[@]}" -q -v ON_ERROR_STOP=1 -f "$P1/02_seed_data.sql"

step "2/9 Generate bulk data (~1.06M transactions)"
{ stamp; "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$P2/01_bulk_data.sql"; } > evidence/01_bulk_data_output.txt 2>&1

step "3/9 Record the test environment"
{
  stamp
  echo "Host CPU : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -p)"
  echo "Docker   : $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM available to containers')"
  "${PSQL[@]}" -c "SELECT version();" \
               -c "SELECT name, setting, unit FROM pg_settings
                   WHERE name IN ('shared_buffers','work_mem','effective_cache_size','random_page_cost',
                                  'max_parallel_workers_per_gather','jit','default_statistics_target')
                   ORDER BY name;"
} > evidence/00_environment.txt 2>&1

step "4/9 Query results (no indexes yet)"
{ stamp; "${PSQL[@]}" -v EXPLAIN= -f "$P2/02_workload.sql"; } > evidence/02_query_results.txt 2>&1

step "5/9 Execution plans BEFORE indexing + benchmark"
{ stamp; "${PSQL[@]}" -v EXPLAIN='EXPLAIN (ANALYZE, BUFFERS)' -f "$P2/02_workload.sql"; } \
    > evidence/03_plans_before_indexing.txt 2>&1
python3 benchmark.py run before

step "6/9 Create indexes and extended statistics"
{ stamp; "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$P2/03_indexes.sql"; } > evidence/04_indexes_output.txt 2>&1

step "7/9 Execution plans AFTER indexing + benchmark"
{ stamp; "${PSQL[@]}" -v EXPLAIN='EXPLAIN (ANALYZE, BUFFERS)' -f "$P2/02_workload.sql"; } \
    > evidence/05_plans_after_indexing.txt 2>&1
python3 benchmark.py run after
{ stamp; python3 benchmark.py compare before after; } > evidence/06_benchmark_summary.md

step "8/9 Advanced techniques (statistics, NOT IN, work_mem, materialized view)"
{ stamp; "${PSQL[@]}" -f "$P2/04_advanced.sql"; } > evidence/07_advanced_output.txt 2>&1

step "9/9 Index trade-offs (storage, alternatives, write overhead)"
{ stamp; "${PSQL[@]}" -f "$P2/05_index_tradeoffs.sql"; } > evidence/08_index_tradeoffs_output.txt 2>&1

echo
cat evidence/06_benchmark_summary.md
if grep -l 'ERROR' evidence/0[0-8]_*.txt; then
    echo "!! The files above contain errors - check them."; exit 1
fi
echo "Done. Evidence written to $(pwd)/evidence/"
