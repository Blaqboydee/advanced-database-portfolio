// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 5
// mongodb/sharding_setup.js : two ways to shard the SAME statement documents
// Run through the mongos router BEFORE the documents are imported.
//
//   statements_hashed    shard key { accountNumber: "hashed" }
//                        A hash of the account number decides the shard, so data
//                        and writes spread evenly. "All of one account" goes to one shard.
//   statements_by_month  shard key { month: 1 }   (range)
//                        Consecutive months live together. Easy for "all of one
//                        month", but there are only a few distinct values, and every
//                        NEW month lands in the same last range: a hot spot.
// =====================================================================

db = db.getSiblingDB("owotrust");
db.dropDatabase();
db.createCollection("statements_hashed");
db.createCollection("statements_by_month");
const primaryShard = db.getSiblingDB("config").databases.findOne({ _id: "owotrust" }).primary;
const otherShard = primaryShard === "shard1rs" ? "shard2rs" : "shard1rs";

// hashed: on an empty collection MongoDB pre-splits the hash range and spreads it across both shards
sh.shardCollection("owotrust.statements_hashed", { accountNumber: "hashed" });

// range on month: start with one chunk, then lay the months out by hand so the
// test is deterministic (balancer off for this collection):
//   [MinKey, "2026-09")  -> primary shard   (August)
//   ["2026-09", "2026-10") -> other shard   (September)
//   ["2026-10", MaxKey)  -> primary shard   (October AND every future month)
sh.shardCollection("owotrust.statements_by_month", { month: 1 });
sh.disableBalancing("owotrust.statements_by_month");
sh.splitAt("owotrust.statements_by_month", { month: "2026-09" });
sh.splitAt("owotrust.statements_by_month", { month: "2026-10" });
db.adminCommand({ moveChunk: "owotrust.statements_by_month", find: { month: "2026-09" }, to: otherShard });

print("primary shard for database owotrust: " + primaryShard);
for (const coll of ["statements_hashed", "statements_by_month"]) {
  const uuid = db.getSiblingDB("config").collections.findOne({ _id: "owotrust." + coll }).uuid;
  print("\nChunks of " + coll + ":");
  db.getSiblingDB("config").chunks.find({ uuid: uuid }).sort({ min: 1 }).forEach(c =>
    print("   " + JSON.stringify(c.min) + " -> " + JSON.stringify(c.max) + "   on " + c.shard));
}
