#!/usr/bin/env bash
# =====================================================================
# OwoTrust Digital Bank (simulated) - Portfolio 4
# redis/redis_demo.sh : key-value model (Redis) for the bank's FAST,
#                       SHORT-LIVED data
#
# Redis keeps everything in memory, and each key can expire on its own (TTL).
# That suits data that is read and written constantly, is only valid for
# seconds or minutes, and can be rebuilt if lost. It does NOT suit the
# ledger (see R8).
#
# Key naming convention:  <purpose>:<identifier>[:<window>]
# Usage: ./redis_demo.sh        (requires: docker compose --profile nosql up -d)
# =====================================================================
set -euo pipefail

r()   { echo "redis> $*"; docker exec owotrust-redis redis-cli --no-raw "$@" | sed 's/^/        /'; }
say() { echo "  $*"; }
hdr() { echo; echo "======================================================================"; echo "$*"; echo "======================================================================"; }

docker exec owotrust-redis redis-cli FLUSHALL >/dev/null
echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z'); $(docker exec owotrust-redis redis-server --version | cut -d' ' -f1-3)"

hdr "R1. LOGIN SESSIONS: a key that deletes itself after 15 minutes of inactivity"
r SET session:9f2c41d7e8 '{"customerId":1015,"deviceId":"dev-694cac15d72d","kycTier":2}' EX 900
r GET session:9f2c41d7e8
r TTL session:9f2c41d7e8
say "Each API call slides the expiry forward (keep-alive):"
r EXPIRE session:9f2c41d7e8 900
say "A hash keeps the session's fields individually addressable:"
r HSET sess:9f2c41d7e8 customerId 1015 deviceId dev-694cac15d72d kycTier 2 lastSeen 2026-11-04T09:00:00Z
r HGET sess:9f2c41d7e8 kycTier
r EXPIRE sess:9f2c41d7e8 900

hdr "R2. ONE-TIME PASSWORDS (OTP) for transfer confirmation"
say "SET ... NX only succeeds if no OTP is active, which stops repeated OTP requests flooding the customer:"
r SET otp:+2348100001000 482913 EX 120 NX
r SET otp:+2348100001000 111111 EX 120 NX
say "Wrong guesses are counted; the counter expires on its own:"
for guess in 1 2 3; do r INCR otp_attempts:+2348100001000; done
r EXPIRE otp_attempts:+2348100001000 900
say "(the application refuses further guesses once the counter reaches 3)"
say "Correct code: verify, then DEL so the code cannot be used twice:"
r GET otp:+2348100001000
r DEL otp:+2348100001000
say "Expiry in action, with an OTP of 2 seconds:"
r SET otp:demo 999999 EX 2
sleep 2.5
r GET otp:demo

hdr "R3. RATE LIMITING: at most 5 transfers per customer per minute"
say "A Lua script makes INCR + EXPIRE ONE atomic step on the server, so two app servers"
say "cannot both see count = 5 and let a 6th transfer through:"
LUA='local c = redis.call("INCR", KEYS[1]); if c == 1 then redis.call("EXPIRE", KEYS[1], ARGV[1]) end; return c'
window=$(( $(date +%s) / 60 ))
for attempt in 1 2 3 4 5 6 7; do
    count=$(docker exec owotrust-redis redis-cli EVAL "$LUA" 1 "rl:transfer:1015:$window" 60)
    if [ "$count" -le 5 ]; then verdict="ALLOWED"; else verdict="BLOCKED (429 Too Many Requests)"; fi
    echo "   transfer attempt $attempt  ->  count in this minute = $count  ->  $verdict"
done
r TTL "rl:transfer:1015:$window"

hdr "R4. IDEMPOTENCY KEYS (the same idea as Portfolio 3 D6, checked before PostgreSQL is touched)"
r SET idem:APP-REQ-000555 PROCESSING NX EX 86400
say "The app times out and re-sends the same request:"
r SET idem:APP-REQ-000555 PROCESSING NX EX 86400
say "(nil) = key already exists, so this is a duplicate and is rejected without hitting the database"
r SET idem:APP-REQ-000555 COMPLETED:TRF000000004711 XX KEEPTTL
r GET idem:APP-REQ-000555

hdr "R5. LIVE LEADERBOARD (sorted set) fed from the SAME PostgreSQL data"
say "Every transaction on 31 Oct 2026 adds 1 to the score of each account it touched:"
docker exec owotrust-pg psql -X -At -U owotrust -d owotrust_bank -c "
    SELECT 'ZINCRBY busiest:2026-10-31 1 ' || a.account_number
    FROM bank_transaction t
    JOIN account a ON a.account_id IN (t.debit_account_id, t.credit_account_id)
    WHERE t.status = 'COMPLETED'
      AND t.created_at >= TIMESTAMPTZ '2026-10-31 00:00+01' AND t.created_at < TIMESTAMPTZ '2026-11-01 00:00+01'" \
  | docker exec -i owotrust-redis redis-cli > /dev/null
r ZCARD busiest:2026-10-31
say "Top 5 (kept sorted on every update, so reading it costs O(log n), not a GROUP BY):"
r ZREVRANGE busiest:2026-10-31 0 4 WITHSCORES
say "Where does one account rank? (0-based: 3 = 4th place)"
r ZREVRANK busiest:2026-10-31 3100000037
r ZSCORE busiest:2026-10-31 3100000037
say "The same question asked of PostgreSQL (must agree with the top 5 above):"
docker exec owotrust-pg psql -X -U owotrust -d owotrust_bank -c "
    SELECT a.account_number, COUNT(*) AS transactions
    FROM bank_transaction t
    JOIN account a ON a.account_id IN (t.debit_account_id, t.credit_account_id)
    WHERE t.status = 'COMPLETED'
      AND t.created_at >= TIMESTAMPTZ '2026-10-31 00:00+01' AND t.created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
    GROUP BY a.account_number ORDER BY transactions DESC, a.account_number DESC LIMIT 5;" | sed 's/^/        /'

hdr "R6. CACHE-ASIDE: balance enquiries served from memory for 30 seconds"
r GET cache:balance:3100000100
say "(nil) = cache miss -> read PostgreSQL, then store the answer with a short TTL:"
bal=$(docker exec owotrust-pg psql -X -At -U owotrust -d owotrust_bank -c "SELECT balance FROM account WHERE account_number = '3100000100'")
r SET cache:balance:3100000100 "$bal" EX 30
r GET cache:balance:3100000100
say "When a transfer posts, the app deletes the key so the next read is fresh:"
r DEL cache:balance:3100000100

hdr "R7. THROUGHPUT (redis-benchmark, 50 clients, 100,000 requests each test)"
docker exec owotrust-redis redis-benchmark -q -n 100000 -c 50 -t set,get,incr | tr '\r' '\n' | grep 'requests per second' | sed 's/^ */   /'
say "With pipelining (16 commands per round trip):"
docker exec owotrust-redis redis-benchmark -q -n 100000 -c 50 -P 16 -t set,get,incr | tr '\r' '\n' | grep 'requests per second' | sed 's/^ */   /'

hdr "R8. WHY THE LEDGER STAYS IN POSTGRESQL"
r CONFIG GET appendonly
r CONFIG GET save
r INFO persistence | grep -E 'aof_enabled|rdb_last_save_time|rdb_changes_since_last_save' || true
say "With the default settings Redis persists only periodic snapshots (RDB), and the"
say "append-only file is OFF. A crash can lose the writes since the last snapshot,"
say "which is acceptable for sessions, OTPs and counters, and unacceptable for money."
r INFO memory | grep -E '^ *used_memory_human' || true
