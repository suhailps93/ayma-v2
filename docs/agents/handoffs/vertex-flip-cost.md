# Vertex flip-window cost — Nov 2 (billing export)

From: Muse (Engineer — Deployment), for Astro. Task: exact Vertex cost of the Nov 2 flip window (read-only).

## Status: BLOCKED — flip window still not fully exported (no access error)

`bq` access works. Retry check at 2026-11-02 23:45 UTC / 15:45 PT: `MAX(usage_end_time)` advanced to
**2026-11-02 17:00:00 UTC**, but the **15:00–16:00 UTC bucket — holding 15:00–15:29 of the flip window —
has 0 rows across ALL services** (export hole / delayed file; the 16:00-bucket rows landed 21:38 UTC).
The EXACT 14:55–15:29 UTC figure is still not computable. Nothing below is a guess; the window cost
is reported as unknown, not zero.

Structural finding this retry: **Vertex rows are hourly-aggregated** (0 of 287 Nov-2 Vertex rows have
a sub-hour `usage_start_time`). Even once the 15:00 bucket lands, the export can only give exact
HOURLY figures (14:00–15:00 and 15:00–16:00 buckets); isolating exactly 14:55–15:29 from the export
alone is impossible — the 14:00 bucket mixes 5 window minutes with 55 pre-flip minutes, and the
15:00 bucket will mix 29 window minutes with 31 post-window minutes. Founder call: whether the two
exact hourly buckets suffice, or the window figure stays an estimate bounded by them.

## Export freshness (checked 2026-11-02 23:45 UTC / 15:45 PT)

- Table: `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
- Latest `usage_end_time`: **2026-11-02 17:00:00 UTC (09:00 PT)** — ~7h behind real time
- Latest `export_time`: 2026-11-02 21:51:42 UTC
- Hourly-bucket row counts (all services), 12:00–17:00 UTC: 12h ✓, 13h ✓, 14h ✓ (25 Vertex rows),
  **15h MISSING (0 rows, every service)**, 16h ✓ (60 rows, exported 21:38 UTC)
- Flip window 14:55–15:29 UTC (06:55–07:29 PT): minute-level query still returns **0 rows** —
  not because cost is zero, but because rows only exist on hour boundaries and the 15:00 bucket is absent

## Exact figures available now

### (a) Flip window 2026-11-02 14:55–15:29 UTC: UNKNOWN (15:00 bucket not yet exported)

Do not report $0 — rows are absent, not zero-cost.

Closest exact enclosing figure (hourly bucket, NOT the window): 14:00–15:00 UTC Vertex AI:

| Project | Rows | Gross | Credits (50% promo) | Net |
|---|---|---|---|---|
| ayma-staging | 12 | $0.1897 | −$0.0948 | **$0.0948** |
| ayma-ai | 13 | $0.0233 | −$0.0116 | $0.0116 |
| Total 14:00 bucket | 25 | $0.2130 | −$0.1065 | $0.1065 |

Raw: staging gross 0.189689 / net 0.094847; ayma-ai gross 0.023262 / net 0.011627.
This bucket contains only 5 window minutes (14:55–15:00) plus 55 pre-flip minutes — do not quote it as the window cost.

Corroborating (non-cost) signal: staging Vertex collapses to ~$0 in the 16:00 bucket (1 row, gross
$0.000005) — consistent with the ~15:34 UTC revert; and the 13:00 bucket staging Vertex was $0.0005
gross. The flip traffic spike sits in the 14:00 + missing 15:00 buckets.

### (b) Nov 2 Vertex AI total so far (00:00–17:00 UTC buckets as exported; 15:00 bucket missing)

| | Gross | Credits | Net |
|---|---|---|---|
| Vertex AI (287 rows) | $2.4119 | −$1.2057 | **$1.2062** |

Raw sums: gross 2.411938, credits −1.205744, net 1.206194. NOT a full-day total: the 15:00 bucket
is missing and usage after 17:00 UTC is not yet exported (real time 23:45 UTC).

Staging vs prod, new buckets since the 13:06 PT check (net): 13h staging $0.0005; 14h staging
$0.0948 / ayma-ai $0.0116; 16h ayma-ai $0.0742 / staging ~$0.0000.

### (c) SKUs / models (14:00–15:00 bucket — the window-adjacent hour; all USD)

| Project | SKU | Rows | Gross | Credits (50% promo) | Net |
|---|---|---|---|---|---|
| ayma-staging | Gemini 3.7 Flash Global Text Input - Predictions | 5 | $0.1091 | −$0.0545 | $0.0545 |
| ayma-staging | Gemini 3.7 Flash Global Text Output - Predictions | 5 | $0.0788 | −$0.0394 | $0.0394 |
| ayma-staging | Gemini 3.7 Flash Global Text Input Caching | 2 | $0.0018 | −$0.0009 | $0.0009 |
| ayma-ai | Gemini 3.7 Flash Global Text Output - Predictions | 6 | $0.0118 | −$0.0059 | $0.0059 |
| ayma-ai | Gemini 3.7 Flash Global Text Input - Predictions | 7 | $0.0115 | −$0.0057 | $0.0057 |

Credit applied: **"Gemini 3.7 Flash Launch Promotion - 50% off - include offpeak"** — still halving
every billed Vertex row, including the new buckets. (Full-day SKU table from the 13:06 PT check
stands for the earlier buckets; re-run the SKU query below for the final full-day table once the
15:00 bucket lands.)

## Queries run (BigQuery Standard SQL, project ayma-ai)

Freshness / coverage:

```sql
SELECT MAX(usage_end_time) AS latest_usage_end, MAX(export_time) AS latest_export, COUNT(*) AS n
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`;
```

