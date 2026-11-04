// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 4
// neo4j/01_load.cypher : build the fraud-analytics graph from the CSV exports
//
//   cypher-shell -u neo4j -p owotrust_dev -f /portfolio/portfolio-4-nosql/neo4j/01_load.cypher
//
// Graph model (property graph):
//   (:Customer)-[:OWNS]->(:Account)
//   (:Customer)-[:USES]->(:Device)
//   (:Account)-[:TRANSFERRED {ref, amount, channel, at}]->(:Account)   October 2026 transfers
//   (:Account)-[:CASHED_OUT {ref, amount, at}]->(:CashChannel)        October ATM / POS withdrawals
// Relationships are stored as direct pointers between nodes (index-free
// adjacency), so following a chain of transfers costs one hop per step, not one join.
// =====================================================================

// start from an empty graph so the script can be re-run
MATCH (n) CALL (n) { DETACH DELETE n } IN TRANSACTIONS OF 10000 ROWS;

CREATE CONSTRAINT customer_id    IF NOT EXISTS FOR (c:Customer)    REQUIRE c.customerId IS UNIQUE;
CREATE CONSTRAINT account_number IF NOT EXISTS FOR (a:Account)     REQUIRE a.number     IS UNIQUE;
CREATE CONSTRAINT device_id      IF NOT EXISTS FOR (d:Device)      REQUIRE d.deviceId   IS UNIQUE;
CREATE CONSTRAINT cash_channel   IF NOT EXISTS FOR (x:CashChannel) REQUIRE x.name       IS UNIQUE;

LOAD CSV WITH HEADERS FROM 'file:///graph_customers.csv' AS row
CALL (row) {
  CREATE (:Customer {customerId: toInteger(row.customer_id), name: row.name,
                     kycTier: toInteger(row.kyc_tier), createdAt: datetime(row.created_at)})
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///graph_accounts.csv' AS row
CALL (row) {
  MATCH (c:Customer {customerId: toInteger(row.customer_id)})
  CREATE (c)-[:OWNS]->(:Account {number: row.account_number, product: row.type_code,
                                 status: row.status, openedAt: datetime(row.opened_at)})
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///graph_devices.csv' AS row
CALL (row) {
  MATCH (c:Customer {customerId: toInteger(row.customer_id)})
  MERGE (d:Device {deviceId: row.device_id}) ON CREATE SET d.platform = row.platform
  CREATE (c)-[:USES]->(d)
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///graph_transfers.csv' AS row
CALL (row) {
  MATCH (f:Account {number: row.from_account}), (t:Account {number: row.to_account})
  CREATE (f)-[:TRANSFERRED {ref: row.reference, amount: toFloat(row.amount),
                            channel: row.channel, at: datetime(row.at)}]->(t)
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///graph_cashouts.csv' AS row
CALL (row) {
  MATCH (a:Account {number: row.account})
  MERGE (x:CashChannel {name: row.channel})
  CREATE (a)-[:CASHED_OUT {ref: row.reference, amount: toFloat(row.amount), at: datetime(row.at)}]->(x)
} IN TRANSACTIONS OF 10000 ROWS;

// what was loaded
MATCH (n) RETURN labels(n)[0] AS node_label, count(*) AS nodes ORDER BY node_label;
MATCH ()-[r]->() RETURN type(r) AS relationship, count(*) AS relationships ORDER BY relationship;
