// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 5
// mongodb/sharding_analysis.js : distribution, query routing, distributed aggregation
// Run through the mongos router AFTER the import.
// =====================================================================

db = db.getSiblingDB("owotrust");
function heading(t) { print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70)); }

heading("S1. DATA DISTRIBUTION across the two shards");
for (const coll of ["statements_hashed", "statements_by_month"]) {
  print("\n--- " + coll + " ---");
  printjson(db.getCollection(coll).getShardDistribution());
}

heading("S2. QUERY ROUTING: does mongos ask ONE shard or ALL of them?");
function route(coll, filter) {
  const e = db.getCollection(coll).find(filter).explain("executionStats");
  const wp = e.queryPlanner.winningPlan;
  return { collection: coll, filter: JSON.stringify(filter), routerStage: wp.stage,
           shardsAsked: wp.shards.map(s => s.shardName).join(", "),
           docsExaminedPerShard: e.executionStats.executionStages.shards
                                   .map(s => s.shardName + "=" + s.totalDocsExamined).join(", "),
           returned: e.executionStats.nReturned };
}
const routing = [
  route("statements_hashed",   { accountNumber: "3100000100" }),
  route("statements_hashed",   { month: "2026-10" }),
  route("statements_by_month", { month: "2026-10" }),
  route("statements_by_month", { accountNumber: "3100000100" }),
];
printjson(routing);
print("SINGLE_SHARD = targeted query (shard key in the filter); SHARD_MERGE = scatter-gather to every");
print("shard, with mongos merging the answers. No shard key serves every query: choose it for the");
print("most important access path. For OwoTrust that is 'statements of ONE account'.");

heading("S3. DISTRIBUTED AGGREGATION: October debits by channel, computed on both shards");
const t0 = Date.now();
const byChannel = db.statements_hashed.aggregate([
  { $match: { month: "2026-10" } },
  { $unwind: "$transactions" },
  { $match: { "transactions.drCr": "DR" } },
  { $group: { _id: "$transactions.channel", debits: { $sum: 1 }, total: { $sum: "$transactions.amount" } } },
  { $sort: { _id: 1 } }
]).toArray();
printjson(byChannel);
print("(" + (Date.now() - t0) + " ms; each shard computes a partial $group and mongos merges them.");
print(" These figures must equal Portfolio 4 M5 / PostgreSQL X1, e.g. ATM 4205 / 106165580.00.)");
const plan = db.statements_hashed.explain().aggregate([
  { $match: { month: "2026-10" } }, { $unwind: "$transactions" },
  { $group: { _id: "$transactions.channel", total: { $sum: "$transactions.amount" } } }]);
printjson({ splitPipeline: !!plan.splitPipeline, mergeType: plan.mergeType, shardsUsed: Object.keys(plan.shards) });

heading("S4. NEW WRITES: 2,000 November statement buckets, spread over the whole customer base");
const novDocs = [];
for (let i = 1; i <= 2000; i++) {
  const acct = "31" + String(i * 29).padStart(8, "0");          // every 29th account: 2,000 distinct accounts
  novDocs.push({ _id: acct + ":2026-11", accountNumber: acct, month: "2026-11", currency: "NGN",
                 openingBalance: NumberDecimal("0"), closingBalance: NumberDecimal("0"),
                 totals: { credits: NumberDecimal("0"), debits: NumberDecimal("0"), count: 0 }, transactions: [] });
}
for (const coll of ["statements_hashed", "statements_by_month"]) {
  const res = db.getCollection(coll).insertMany(novDocs, { ordered: false });
  print(coll + ": inserted " + Object.keys(res.insertedIds).length + " November documents");
}
print("(the per-shard counts of these new documents are read directly from each shard by sharding_demo.sh)");
