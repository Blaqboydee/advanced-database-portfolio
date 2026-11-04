#!/usr/bin/env bash
# Rebuilds the distributed cluster FROM SCRATCH and regenerates evidence/ (~3 minutes).
#   - PostgreSQL: 1 primary + 2 streaming replicas -> replication demo -> failover test
#   - MongoDB: config server + 2 shards + mongos -> sharding demo (uses Portfolio 4's export)
# The cluster is left running afterwards for exploration. To remove it:
#   docker compose -f portfolio-5-distributed-cloud/docker-compose.cluster.yml down -v
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.cluster.yml)
stamp() { echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; }
step()  { echo "==> $*"; }
mkdir -p evidence

if [ ! -s ../portfolio-4-nosql/data/statements.ndjson ]; then
    echo "Portfolio 4's export is missing. Run ../portfolio-4-nosql/run_all.sh first."; exit 1
fi

step "1/5 Fresh cluster (old containers and volumes removed)"
"${COMPOSE[@]}" down -v > /dev/null 2>&1 || true
"${COMPOSE[@]}" up -d > /dev/null 2>&1
for c in dist-pg-primary dist-pg-replica1 dist-pg-replica2; do
    until [ "$(docker inspect -f '{{.State.Health.Status}}' $c 2>/dev/null)" = healthy ]; do sleep 2; done
done
./mongodb/init-cluster.sh > /dev/null

step "2/5 Load the OwoTrust schema and sample data on the primary"
{
  stamp
  for f in /portfolio/portfolio-1-database-design/sql/01_schema.sql \
           /portfolio/portfolio-1-database-design/sql/02_seed_data.sql \
           /portfolio/portfolio-5-distributed-cloud/postgres/cluster_setup.sql; do
      docker exec dist-pg-primary psql -X -q -U owotrust -d owotrust_bank -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v NOTICE || true
  done
  sleep 1
  echo "Containers:"
  docker ps --filter name=dist- --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' | sort
  echo "Replication right after loading:"
  docker exec dist-pg-primary psql -X -U owotrust -d owotrust_bank -c \
      "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind FROM pg_stat_replication ORDER BY 1;"
  for r in replica1 replica2; do
      docker exec dist-pg-$r psql -X -At -U owotrust -d owotrust_bank \
          -c "SELECT '$r: ' || COUNT(*) || ' transactions, in recovery = ' || pg_is_in_recovery() FROM bank_transaction;"
  done
  echo "MongoDB shards:"
  ./mongodb/init-cluster.sh | tail -n +4
} > evidence/00_cluster_setup.txt 2>&1

step "3/5 PostgreSQL replication demo (R1-R8)"
./postgres/01_replication_demo.sh > evidence/01_replication_demo.txt 2>&1

step "4/5 PostgreSQL failover under live traffic (F1-F6)"
./postgres/02_failover_test.sh > evidence/02_failover_test.txt 2>&1

step "5/5 MongoDB sharding demo (S1-S6)"
./mongodb/sharding_demo.sh > evidence/03_sharding_demo.txt 2>&1

echo
echo "Key results:"
grep -E 'visible .* ms after'                       evidence/01_replication_demo.txt | sed 's/^ */  R2 /'
grep -E '^  (ASYNC|SYNC)'                            evidence/01_replication_demo.txt | sed 's/^ */  R6 /'
grep -E 'acknowledged_to_client' -A2                 evidence/02_failover_test.txt | tail -1 | sed 's/^ */  F5 acked | present | LOST | rows: /'
grep -E 'RTO'                                        evidence/02_failover_test.txt | sed 's/^ */  F4 /'
grep -E '^  statements_(hashed|by_month) +shard1rs'  evidence/03_sharding_demo.txt | sed 's/^ */  S5 /'
grep -cE '^ *ERROR' evidence/0*.txt | sed 's/^/  ERROR lines per file (some are expected): /'
echo "Done. Evidence written to $(pwd)/evidence/"
