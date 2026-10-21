## Golden queries

1. ###### *Identify the correlation between usage amount and cost for each service description, filtering for services with average cost greater than $100.*

```sql
SELECT
  service.description,
  CORR(usage.amount, cost) AS correlation
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1
HAVING
  AVG(cost) > 100;
```

2. ###### *Calculate the cost variation (standard deviation) for each location's region, considering only costs above the 75th percentile.*

```sql
SELECT
  location.region,
  STDDEV(cost) AS cost_stddev
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  cost > (
    SELECT
      APPROX_QUANTILES(cost, 4)[OFFSET(3)]
    FROM
      `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
    WHERE
      time_stamp
        BETWEEN TIMESTAMP('2026-01-01 00:00:00')
        AND TIMESTAMP('2026-03-01 00:00:00')
  )
  AND time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1;
```

3. ###### *Calculate the month-over-month percentage change in cost for each SKU description.*

```sql
SELECT
  invoice.month,
  sku.description,
  SAFE_DIVIDE(
    (
      SUM(cost)
      - LAG(SUM(cost), 1, 0)
        OVER (PARTITION BY sku.description ORDER BY invoice.month)
    ),
    LAG(SUM(cost), 1, 0)
      OVER (PARTITION BY sku.description ORDER BY invoice.month)
  ) AS percentage_change
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1, 2
ORDER BY
  1, 2;
```

4. ###### *Calculate the population variance of cost for each project name to assess the spread of costs across different projects, filtered by usage end time.*

```sql
SELECT
  project.name,
  VAR_POP(cost) AS cost_variance
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  usage_end_time
    BETWEEN TIMESTAMP('2026-01-01 00:00:00 UTC')
    AND TIMESTAMP('2026-01-31 23:59:59 UTC')
  AND time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00 UTC')
    AND TIMESTAMP('2026-06-01 00:00:00 UTC')
GROUP BY
  project.name;
```

5. ###### *Identify the top 5 SKUs with the highest average cost at list to understand which resources are generally the most expensive, filtering by invoice month.*

```sql
SELECT
  sku.description,
  AVG(cost_at_list) AS avg_cost_at_list
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
WHERE
  invoice.month = '202607'
  AND time_stamp >= TIMESTAMP(
    DATE_SUB(PARSE_DATE('%Y%m', '202607'), INTERVAL 1 DAY), 'UTC')
  AND time_stamp < TIMESTAMP(
    DATE_ADD(LAST_DAY(PARSE_DATE('%Y%m', '202607'), MONTH), INTERVAL 2 DAY),
    'UTC')
GROUP BY
  sku.description
ORDER BY
  avg_cost_at_list DESC
LIMIT 5;
```

6. ###### *Calculate the monthly cost distribution across different service descriptions, showing the median cost for each service.*

```sql
SELECT
  invoice.month,
  service.description,
  APPROX_QUANTILES(cost, 2)[OFFSET(1)] AS median_cost
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1, 2;
```

7. ###### *Identify the top 3 project IDs with the highest cost and their corresponding average usage amount in pricing units.*

```sql
SELECT
  project.id,
  AVG(usage.amount_in_pricing_units) AS avg_usage
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1
ORDER BY
  SUM(cost) DESC
LIMIT 3;
```

8. ###### *Determine the percentage contribution of each SKU description to the total cost, grouped by invoice month.*

```sql
SELECT
  invoice.month,
  sku.description,
  SUM(cost)
    / (
      SELECT
        SUM(cost)
      FROM
        `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
      WHERE
        time_stamp
          BETWEEN TIMESTAMP('2026-01-01 00:00:00')
          AND TIMESTAMP('2026-03-01 00:00:00')
    ) AS percentage_contribution
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY
  1, 2;
```

9. ###### *Determine the top 5 most expensive SKUs each month and their contribution to the total cost.*

```sql
WITH MonthlySKUCosts AS (
  SELECT
    FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS month,
    sku.description AS sku_description,
    SUM(cost) AS monthly_cost
  FROM
    `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
  WHERE
    time_stamp
      BETWEEN TIMESTAMP('2025-01-01 00:00:00 UTC')
      AND TIMESTAMP('2026-01-01 00:00:00 UTC')
    AND usage_start_time
      BETWEEN TIMESTAMP('2025-01-01 00:00:00 UTC')
      AND TIMESTAMP('2026-01-01 00:00:00 UTC')
  GROUP BY
    1, 2
),
RankedSKUCosts AS (
  SELECT
    month,
    sku_description,
    monthly_cost,
    RANK() OVER (PARTITION BY month ORDER BY monthly_cost DESC) AS rank
  FROM
    MonthlySKUCosts
),
MonthlyTotalCosts AS (
  SELECT
    month,
    SUM(monthly_cost) AS total_monthly_cost
  FROM
    MonthlySKUCosts
  GROUP BY
    month
)
SELECT
  r.month,
  r.sku_description,
  r.monthly_cost,
  COALESCE(SAFE_DIVIDE(r.monthly_cost, m.total_monthly_cost), 0) AS cost_contribution
FROM
  RankedSKUCosts r
JOIN
  MonthlyTotalCosts m ON r.month = m.month
WHERE
  r.rank <= 5
ORDER BY
  r.month, r.rank;
```

10. ###### *GKE Cluster, Namespace & Workload Cost Allocation*

```sql
SELECT
  -- Safely extract GKE metadata fields from the repeated labels array
  (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-cluster-name') AS cluster_name,
  (SELECT value FROM UNNEST(labels) WHERE key = 'k8s-namespace') AS namespace,
  (SELECT value FROM UNNEST(labels) WHERE key = 'k8s-workload-name') AS workload_name,
  service.description AS service_description,
  sku.description AS sku_description,
  ROUND(SUM(cost), 2) AS gross_cost,
  -- Calculate net cost by summing costs and negative credit amounts
  ROUND(SUM(cost + (SELECT IFNULL(SUM(c.amount), 0) FROM UNNEST(credits) AS c)), 2) AS net_cost
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  -- Query partition optimization
  time_stamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  -- Filter strictly for resources flagged with a GKE cluster label
  AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = 'goog-k8s-cluster-name')
GROUP BY
  1, 2, 3, 4, 5
ORDER BY
  net_cost DESC;
```

11. ###### *Vertex AI and Generative AI (LLMs) Cost Tracking*

```sql
SELECT
  project.id AS project_id,
  -- Extract the specific Vertex AI pipeline run identifier
  (SELECT value FROM UNNEST(labels) WHERE key = 'vertex-ai-pipelines-run-billing-id') AS pipeline_run_id,
  service.description AS service_description,
  sku.description AS sku_description,
  ROUND(SUM(usage.amount_in_pricing_units), 2) AS total_usage,
  usage.pricing_unit AS usage_unit,
  ROUND(SUM(cost), 2) AS gross_cost,
  ROUND(SUM(cost + (SELECT IFNULL(SUM(c.amount), 0) FROM UNNEST(credits) AS c)), 2) AS net_cost
FROM
  `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND (
    LOWER(service.description) LIKE '%vertex%'
    OR LOWER(service.description) LIKE '%generative%'
    -- Capture underlying compute spun up by Vertex Pipelines
    OR EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = 'vertex-ai-pipelines-run-billing-id')
  )
GROUP BY
  1, 2, service_description, sku_description, usage_unit
ORDER BY
  net_cost DESC;
```
