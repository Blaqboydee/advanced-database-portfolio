-- Graph export: which customer used which device (the USES relationship)
COPY (SELECT customer_id, device_id, platform FROM customer_device ORDER BY customer_id, device_id)
TO STDOUT WITH (FORMAT csv, HEADER);