Hourly coverage by service (reveals the 15:00-bucket hole):

```sql
SELECT TIMESTAMP_TRUNC(usage_start_time, HOUR) AS h, service.description AS svc, COUNT(*) AS n
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE usage_start_time >= TIMESTAMP '2026-11-02 12:00:00+00'
  AND usage_start_time < TIMESTAMP '2026-11-02 18:00:00+00'
GROUP BY h, svc ORDER BY h, svc;
```

Granularity proof (subhour_rows = 0 → hourly aggregates only):

```sql
SELECT COUNT(*) AS n_vertex_nov2,
       COUNTIF(EXTRACT(MINUTE FROM usage_start_time) != 0 OR EXTRACT(SECOND FROM usage_start_time) != 0) AS subhour_rows,
       COUNT(DISTINCT usage_start_time) AS distinct_buckets
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE DATE(usage_start_time) = DATE '2026-11-02' AND service.description = 'Vertex AI';
```

Exact hourly-bucket figure (re-run with the 15:00 bucket once it lands; swap timestamps):

```sql
SELECT project.id AS proj, sku.description AS sku, COUNT(*) AS n, SUM(cost) AS gross,
       SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS credits,
       SUM(cost) + SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS net
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE usage_start_time >= TIMESTAMP '2026-11-02 14:00:00+00'
  AND usage_start_time < TIMESTAMP '2026-11-02 15:00:00+00'
  AND service.description = 'Vertex AI'
GROUP BY proj, sku ORDER BY proj, net DESC;
```

Nov 2 Vertex by hour × project (shows the 15:00 gap inline):

```sql
SELECT TIMESTAMP_TRUNC(usage_start_time, HOUR) AS h, project.id AS proj, COUNT(*) AS n,
       SUM(cost) AS gross,
       SUM(cost) + SUM((SELECT COALESCE(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) AS net
FROM `ayma-ai.billing_export.gcp_billing_export_resource_v1_01F253_37B91E_1A2E78`
WHERE DATE(usage_start_time) = DATE '2026-11-02' AND service.description = 'Vertex AI'
GROUP BY h, proj ORDER BY h, proj;
```

## Retry instruction

Re-run the freshness query AND the hourly-coverage query — `MAX(usage_end_time)` alone is not
sufficient proof, since the 15:00 bucket is missing while later buckets exist. Done when the 15:00
bucket shows rows for Vertex AI. Then report the two exact hourly buckets (14:00 + 15:00) with the
bucket query above, and flag to the founder that exact 14:55–15:29 isolation is impossible from this
export (hourly granularity). No GCP changes were made (read-only; only `bq query` SELECTs).

## Caveats

- The 50% Gemini 3.7 Flash launch promo applied to all billed Vertex rows through the 16:00 bucket,
  but do NOT assume it applies to the missing 15:00-bucket rows until they are queried.
- The 15:00-bucket hole affects all services (0 rows), so it is an export delay, not zero usage.
- Prior partial check (cutoff 01:00 PT / 09:00 UTC): Vertex net $0.8599, day ≈ $0.89. First retry
  cutoff (13:00 UTC): Vertex net $0.9600. Current (17:00 UTC buckets minus the 15:00 hole): $1.2062.
