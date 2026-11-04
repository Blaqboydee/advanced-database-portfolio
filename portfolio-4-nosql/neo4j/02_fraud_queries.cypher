// =====================================================================
// OwoTrust Digital Bank (simulated) - Portfolio 4
// neo4j/02_fraud_queries.cypher : fraud analytics, where the RELATIONSHIPS are the data
//
//   cypher-shell -u neo4j -p owotrust_dev --format verbose -f .../02_fraud_queries.cypher
//
// None of these queries is told which accounts are suspicious. Each one
// searches the whole October 2026 graph (~32,000 transfers) for a PATTERN.
// =====================================================================

// G1. SHARED DEVICES: one phone used by several customers.
//     Rarely legitimate (a family tablet), and a classic sign of a mule
//     operator who opens many accounts from one handset.
MATCH (c:Customer)-[:USES]->(d:Device)
WITH d, count(c) AS customers, collect(c.name) AS names
WHERE customers >= 3
RETURN d.deviceId AS device, customers, names
ORDER BY customers DESC;

// G2. MONEY CYCLES (layering): money that returns to the account it left
//     within 24 hours, through 3-6 hops, each hop happening after the previous one.
MATCH path = (a:Account)-[rels:TRANSFERRED*3..6]->(a)
WHERE all(i IN range(1, size(rels) - 1) WHERE rels[i].at > rels[i-1].at)
  AND last(rels).at < rels[0].at + duration('PT24H')
RETURN [n IN nodes(path) | n.number]        AS cycle,
       size(rels)                           AS hops,
       [r IN rels | toInteger(r.amount)]    AS amounts,
       toString(rels[0].at)                 AS started_utc,
       duration.between(rels[0].at, last(rels).at).minutes AS minutes_to_complete;

// G3. PASS-THROUGH ACCOUNTS: received N50,000+ and sent at least 80% of it
//     onwards (transfer or ATM/POS cash-out) within 2 hours.
MATCH (src:Account)-[i:TRANSFERRED]->(a:Account)
WHERE i.amount >= 50000
OPTIONAL MATCH (a)-[o:TRANSFERRED|CASHED_OUT]->()
WHERE o.at > i.at AND o.at < i.at + duration('PT2H')
WITH a, i, src, sum(o.amount) AS moved_on, count(o) AS onward_movements
WHERE moved_on >= 0.8 * i.amount
RETURN a.number AS account, src.number AS received_from, toInteger(i.amount) AS received,
       toInteger(moved_on) AS moved_on_within_2h, onward_movements,
       round(100.0 * moved_on / i.amount) AS pct
ORDER BY toString(i.at);

// G4. FOLLOW THE MONEY from the scam victim's payment: every onward
//     transfer within 6 hours, in time order, plus where it was cashed out.
MATCH (v:Account {number: '3100000777'})-[t0:TRANSFERRED]->(m:Account)
WHERE t0.amount >= 100000
MATCH trail = (m)-[hops:TRANSFERRED*0..6]->(x:Account)
WHERE all(i IN range(0, size(hops) - 1)
          WHERE hops[i].at < t0.at + duration('PT6H')
            AND hops[i].at > CASE WHEN i = 0 THEN t0.at ELSE hops[i-1].at END)
WITH v, t0, trail, x ORDER BY length(trail) DESC LIMIT 1
OPTIONAL MATCH (x)-[c:CASHED_OUT]->(ch:CashChannel)
WHERE c.at > t0.at AND c.at < t0.at + duration('PT6H')
RETURN v.number AS victim,
       [v.number] + [n IN nodes(trail) | n.number] AS money_trail,
       [toInteger(t0.amount)] + [r IN relationships(trail) | toInteger(r.amount)] AS amounts,
       collect(ch.name + ' ' + toInteger(c.amount)) AS cashed_out_at_end;

// G5. INVESTIGATE EVERY SHARED DEVICE: what do the accounts behind it do?
//     The mule phone and the family tablet both pass G1. Their accounts'
//     behaviour separates the fraud from the false positive.
MATCH (d:Device)<-[:USES]-(c0:Customer)
WITH d, count(c0) AS users WHERE users >= 3
MATCH (d)<-[:USES]-(c:Customer)-[:OWNS]->(a:Account)
OPTIONAL MATCH (a)<-[i:TRANSFERRED]-()
WITH d, users, c, a, coalesce(sum(i.amount), 0) AS received
OPTIONAL MATCH (a)-[o:TRANSFERRED|CASHED_OUT]->()
WITH d, users, c, a, received, coalesce(sum(o.amount), 0) AS moved_on
RETURN d.deviceId AS device, c.name AS customer, c.kycTier AS kyc_tier,
       duration.inDays(a.openedAt, datetime('2026-11-01T00:00:00Z')).days AS account_age_days,
       toInteger(received) AS received_oct, toInteger(moved_on) AS moved_on_oct,
       CASE WHEN received > 0 THEN round(100.0 * moved_on / received) END AS pass_through_pct
ORDER BY device, customer;
