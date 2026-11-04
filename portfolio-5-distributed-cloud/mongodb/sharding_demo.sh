#!/usr/bin/env bash
# =====================================================================
# OwoTrust Digital Bank (simulated) - Portfolio 5
# mongodb/sharding_demo.sh : horizontal scaling with a MongoDB sharded cluster
#   loads Portfolio 4's 132,386 monthly statement documents twice (two shard keys),
#   analyses distribution and routing, then takes one shard offline.
# Requires: cluster up and mongodb/init-cluster.sh run;
#           ../portfolio-4-nosql/data/statements.ndjson (created by portfolio-4-nosql/run_all.sh)
# =====================================================================
set -uo pipefail
hdr() { echo; echo "======================================================================"; echo "$*"; echo "======================================================================"; }
say() { echo "  $*"; }
on_shard() {  # on_shard <1|2> "<js>"  - ask one shard DIRECTLY, bypassing the router
    docker exec "dist-mongo-shard$1" mongosh --quiet --port 27018 owotrust --eval "$2"
}

FILE=/portfolio/portfolio-4-nosql/data/statements.ndjson
if ! docker exec dist-mongos test -s "$FILE"; then
    echo "Missing $FILE. Run portfolio-4-nosql/run_all.sh first."; exit 1
fi
echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"

hdr "SETUP: shard both collections, then import the same documents into each"
docker exec dist-mongos mongosh --quiet /portfolio/portfolio-5-distributed-cloud/mongodb/sharding_setup.js
for coll in statements_hashed statements_by_month; do
    docker exec dist-mongos mongoimport --db owotrust --collection "$coll" --file "$FILE" \
        --numInsertionWorkers 4 2>&1 | tail -1 | sed "s/^/  $coll: /"
done

docker exec dist-mongos mongosh --quiet /portfolio/portfolio-5-distributed-cloud/mongodb/sharding_analysis.js

hdr "S5. WHERE DID THE NEW NOVEMBER WRITES GO? (each shard asked directly)"
for coll in statements_hashed statements_by_month; do
    s1=$(on_shard 1 "db.$coll.countDocuments({ month: '2026-11' })")
    s2=$(on_shard 2 "db.$coll.countDocuments({ month: '2026-11' })")
    printf '  %-22s shard1rs: %5s   shard2rs: %5s\n' "$coll" "$s1" "$s2"
done
say "-> hashed key: new writes are shared by both shards. Month range key: EVERY new write"
say "   goes to the one shard that owns the last range: a write hot spot that adding more"
say "   shards would not relieve."

hdr "S6. AVAILABILITY: one shard goes offline"
# find one account stored on each shard (from the router's own routing decision)
acct_on() {
    docker exec dist-mongos mongosh --quiet owotrust --eval "
      for (let i = 100; i < 200; i++) {
        const a = '31' + String(i).padStart(8, '0');
        const s = db.statements_hashed.find({ accountNumber: a }).explain().queryPlanner.winningPlan.shards[0].shardName;
        if (s === '$1') { print(a); break; }
      }"
}
A1=$(acct_on shard1rs); A2=$(acct_on shard2rs)
say "account $A1 lives on shard1rs; account $A2 lives on shard2rs"
docker stop dist-mongo-shard2 > /dev/null && say "dist-mongo-shard2 STOPPED"
q() {
    echo "  query: $1"
    docker exec dist-mongos mongosh --quiet owotrust --eval "
      try { $2 } catch (e) { print('    ERROR: ' + e.message.split('\n')[0].slice(0, 160)); }"
}
q "statement of $A1 (on the surviving shard)" \
  "print('    OK: ' + db.statements_hashed.countDocuments({ accountNumber: '$A1' }, { maxTimeMS: 15000 }) + ' monthly statements returned')"
q "statement of $A2 (on the stopped shard)" \
  "print('    OK: ' + db.statements_hashed.find({ accountNumber: '$A2' }).maxTimeMS(15000).toArray().length + ' statements')"
q "all October statements (needs every shard)" \
  "print('    OK: ' + db.statements_hashed.find({ month: '2026-10' }).maxTimeMS(15000).toArray().length + ' statements')"
q "same, with allowPartialResults: true (the application accepts an incomplete answer)" \
  "const r = db.runCommand({ find: 'statements_hashed', filter: { month: '2026-10' }, allowPartialResults: true,
                             batchSize: 100000, maxTimeMS: 15000 });
   print('    PARTIAL: ' + r.cursor.firstBatch.length + ' of 44,633 statements, partialResultsReturned = '
         + r.cursor.partialResultsReturned)"
say "-> customers whose data is on the healthy shard are unaffected. Queries that need the"
say "   failed shard fail, or return a partial answer if the application explicitly accepts one."
say "   This is why each shard is itself a 3-member replica set in production: a failed node"
say "   is replaced by an automatic election, and the shard stays available."
docker start dist-mongo-shard2 > /dev/null
until [ "$(docker exec dist-mongo-shard2 mongosh --quiet --port 27018 --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = true ]; do sleep 1; done
sleep 3
q "after restarting shard2: all October statements" \
  "print('    OK: ' + db.statements_hashed.find({ month: '2026-10' }).maxTimeMS(30000).toArray().length + ' statements')"
