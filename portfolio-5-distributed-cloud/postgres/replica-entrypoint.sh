#!/bin/bash
# Entry point of a replica container. Usage: replica-entrypoint.sh <replica1|replica2>
#
# On first start the data directory is empty, so the replica clones the
# primary with pg_basebackup (a full physical copy, streaming the WAL written
# meanwhile). It then records how to reach the primary, and creates
# standby.signal so PostgreSQL starts as a read-only HOT STANDBY that
# continuously replays the primary's WAL.
set -e
NAME="$1"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[$NAME] waiting for the primary..."
    until pg_isready -h pg-primary -p 5432 -q; do sleep 1; done

    echo "[$NAME] cloning the primary with pg_basebackup"
    rm -rf "${PGDATA:?}"/*
    PGPASSWORD=replicator_dev pg_basebackup -h pg-primary -U replicator -D "$PGDATA" \
        --wal-method=stream --slot="${NAME}_slot" --checkpoint=fast

    cat >> "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=pg-primary port=5432 user=replicator password=replicator_dev application_name=$NAME'
primary_slot_name = '${NAME}_slot'
EOF
    touch "$PGDATA/standby.signal"
    chmod 700 "$PGDATA"
fi

# hot_standby: accept read-only queries while replaying
# hot_standby_feedback: tell the primary which rows replica queries still need
exec postgres -c hot_standby=on -c hot_standby_feedback=on
