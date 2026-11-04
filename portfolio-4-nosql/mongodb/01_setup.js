// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 4
// mongodb/01_setup.js : create the collections WITH schema validation
//
//   mongosh --quiet /portfolio/portfolio-4-nosql/mongodb/01_setup.js
//
// "Schemaless" does not have to mean "no rules": $jsonSchema validators make
// MongoDB reject malformed documents, while still allowing optional and
// differently shaped fields (e.g. KYC documents that vary by type).
// Run BEFORE mongoimport, so every imported document is validated.
// =====================================================================

db = db.getSiblingDB("owotrust");
db.dropDatabase();

const money = { bsonType: "decimal" };   // Decimal128: exact, like NUMERIC(18,2)

db.createCollection("customers", {
  validationLevel: "strict",
  validationAction: "error",
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "bvn", "name", "contact", "status", "kyc", "accounts", "createdAt"],
    properties: {
      _id:     { bsonType: "int" },
      bvn:     { bsonType: "string", pattern: "^[0-9]{11}$" },
      name:    { bsonType: "object", required: ["first", "last"],
                 properties: { first: { bsonType: "string" }, last: { bsonType: "string" } } },
      contact: { bsonType: "object", required: ["phone"],
                 properties: { phone: { bsonType: "string", pattern: "^\\+234[0-9]{10}$" },
                               email: { bsonType: "string" } } },
      status:  { enum: ["ACTIVE", "SUSPENDED", "CLOSED"] },
      kyc: {
        bsonType: "object", required: ["tier", "dailyDebitLimit", "documents"],
        properties: {
          tier:            { bsonType: "int", minimum: 1, maximum: 3 },
          dailyDebitLimit: money,
          documents: {     // items may have different fields; only "type" is mandatory
            bsonType: "array",
            items: { bsonType: "object", required: ["type"],
                     properties: { type: { enum: ["NIN", "UTILITY_BILL", "INTL_PASSPORT", "DRIVERS_LICENCE"] } } }
          }
        }
      },
      accounts: {
        bsonType: "array", minItems: 1,
        items: { bsonType: "object",
                 required: ["accountNumber", "product", "currency", "role", "status", "balance"],
                 properties: { accountNumber: { bsonType: "string", pattern: "^[0-9]{10}$" },
                               role: { enum: ["PRIMARY", "JOINT"] },
                               balance: money } }
      },
      devices:   { bsonType: "array" },
      createdAt: { bsonType: "date" }
    }
  } }
});

db.createCollection("account_statements", {
  validationLevel: "strict",
  validationAction: "error",
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "accountNumber", "month", "currency", "openingBalance", "closingBalance", "totals", "transactions"],
    properties: {
      _id:            { bsonType: "string", pattern: "^[0-9]{10}:[0-9]{4}-[0-9]{2}$" },
      accountNumber:  { bsonType: "string", pattern: "^[0-9]{10}$" },
      month:          { bsonType: "string", pattern: "^[0-9]{4}-[0-9]{2}$" },
      openingBalance: money,
      closingBalance: money,
      transactions: {  // the bucket is bounded: one month per document, so the array cannot grow without limit
        bsonType: "array", maxItems: 2000,
        items: { bsonType: "object", required: ["ref", "at", "type", "drCr", "amount", "balanceAfter"],
                 properties: { drCr: { enum: ["DR", "CR"] }, amount: money, balanceAfter: money, at: { bsonType: "date" } } }
      }
    }
  } }
});

printjson(db.getCollectionInfos().map(c => ({ collection: c.name, validationAction: c.options.validationAction })));
