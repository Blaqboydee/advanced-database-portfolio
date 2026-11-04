-- pgbench script: one card-funding deposit into a random ACTIVE naira account
-- (account_ids of the 16 active NGN accounts in the Portfolio 1 sample data)
\set i random(1, 16)
SELECT post_deposit((SELECT account_number FROM account
                     WHERE account_id = (ARRAY[1,2,3,4,5,6,7,9,10,11,12,14,15,17,18,19])[:i]), 100);
