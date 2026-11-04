// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 4
// mongodb/03_transaction.js : multi-document ACID transaction in MongoDB
//
//   mongosh --quiet /portfolio/portfolio-4-nosql/mongodb/03_transaction.js
//
// Because balances are EMBEDDED in each customer document (and copied into
// statements), one transfer touches FOUR documents: two customers and two
// statement buckets. A single-document write is always atomic in MongoDB.
// Writes across several documents need a multi-document transaction, which
// requires a replica set (that is why the container runs with --replSet rs0).
// =====================================================================

db = db.getSiblingDB("owotrust");
const FROM = "3100001000", TO = "3100000100", MONTH = "2026-11";

function snapshot(label) {
  const bal = acct => db.customers.findOne({ "accounts.accountNumber": acct }, { "accounts.$": 1 }).accounts[0].balance;
  const st = acct => db.account_statements.findOne({ _id: acct + ":" + MONTH });
  printjson({ when: label,
              [FROM]: { balance: bal(FROM), novemberEntries: st(FROM) ? st(FROM).transactions.length : 0 },
              [TO]:   { balance: bal(TO),   novemberEntries: st(TO)   ? st(TO).transactions.length   : 0 } });
}

function transfer(amountText, ref) {
  const amount = NumberDecimal(amountText);
  const session = db.getMongo().startSession();
  const customers  = session.getDatabase("owotrust").customers;
  const statements = session.getDatabase("owotrust").account_statements;
  session.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
  try {
    const fromDoc = customers.findOne({ "accounts.accountNumber": FROM }, { "accounts.$": 1 });
    const available = parseFloat(fromDoc.accounts[0].balance.toString());
    const now = new Date();

    // 1-2: the two balances (in two different customer documents)
    customers.updateOne({ "accounts.accountNumber": FROM }, { $inc: { "accounts.$.balance": NumberDecimal("-" + amountText) } });
    customers.updateOne({ "accounts.accountNumber": TO },   { $inc: { "accounts.$.balance": amount } });

    // 3-4: append to each account's November bucket; the bucket is CREATED by the
    //      first transaction of the month (upsert), which is how the pattern grows
    for (const [acct, drCr] of [[FROM, "DR"], [TO, "CR"]]) {
      statements.updateOne(
        { _id: acct + ":" + MONTH },
        { $setOnInsert: { accountNumber: acct, month: MONTH, currency: "NGN", openingBalance: NumberDecimal("0") },
          $push: { transactions: { ref: ref, at: now, type: "TRANSFER", channel: "MOBILE", drCr: drCr,
                                   amount: amount, narration: "Mongo transaction demo", balanceAfter: NumberDecimal("0") } },
          $inc:  { "totals.count": 1, ["totals." + (drCr === "DR" ? "debits" : "credits")]: amount },
          $set:  { closingBalance: NumberDecimal("0") } },
        { upsert: true });
    }

    // business rule checked INSIDE the transaction: abort means none of the 4 writes survive
    if (available < parseFloat(amountText)) {
      throw new Error("Insufficient funds: available " + available + ", requested " + amountText);
    }
    session.commitTransaction();
    print("COMMITTED " + ref + ": 4 documents changed atomically");
  } catch (e) {
    session.abortTransaction();
    print("ABORTED " + ref + " (" + e.message + "): every write of this transaction was discarded");
  } finally {
    session.endSession();
  }
}

print("=== T1. Successful transfer of N5,000 ===");
snapshot("before T1");
transfer("5000.00", "MDB-TXN-0001");
snapshot("after T1");

print("\n=== T2. Transfer of N10,000,000: the writes run, then the rule fails and the transaction aborts ===");
transfer("10000000.00", "MDB-TXN-0002");
snapshot("after T2 (identical to 'after T1')");

print("\n=== Isolation: an uncommitted write is invisible outside its transaction ===");
const s = db.getMongo().startSession();
s.startTransaction();
s.getDatabase("owotrust").customers.updateOne({ _id: 1 }, { $set: { status: "SUSPENDED" } });
printjson({ insideTransaction: s.getDatabase("owotrust").customers.findOne({ _id: 1 }).status,
            outsideTransaction: db.customers.findOne({ _id: 1 }).status });
s.abortTransaction();
s.endSession();
