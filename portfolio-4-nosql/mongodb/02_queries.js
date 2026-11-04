// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 4
// mongodb/02_queries.js : document-model queries, indexes, aggregation,
//                         validation and schema evolution
//
//   mongosh --quiet /portfolio/portfolio-4-nosql/mongodb/02_queries.js
// =====================================================================

db = db.getSiblingDB("owotrust");

function heading(t) { print("\n" + "=".repeat(70) + "\n" + t + "\n" + "=".repeat(70)); }

// compact summary of an explain("executionStats") result
function plan(explainResult) {
  const wp = explainResult.queryPlanner.winningPlan;
  const stages = [];
  let s = wp.queryPlan || wp;             // MongoDB 7 may wrap the plan in "queryPlan"
  while (s) {
    stages.push(s.stage + (s.indexName ? "(" + s.indexName + (s.isMultiKey ? ", multikey" : "") + ")" : ""));
    s = s.inputStage;
  }
  const st = explainResult.executionStats;
  return { plan: stages.join(" <- "), keysExamined: st.totalKeysExamined,
           docsExamined: st.totalDocsExamined, returned: st.nReturned, timeMs: st.executionTimeMillis };
}

// ---------------------------------------------------------------------
heading("M1. CUSTOMER 360 for the mobile app: ONE document read");
// Relational equivalent: customer + kyc_tier + account_holder + account +
// account_type + branch + customer_device = a 7-table join.
const phone = "+2348100001000";
print("Before indexing contact.phone:");
printjson(plan(db.customers.find({ "contact.phone": phone }).explain("executionStats")));
db.customers.createIndex({ "contact.phone": 1 }, { unique: true, name: "ux_contact_phone" });
print("After  db.customers.createIndex({ 'contact.phone': 1 }, { unique: true }):");
printjson(plan(db.customers.find({ "contact.phone": phone }).explain("executionStats")));
print("The document (everything the app's home screen needs):");
printjson(db.customers.findOne({ "contact.phone": phone }));

// ---------------------------------------------------------------------
heading("M2. WHO OWNS AN ACCOUNT? Query INSIDE an embedded array (multikey index)");
print("Before indexing accounts.accountNumber:");
printjson(plan(db.customers.find({ "accounts.accountNumber": "3900000003" }).explain("executionStats")));
db.customers.createIndex({ "accounts.accountNumber": 1 }, { name: "ix_accounts_number" });
print("After indexing (one index entry per array element = MULTIKEY index):");
printjson(plan(db.customers.find({ "accounts.accountNumber": "3900000003" }).explain("executionStats")));
printjson(db.customers.findOne({ "accounts.accountNumber": "3900000003" },
                               { _id: 1, name: 1, "kyc.tier": 1, createdAt: 1, "accounts.$": 1, devices: 1 }));

// ---------------------------------------------------------------------
heading("M3. KYC COMPLIANCE over documents of DIFFERENT shapes");
print("Tier counts and how many KYC documents customers in each tier hold:");
printjson(db.customers.aggregate([
  { $group: { _id: "$kyc.tier", customers: { $sum: 1 }, avgDocuments: { $avg: { $size: "$kyc.documents" } } } },
  { $sort: { _id: 1 } }
]).toArray());

const today = ISODate("2026-11-04T00:00:00Z");
print("Tier-3 customers whose passport OR driver's licence has EXPIRED ($elemMatch: both");
print("conditions must hold for the SAME array element; tier 1/2 documents have no expiry field at all):");
print(db.customers.countDocuments({
  "kyc.tier": 3,
  "kyc.documents": { $elemMatch: { type: { $in: ["INTL_PASSPORT", "DRIVERS_LICENCE"] }, expiresOn: { $lt: today } } }
}));
print("Customers whose utility bill did NOT match their address (field exists only on UTILITY_BILL items):");
print(db.customers.countDocuments({ "kyc.documents": { $elemMatch: { type: "UTILITY_BILL", addressMatched: false } } }));
print("Example of an expired-document customer (kyc only):");
printjson(db.customers.findOne(
  { "kyc.documents": { $elemMatch: { type: "INTL_PASSPORT", expiresOn: { $lt: today } } } },
  { _id: 1, name: 1, kyc: 1 }));

