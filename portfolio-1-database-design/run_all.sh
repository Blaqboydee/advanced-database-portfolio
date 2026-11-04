#!/usr/bin/env bash
# Rebuilds the Portfolio 1 database from scratch and regenerates the
# evidence/ output files. Requires the container from docker-compose.yml:
#   docker compose up -d      (run from the repository root)
set -euo pipefail
cd "$(dirname "$0")"

PSQL=(docker exec owotrust-pg psql -U owotrust -d owotrust_bank)
SQL=/portfolio/portfolio-1-database-design/sql

{ echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$SQL/01_schema.sql"; } \
    > evidence/01_schema_output.txt 2>&1
{ echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; "${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$SQL/02_seed_data.sql"; } \
    > evidence/02_seed_output.txt 2>&1
# 03 is expected to print ERRORs: each test deliberately violates a constraint
{ echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; "${PSQL[@]}" -f "$SQL/03_constraint_tests.sql"; } \
    > evidence/03_constraint_tests_output.txt 2>&1
{ echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; "${PSQL[@]}" -f "$SQL/04_verify.sql"; } \
    > evidence/04_verify_output.txt 2>&1

echo "Done. Evidence written to $(pwd)/evidence/"
grep -c 'ERROR:' evidence/03_constraint_tests_output.txt | xargs echo "Constraint violations caught (expected 20):"
