-- pgbench script: ONE random transfer between two of the 16 ACTIVE naira
-- accounts (see stress_account() in ../sql/04_stress_test.sql).
-- pgbench runs this script many times from many concurrent clients.
-- dst is computed so that it is never equal to src.
\set src random(1, 16)
\set dst 1 + (:src + random(0, 14)) % 16
\set amount random(100, 2000)
SELECT transfer_funds_naive(stress_account(:src), stress_account(:dst), :amount);