// ---------------------------------------------------------------------
heading("M4. MONTHLY STATEMENT: one document per account per month (bucket pattern)");
printjson(plan(db.account_statements.find({ _id: "3100000100:2026-10" }).explain("executionStats")));
const st = db.account_statements.findOne({ _id: "3100000100:2026-10" });
printjson({ _id: st._id, openingBalance: st.openingBalance, closingBalance: st.closingBalance,
            totals: st.totals, transactionsEmbedded: st.transactions.length,
            firstTransaction: st.transactions[0], lastTransaction: st.transactions[st.transactions.length - 1] });
print("Cross-check with Portfolio 2 query Q2 (same account, same month): 11 rows, closing balance 5100.00");

// ---------------------------------------------------------------------
heading("M5. AGGREGATION PIPELINE: October 2026 debits by channel");
const byChannel = db.account_statements.aggregate([
  { $match: { month: "2026-10" } },
  { $unwind: "$transactions" },
  { $match: { "transactions.drCr": "DR" } },
  { $group: { _id: "$transactions.channel", debits: { $sum: 1 }, total: { $sum: "$transactions.amount" } } },
  { $sort: { _id: 1 } }
]).toArray();
printjson(byChannel);
print("(run_all.sh runs the same calculation in PostgreSQL; the two must agree)");

// ---------------------------------------------------------------------
heading("M6. AGGREGATION with $lookup: top 5 spenders in October 2026");
printjson(db.account_statements.aggregate([
  { $match: { month: "2026-10" } },
  { $group: { _id: "$accountNumber", spent: { $sum: "$totals.debits" } } },
  { $sort: { spent: -1 } },
  { $limit: 5 },
  { $lookup: { from: "customers", localField: "_id", foreignField: "accounts.accountNumber", as: "owner" } },
  { $project: { _id: 0, account: "$_id", spent: 1,
                customer: { $concat: [{ $first: "$owner.name.first" }, " ", { $first: "$owner.name.last" }] },
                tier: { $first: "$owner.kyc.tier" } } }
]).toArray());

// ---------------------------------------------------------------------
heading("M7. SCHEMA VALIDATION rejects a malformed customer");
try {
  db.customers.insertOne({
    _id: 999999, bvn: "2210000", name: { first: "Bad", last: "Data" },
    contact: { phone: "08031234567" }, status: "ACTIVE",
    kyc: { tier: 4, dailyDebitLimit: NumberDecimal("50000"), documents: [] },
    accounts: [], createdAt: new Date()
  });
  print("UNEXPECTED: insert succeeded");
} catch (e) {
  print("Rejected: " + e.message);
  const details = e.errInfo.details.schemaRulesNotSatisfied[0].propertiesNotSatisfied
                    .map(p => p.propertyName + " -> " + JSON.stringify(p.details.map(d => d.reason || d.operatorName)));
  printjson(details);
}

// ---------------------------------------------------------------------
heading("M8. SCHEMA EVOLUTION without a migration");
// The app starts capturing NDPR marketing consent. In PostgreSQL this would
// need ALTER TABLE (and a deploy step). Here, new documents simply carry the field.
db.customers.updateOne({ _id: 1 }, { $set: { consents: { marketingSms: false, dataSharing: true,
                                                         recordedAt: ISODate("2026-11-04T09:00:00Z") } } });
printjson({ withConsents: db.customers.countDocuments({ consents: { $exists: true } }),
            withoutConsents: db.customers.countDocuments({ consents: { $exists: false } }) });

// ---------------------------------------------------------------------
heading("STORAGE");
for (const name of ["customers", "account_statements"]) {
  const s = db.getCollection(name).stats();
  printjson({ collection: name, documents: s.count, avgDocumentBytes: s.avgObjSize,
              dataMB: +(s.size / 1048576).toFixed(1), storageMB_compressed: +(s.storageSize / 1048576).toFixed(1),
              indexes: Object.keys(s.indexSizes), indexMB: +(s.totalIndexSize / 1048576).toFixed(1) });
}
