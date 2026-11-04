#!/usr/bin/env bash
# Initialises the MongoDB sharded cluster defined in docker-compose.cluster.yml.
# Safe to re-run: each step is skipped if it was already done.
#   config server replica set "cfgrs"  : stores which chunk of data lives on which shard
#   shards "shard1rs" and "shard2rs"   : each holds part of the data (a 1-node replica
#                                        set here; 3 nodes in production)
#   mongos                             : the router the application connects to
set -euo pipefail

ms() { docker exec "$1" mongosh --quiet --port "$2" --eval "$3"; }
init_rs() {  # container port rs_id extra
    ms "$1" "$2" "try { rs.status().ok } catch (e) {
        rs.initiate({_id: '$3', $4 members: [{_id: 0, host: '${1#dist-}:$2'}]}).ok }" >/dev/null
    until [ "$(ms "$1" "$2" 'db.hello().isWritablePrimary')" = true ]; do sleep 1; done
    echo "replica set $3 ready"
}

init_rs dist-mongo-cfg    27019 cfgrs    "configsvr: true,"
init_rs dist-mongo-shard1 27018 shard1rs ""
init_rs dist-mongo-shard2 27018 shard2rs ""

# mongos may have started before the config server was ready: wait for it
until docker exec dist-mongos mongosh --quiet --eval 'db.adminCommand({ping: 1}).ok' >/dev/null 2>&1; do sleep 1; done
docker exec dist-mongos mongosh --quiet --eval '
  const have = db.adminCommand({listShards: 1}).shards.map(s => s._id);
  for (const s of ["shard1rs/mongo-shard1:27018", "shard2rs/mongo-shard2:27018"]) {
    if (!have.includes(s.split("/")[0])) sh.addShard(s);
  }
  printjson(db.adminCommand({listShards: 1}).shards.map(s => ({ shard: s._id, host: s.host, state: s.state })));'
