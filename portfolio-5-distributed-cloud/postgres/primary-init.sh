#!/bin/bash
# Runs ONCE when the primary's data directory is first created
# (mounted into /docker-entrypoint-initdb.d by docker-compose.cluster.yml).
#  - a dedicated login role for replication (replicas never use the app account)
#  - one physical replication slot per replica: the primary keeps WAL until that
#    replica has received it, so a replica that falls behind can always catch up
#  - pg_hba.conf entry allowing replication connections from the Docker network
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_dev';
    SELECT pg_create_physical_replication_slot('replica1_slot');
    SELECT pg_create_physical_replication_slot('replica2_slot');
SQL

echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
