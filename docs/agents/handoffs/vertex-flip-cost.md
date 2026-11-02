# Vertex flip-window cost — Nov 2 (billing export)

From: Muse (Engineer — Deployment), for Astro. Task: exact Vertex cost of the Nov 2 flip window (read-only).

## Status: BLOCKED — flip-window usage not yet in the billing export (no access error)

`bq` access works. The billing export simply has not caught up to the flip window yet, so the EXACT figure cannot be computed right now. Nothing below is a guess; window cost is reported as unknown, not zero.

## Export freshness (checked 2026-11-02 21:06 UTC / 13:06 PT)

- Table: `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
- Latest `usage_end_time`: **2026-11-02 13:00:00 UTC (05:00 PT)** — ~8h behind real time
- Latest `export_time`: 2026-11-02 17:45:47 UTC
- Nov 2 hourly coverage ends at the 12:00–13:00 UTC bucket (10 rows — that hour itself is still partial vs ~60–170 rows/hour for complete hours)
- Flip window 14:55–15:29 UTC (06:55–07:29 PT): **0 Vertex rows** in the export

## Exact figures available now (Nov 2 usage, 00:00–13:00 UTC only — PRE-window)

### (a) Flip window 2026-11-02 14:55–15:29 UTC: UNKNOWN (no rows exported yet)

Do not report $0 — rows are absent, not zero-cost.

### (b) Nov 2 Vertex AI total so far (through 13:00 UTC cutoff)

| | Gross | Credits | Net |
|---|---|---|---|
| Vertex AI | $1.9200 | −$0.9600 | **$0.9600** |

Raw sums: gross 1.9200139999999999, credits −0.9600129999999992, net 0.9600010000000007 (float display dust; 4dp values are exact to billing precision).

Credit applied (single credit, 203 of 217 Vertex rows): **"Gemini 3.7 Flash Launch Promotion - 50% off - include offpeak"**, −$0.9600. It halves every billed SKU below.

By project: `ayma-ai` gross $1.7852 / net $0.8926; `ayma-staging` gross $0.1348 / net $0.0674.

For reference, the prior partial check (cutoff 01:00 PT / 09:00 UTC) was Vertex net $0.8599, day ≈ $0.89 — consistent with 4 more hours of usage since.

### (c) SKUs / models (Nov 2 through 13:00 UTC; all USD)

| SKU | Rows | Gross | Credits (50% promo) | Net |
|---|---|---|---|---|
| Gemini 3.7 Flash Global Text Output - Predictions | 91 | $1.1427 | −$0.5714 | $0.5713 |
| Gemini 3.7 Flash Global Text Input - Predictions | 107 | $0.7133 | −$0.3566 | $0.3567 |
| Gemini 3.7 Flash Global Text Output - Batch Predictions | 4 | $0.0420 | −$0.0210 | $0.0210 |
| Gemini 3.7 Flash Global Text Input - Batch Predictions | 4 | $0.0220 | −$0.0110 | $0.0110 |
| Grounding with Google Search | 11 | $0.0000 | $0.0000 | $0.0000 |

Day grand total (all services, same cutoff): gross $4.0679 / net $1.0012. (Cloud Run gross $2.1067 nets to $0.0000 after its credits.)

## Queries run (BigQuery Standard SQL, project ayma-ai)

Freshness / coverage:

```sql
SELECT MAX(usage_end_time) AS latest_usage_end, MAX(export_time) AS latest_export
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`;
```

Flip-window check (returns 0 rows today; re-run for the answer):

```sql
SELECT COUNT(*) AS n, SUM(cost) AS gross,
       SUM(cost) + SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS net
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE usage_start_time >= TIMESTAMP '2026-11-02 14:55:00+00'
  AND usage_start_time < TIMESTAMP '2026-11-02 15:30:00+00'
  AND service.description = 'Vertex AI';
```

Nov 2 Vertex by SKU (swap the WHERE clause for the window above once covered):

```sql
SELECT sku.description AS sku, currency, COUNT(*) AS n, SUM(cost) AS gross,
       SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS credits,
       SUM(cost) + SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS net
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE DATE(usage_start_time) = DATE '2026-11-02'
  AND service.description = 'Vertex AI'
GROUP BY sku, currency ORDER BY net DESC;
```

Credit names:

```sql
SELECT c.name AS credit_name, SUM(c.amount) AS amount, COUNT(*) AS n
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`, UNNEST(credits) AS c
WHERE DATE(usage_start_time) = DATE '2026-11-02'
  AND service.description = 'Vertex AI'
GROUP BY credit_name ORDER BY amount;
```

## Retry instruction

Re-run the freshness query; once `MAX(usage_end_time)` is past 2026-11-02 16:00 UTC (1h margin past the window), re-run the flip-window query plus the SKU/credit queries with the window WHERE clause. At the observed ~8h lag, Nov 2 evening PT / Nov 3 morning UTC should cover it. No GCP changes were made (read-only; only `bq query` SELECTs).

## Caveats

- The 50% Gemini 3.7 Flash launch promo applied to all billed pre-window Vertex rows, but do NOT assume it applies to the flip-window rows until they are queried.
- The 12:00–13:00 UTC hour is partial (10 rows), so even the "through 13:00 UTC" figures will grow slightly for that hour.
- Staging vs prod split for the window must come from the window rows themselves (`project.id`); pre-window staging Vertex net ($0.0674) is unrelated traffic.
