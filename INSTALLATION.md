# Enterprise Billing Agent INSTALLATION

# Overview

## The Enterprise Billing Agent (`billing_ent_agent`) is an advanced multi-Billing Account FinOps tool designed to perform granular cost analysis, detect financial anomalies, and generate actionable insights across multiple GCP Billing Accounts and Organizations using BigQuery billing exports. It functions as a unified, row-level secured (`SESSION_USER()`) resource price calculator and infrastructure cost advisor.

---

# Before you begin

## To function correctly across one or more GCP Billing Accounts, the agent requires access to the following BigQuery export tables (all datasets must reside in the **same BigQuery region**, e.g., `US` or `EU`):

1. ### Billing Data Exports (Per Billing Account)

   1. ##### `gcp_billing_export_v1_<Billing_Account>` **(Standard Usage — Mandatory)**: Contains standard Cloud Billing account cost information (SKU, invoice date, services, projects, labels, locations, currency, etc.).
   2. ##### `gcp_billing_export_resource_v1_<Billing_Account>` **(Detailed Usage)**: Provides detailed, resource-level cost data (includes everything in the standard export plus resource-level details like virtual machines, SSDs, GKE clusters, etc.). [Documentation](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery)

2. ### Pricing and Insights (Per Billing Account)

   1. ##### `cloud_pricing_export`: Contains official pricing information, including service rates, billing account IDs, consumption models, and pricing tiers. [Documentation](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/pricing-data)

3. ### `recommendations_export` (Per Organization / Billing Account)

   Includes Active Assist recommendations and insights for projects, folders, and billing accounts, such as VM right-sizing, idle resource cleanup, and commitment purchases. [Documentation](https://docs.cloud.google.com/recommender/docs/bq-export/export-recommendations-to-bq)

4. ### IAM User Roles

   1. #### [Data Agent Creation & Management Roles](https://docs.cloud.google.com/bigquery/docs/create-data-agents#required-roles) *(Administrator / Installer)*

      1. ##### ***Gemini Data Analytics Data Agent Creator*** (`roles/geminidataanalytics.dataAgentCreator`): Project-level role required to create new data agents. Creating an agent automatically grants you owner permissions on that specific agent.
      2. ##### ***Gemini Data Analytics Data Agent Owner*** (`roles/geminidataanalytics.dataAgentOwner`): Granted on the agent or project to edit, share, manage IAM policies, and delete the agent.
      3. ##### ***Gemini Data Analytics Data Agent Editor*** (`roles/geminidataanalytics.dataAgentEditor`): Granted on the agent or project to modify agent configuration and knowledge source mappings.
      4. ##### ***BigQuery Admin*** (`roles/bigquery.admin`): Required during installation to create the central `billing_ent` dataset, create the per-BA `projects` Materialized Views, and configure cross-dataset Authorized Views.

   2. #### [Conversational Usage & Chat Roles](https://docs.cloud.google.com/bigquery/docs/create-conversations#required_roles) *(End Users — Automated by `scripts/user_add.sh`)*

      1. ##### ***Gemini Data Analytics Data Agent User*** (`roles/geminidataanalytics.dataAgentUser`): Granted automatically by `scripts/user_add.sh` on the specific Data Agent (`${CA_AGENT_ID}`, default `enterprise_billing_agent`) to view and chat with the published agent.
      2. ##### ***Gemini Data Analytics Stateless Chat User*** (`roles/geminidataanalytics.dataAgentStatelessUser`): Optional role if users also initiate direct ad-hoc conversations with views without a predefined agent.
      3. ##### ***Gemini for Google Cloud User*** (`roles/cloudaicompanion.user`): Required at the project level for accessing Gemini-powered features in the Google Cloud Console.

   3. #### [Underlying BigQuery & Data Access Roles](https://docs.cloud.google.com/bigquery/docs/conversational-analytics) *(End Users — Automated by `scripts/user_add.sh`)*

      Because Conversational Analytics queries data using the requesting user's identity (`SESSION_USER()`), each end user receives strictly scoped permissions via `scripts/user_add.sh`:

      1. ##### ***BigQuery Job User*** (`roles/bigquery.jobUser`): Project-level role granted on the host project (`${PROJECT_ID}`) so the agent can execute SQL query jobs on the user's behalf (does not grant read access to any tables).
      2. ##### ***BigQuery Data Viewer*** (`roles/bigquery.dataViewer`): Granted **ONLY on the 4 unified analytical views** in `${PROJECT_ID}:${ENT_DATASET}` (`gcp_billing_export_v1_all_ba`, `gcp_billing_export_resource_v1_all_ba`, `cloud_pricing_export_all_ba`, `recommendations_export_all_ba`). End users never receive direct access to `usr-prv`, `billing_projects`, or the underlying Billing Account datasets.

---

## Table Availability Verification & Enabling Required BigQuery Export Tables

During installation (`./scripts/setup_all.sh`, `./scripts/02_create_ba_materialized_views.sh`, `./scripts/03_create_ent_views.sh`, and `./scripts/04_provision_bq_ca_agent.sh`), the scripts automatically verify the availability and accessibility of all configured source tables:

1. **Mandatory Table (`gcp_billing_export_v1_<BA>`)**:
   - Checked in every configured Billing Account dataset (`<BA_PROJECT_ID>:<BA_DATASET>.gcp_billing_export_v1_<BA_ID>`).
   - **If `gcp_billing_export_v1_<BA>` is missing or inaccessible for any Billing Account, the installation process halts immediately (`exit 1`) and returns an error.**
2. **Other Export Tables (`gcp_billing_export_resource_v1_<BA>`, `cloud_pricing_export`, `recommendations_export`)**:
   - Checked in each configured Billing Account / Recommendations dataset.
   - **If any of these tables are missing or inaccessible, the installer logs a `[Warning] Action Recommended: Please create/enable ... Without this table the agent answers will be less informative.` message**, dynamically builds the `UNION ALL` views from the available tables, and demonstrates the exact `SELECT` statements used in each view during `--preview` mode.

### Procedure to Enable Missing BigQuery Export Tables

1. #### Standard Usage Cost Export (`gcp_billing_export_v1_<BA>`) — *Mandatory*
   - Open **Google Cloud Console → Billing → Billing export** ([https://console.cloud.google.com/billing/export](https://console.cloud.google.com/billing/export)).
   - Select your Billing Account.
   - Under **BigQuery export → Standard usage cost**, click **Edit settings**.
   - Select the target **Project** and **Dataset** configured in `BILLING_ACCOUNTS` (must be in the same region as `billing_ent`) and click **Save**.
   - Reference: [Set up Cloud Billing data export to BigQuery](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery).

2. #### Detailed Usage Cost Export (`gcp_billing_export_resource_v1_<BA>`)
   - Open **Google Cloud Console → Billing → Billing export** ([https://console.cloud.google.com/billing/export](https://console.cloud.google.com/billing/export)).
   - Under **BigQuery export → Detailed usage cost**, click **Edit settings**.
   - Select the same target **Project** and **Dataset** configured for that Billing Account and click **Save**.

3. #### Cloud Billing Pricing Export (`cloud_pricing_export`)
   - Enable the **BigQuery Data Transfer Service API** (`bigquerydatatransfer.googleapis.com`) in the target project.
   - Open **Google Cloud Console → Billing → Billing export** ([https://console.cloud.google.com/billing/export](https://console.cloud.google.com/billing/export)).
   - Under **BigQuery export → Pricing**, click **Edit settings**, select the target **Project** and **Dataset**, and click **Save**.
   - Reference: [Enable Pricing export in Cloud Billing](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/pricing-data).

4. #### Active Assist Recommendations Export (`recommendations_export`)
   - Enable the **BigQuery Data Transfer Service API** (`bigquerydatatransfer.googleapis.com`) and **Recommender API** (`recommender.googleapis.com`).
   - Open **Google Cloud Console → BigQuery → Data transfers** ([https://console.cloud.google.com/bigquery/transfers](https://console.cloud.google.com/bigquery/transfers)).
   - Click **+ Create transfer**, select **Google Cloud Recommendations** as the Source type, choose the Organization scope, set the target **Dataset** configured in `RECOMMENDATIONS_SOURCES`, and click **Save**.
   - Reference: [Export recommendations to BigQuery](https://docs.cloud.google.com/recommender/docs/bq-export/export-recommendations-to-bq).

> After enabling any missing export tables and waiting for the initial export table creation in BigQuery, re-run `./scripts/03_create_ent_views.sh` and `./scripts/04_provision_bq_ca_agent.sh` (or `./scripts/setup_all.sh`).

---

# Automated Installation & Provisioning (Recommended)

Unlike a single-Billing Account setup, `billing_ent_agent` automates the entire BigQuery dataset, Materialized View, Authorized View, Schema Description, and Conversational Analytics Agent provisioning pipeline via CLI scripts.

### Step 1: Configure Environment (`config/config.env`)

Copy `config/config.env.example` to `config/config.env` and populate your host project, BigQuery region, Billing Accounts, Recommendations sources, and `CA_AGENT_ID`:

```bash
cp config/config.env.example config/config.env
```

Example `config/config.env`:
```bash
PROJECT_ID="billing-export-123456"
BQ_LOCATION="US"
ENT_DATASET="billing_ent"
USR_PRV_TABLE="usr-prv"

CA_AGENT_LOCATION="global"
CA_AGENT_ID="enterprise_billing_agent"
CA_AGENT_DISPLAY_NAME="Enterprise Multi-BA FinOps & Billing Agent"

# Format: "BA_ID_UNDERSCORED:EXPORT_PROJECT_ID:EXPORT_DATASET" (or "EXPORT_PROJECT_ID:EXPORT_DATASET" for auto-discovery)
BILLING_ACCOUNTS=(
  "012345_6789AB_CDEF01:project-1:billing_ds"
  "ABCDEF_012345_6789AB:project-2:billing"
)

# Format: "REC_PROJECT_ID:REC_DATASET:REC_TABLE"
RECOMMENDATIONS_SOURCES=(
  "org-rec-project:recommendation_us_org:recommendations_export"
  "project-2:billing:recommendations_export"
)
```

### Step 2: Review or Customize SQL Templates, System Instructions & Golden Queries

- **SQL Templates (`sql/`)**: Customize the view/MV templates if needed.
- **Agent Instructions (`json/agent_instructions.md`)**: System prompt injected into the BQ CA Data Agent (`${PROJECT_ID}` and `${ENT_DATASET}` placeholders are rendered automatically).
- **Golden Queries (`json/golden_queries.md`)**: 11 Verified Queries (`exampleQueries`) automatically parsed and uploaded to the BQ CA Data Agent.

### Step 3: Preview or Run Provisioning Scripts

All scripts support `--preview` (or `-p` / `preview`) to print all rendered BigQuery DDL statements, `bq` CLI commands, and REST API payloads without executing them, as well as `--agent-id <agent_id>` (or `-a <agent_id>`) to override `CA_AGENT_ID`:

```bash
# Preview the entire installation pipeline without making changes:
./scripts/setup_all.sh --preview

# Or preview individual steps:
./scripts/01_create_datasets_and_tables.sh --preview
./scripts/02_create_ba_materialized_views.sh --preview
./scripts/03_create_ent_views.sh --preview
./scripts/04_provision_bq_ca_agent.sh --preview
```

Execute against your GCP environment:
```bash
# Run all steps sequentially (01 -> 04):
./scripts/setup_all.sh

# Or run with a custom Data Agent ID:
./scripts/setup_all.sh --agent-id my_custom_billing_agent
```

What each step does:
1. **`01_create_datasets_and_tables.sh`**: Creates the central `${PROJECT_ID}:${ENT_DATASET}` dataset and the `usr-prv` access control table.
2. **`02_create_ba_materialized_views.sh`**: Verifies `gcp_billing_export_v1_<BA>` in each Billing Account dataset and creates the `projects` Materialized View (`project_id`, `project_number`, `ancestry_numbers`, `billing_account_id`).
3. **`03_create_ent_views.sh`**: Creates `billing_projects` and the 4 unified `*_all_ba` views (`gcp_billing_export_v1_all_ba`, `gcp_billing_export_resource_v1_all_ba`, `recommendations_export_all_ba`, `cloud_pricing_export_all_ba`), merges column and nested `RECORD` descriptions from `json/*_schema.json`, and configures **Authorized Views** across all source and central datasets.
4. **`04_provision_bq_ca_agent.sh`**: Enables `geminidataanalytics.googleapis.com` and creates or updates the BigQuery Conversational Analytics Data Agent (`${CA_AGENT_ID}`) with the 4 `*_all_ba` views, rendered System Instructions (`json/agent_instructions.md`), and Verified Queries (`json/golden_queries.md`).

---

### Step 4: Onboard, Disable, Enable, or Delete End Users (`scripts/user_add.sh`)

Use `scripts/user_add.sh` to manage user IAM bindings and row-level availability records in `${PROJECT_ID}.${ENT_DATASET}.usr-prv`:

- **Permissions Granted Automatically on User Add / Enable (`--status true`)**:
  1. `roles/bigquery.dataViewer` on the **4 `*_all_ba` views only** (`gcp_billing_export_v1_all_ba`, `gcp_billing_export_resource_v1_all_ba`, `cloud_pricing_export_all_ba`, `recommendations_export_all_ba`).
  2. `roles/bigquery.jobUser` on the **host project** (`${PROJECT_ID}`).
  3. `roles/geminidataanalytics.dataAgentUser` on the **BQ CA Data Agent** (`${CA_AGENT_ID}`).
- **Automatic Billing Account ID Normalization**:
  - `--billing-account` (and the BA segment of `--record`) automatically converts underscore-separated (`xxxxxx_xxxxx_xxxxxx` / `xxxxxx_xxxxxx_xxxxxx`) or unseparated (`xxxxxxxxxxxxxxxxx` / `xxxxxxxxxxxxxxxxxx`) Billing Account IDs to hyphenated format (`xxxxxx-xxxxx-xxxxxx` / `xxxxxx-xxxxxx-xxxxxx`) to match BigQuery billing export data.

```bash
# Add a user with multiple availability records (projects, folders, or billing accounts):
./scripts/user_add.sh --user alice@example.com \
  --project my-project-1 --project my-project-2 \
  --folder 123456789012 \
  --billing-account 012345-6789AB-CDEF01

# Grant access to ALL Billing Accounts configured in the enterprise agent:
./scripts/user_add.sh --user finops-admin@example.com --billing-account ALL

# Billing Account IDs with underscores or no separators are automatically normalized:
./scripts/user_add.sh --user alice@example.com --billing-account 012345_6789AB_CDEF01

# Preview the IAM bindings and MERGE SQL without executing:
./scripts/user_add.sh --user alice@example.com --project my-project-1 --preview

# Temporarily disable all records for a user (sets status=FALSE and updates date=CURRENT_TIMESTAMP()):
./scripts/user_add.sh --user alice@example.com --disable

# Re-enable a user (sets status=TRUE and updates date=CURRENT_TIMESTAMP()):
./scripts/user_add.sh --user alice@example.com --enable

# Delete a user completely (removes all rows from usr-prv, revokes BQ Data Viewer from all 4 views,
# and revokes roles/geminidataanalytics.dataAgentUser from the Data Agent):
./scripts/user_add.sh --user alice@example.com --delete
```

---

# Manual / Console BQ Agent Configuration Reference

> **Note:** If you ran `./scripts/04_provision_bq_ca_agent.sh` (or `./scripts/setup_all.sh`), the BigQuery Conversational Analytics Agent is **already created and configured** with all view schemas, system instructions, and golden queries. You can follow the steps below if you prefer to inspect, edit, or publish the agent manually in the Google Cloud Console.

1. ##### Open **BigQuery → Agents** in the GCP Console for your host project (`${PROJECT_ID}`).
2. ##### Select the provisioned agent (`Enterprise Multi-BA FinOps & Billing Agent` / `enterprise_billing_agent`) or press **Create Agent**.
3. ##### Verify the 4 Unified Enterprise Views (`${PROJECT_ID}:${ENT_DATASET}`)
   Unlike a single-BA agent that connects directly to raw tables, the Enterprise Billing Agent connects exclusively to the **4 row-level secured views** in `billing_ent` (column descriptions are automatically applied by `03_create_ent_views.sh` from `json/*_schema.json`):
   - `gcp_billing_export_v1_all_ba`
   - `gcp_billing_export_resource_v1_all_ba`
   - `cloud_pricing_export_all_ba`
   - `recommendations_export_all_ba`
4. ##### Verify the System Prompt ([`json/agent_instructions.md`](json/agent_instructions.md)) in the agent's **Instructions** field (also shown in the [Appendix](#instructions) below).
5. ##### Verify the **Verified Queries / Golden Queries** ([`json/golden_queries.md`](json/golden_queries.md), also shown in the [Appendix](#golden-queries) below).
6. ##### **Save - Publish - Share**:
   Save and publish the BigQuery agent for use in the BigQuery Console and external A2A clients such as **Gemini Enterprise**.

---

# Connect the BQ Agent to Gemini Enterprise App

1. ##### Copy JSON Agent Card

   After saving the agent in the BigQuery Console, click the **Publish** button and copy the JSON payload to your clipboard. You can save this to a file for later use when adding the agent to your Gemini Enterprise (GE) application. If you forget to copy it now, you can re-save and publish the agent at any time.

![Pic1](https://raw.githubusercontent.com/tytskov-tech/gcp-billing-agent/main/image_1.png)

2. ##### Open your Gemini Enterprise application (or create a new one), navigate to the **Agents** menu, and press **Add Agent**.

![Pic2](https://raw.githubusercontent.com/tytskov-tech/gcp-billing-agent/main/image_2.png)

3. ##### In the **Add an Agent** window, select **Custom agent via A2A**.

![Pic3](https://raw.githubusercontent.com/tytskov-tech/gcp-billing-agent/main/image_3.png)

4. ##### Paste the previously copied JSON into the **Agent Card JSON** field and press **Preview Agent Details** to verify the description of your BQ CA agent.

![Pic4](https://raw.githubusercontent.com/tytskov-tech/gcp-billing-agent/main/image_4.png)

5. ##### Configure Agent Authorization
   1. [Configure authorization details](https://docs.cloud.google.com/gemini/enterprise/docs/register-and-manage-an-a2a-agent#authorize-your-agent)
   2. [Complete the setup](https://docs.cloud.google.com/gemini/enterprise/docs/register-and-manage-an-a2a-agent#register-agent)
      1. **Authorization URL**: `https://accounts.google.com/o/oauth2/auth?access_type=offline&prompt=consent`
      2. **Token URL**: `https://oauth2.googleapis.com/token`
      3. **Scopes**: `https://www.googleapis.com/auth/cloud-platform`
      4. **PKCE verification**: Enabled
6. ##### Open the new agent in Gemini Enterprise and grant user access (and onboard each user's row-level scope via `./scripts/user_add.sh`).

All onboarded users can now see the agent in the Gemini Enterprise (GE) App and submit FinOps queries using natural language—automatically seeing only the Billing Accounts, folders, and projects authorized for their Google identity (`SESSION_USER()`).

---

# Appendix

## Instructions

> Full source file (automatically rendered and uploaded by `04_provision_bq_ca_agent.sh`): **[`json/agent_instructions.md`](json/agent_instructions.md)**

* **Role**: Senior Cloud FinOps Engineer and GCP Pricing Architect (`FinOps-GCP-Expert`).
* **Target Unified Enterprise Views (`${PROJECT_ID}.${ENT_DATASET}`)**:
  1. `gcp_billing_export_resource_v1_all_ba` (Detailed Usage Cost Export across all Billing Accounts — Resource-level granularity)
  2. `gcp_billing_export_v1_all_ba` (Standard Usage Cost Export across all Billing Accounts — SKU-level granularity)
  3. `cloud_pricing_export_all_ba` (Cloud Pricing Export across all Billing Accounts — Official Rate Card & Custom Contract Rates)
  4. `recommendations_export_all_ba` (Active Assist / Recommender export across all Organizations & Billing Accounts)
* **Key Mandates**:
  - **Mandatory Partition Filter**: Every query MUST filter on `time_stamp` (the exposed alias for `_PARTITIONTIME` in all 4 `*_all_ba` views), e.g., `WHERE time_stamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)`.
  - **Net Discounted Spend by Default**: Always calculate net cost inclusive of credits (`ROUND(SUM(CAST(cost AS NUMERIC) + (SELECT IFNULL(SUM(CAST(c.amount AS NUMERIC)), 0) FROM UNNEST(credits) AS c)), 2) AS net_cost`) unless public list price is explicitly requested.
  - **Multi-BA Awareness**: Supports grouping and filtering by `billing_account_id` across all views while respecting row-level security enforced by `billing_projects`.

---

## Golden Queries

> Full source file (automatically parsed and uploaded as `exampleQueries` by `04_provision_bq_ca_agent.sh`): **[`json/golden_queries.md`](json/golden_queries.md)**

1. ###### *Identify the correlation between usage amount and cost for each service description, filtering for services with average cost greater than $100.*

```sql
SELECT
  service.description,
  CORR(usage.amount, cost) AS correlation
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1
HAVING AVG(cost) > 100;
```

2. ###### *Calculate the cost variation (standard deviation) for each location's region, considering only costs above the 75th percentile.*

```sql
SELECT
  location.region,
  STDDEV(cost) AS cost_stddev
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  cost > (
    SELECT APPROX_QUANTILES(cost, 4)[OFFSET(3)]
    FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
    WHERE
      time_stamp
        BETWEEN TIMESTAMP('2026-01-01 00:00:00')
        AND TIMESTAMP('2026-03-01 00:00:00')
  )
  AND time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1;
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
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1, 2
ORDER BY 1, 2;
```

4. ###### *Calculate the population variance of cost for each project name to assess the spread of costs across different projects, filtered by usage end time.*

```sql
SELECT
  project.name,
  VAR_POP(cost) AS cost_variance
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  usage_end_time BETWEEN TIMESTAMP('2026-01-01 00:00:00 UTC') AND TIMESTAMP('2026-01-31 23:59:59 UTC')
  AND time_stamp BETWEEN TIMESTAMP('2026-01-01 00:00:00 UTC') AND TIMESTAMP('2026-06-01 00:00:00 UTC')
GROUP BY
  project.name;
```

5. ###### *Identify the top 5 SKUs with the highest average cost at list to understand which resources are generally the most expensive, filtering by invoice month.*

```sql
SELECT
  sku.description,
  AVG(cost_at_list) AS avg_cost_at_list
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
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
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1, 2;
```

7. ###### *Identify the top 3 project IDs with the highest cost and their corresponding average usage amount in pricing units.*

```sql
SELECT
  project.id,
  AVG(usage.amount_in_pricing_units) AS avg_usage
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1
ORDER BY SUM(cost) DESC
LIMIT 3;
```

8. ###### *Determine the percentage contribution of each SKU description to the total cost, grouped by invoice month.*

```sql
SELECT
  invoice.month,
  sku.description,
  SUM(cost)
    / (
      SELECT SUM(cost)
      FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
      WHERE
        time_stamp
          BETWEEN TIMESTAMP('2026-01-01 00:00:00')
          AND TIMESTAMP('2026-03-01 00:00:00')
    ) AS percentage_contribution
FROM `${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba`
WHERE
  time_stamp
    BETWEEN TIMESTAMP('2026-01-01 00:00:00')
    AND TIMESTAMP('2026-03-01 00:00:00')
GROUP BY 1, 2;
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
    time_stamp BETWEEN TIMESTAMP('2025-01-01 00:00:00 UTC') AND TIMESTAMP('2026-01-05 00:00:00 UTC')
    AND usage_start_time BETWEEN TIMESTAMP('2025-01-01 00:00:00 UTC') AND TIMESTAMP('2026-01-01 00:00:00 UTC')
  GROUP BY 1, 2
),
RankedSKUCosts AS (
  SELECT
    month,
    sku_description,
    monthly_cost,
    RANK() OVER (PARTITION BY month ORDER BY monthly_cost DESC) AS rank
  FROM MonthlySKUCosts
),
MonthlyTotalCosts AS (
  SELECT
    month,
    SUM(monthly_cost) AS total_monthly_cost
  FROM MonthlySKUCosts
  GROUP BY month
)
SELECT
  r.month,
  r.sku_description,
  r.monthly_cost,
  COALESCE(SAFE_DIVIDE(r.monthly_cost, m.total_monthly_cost), 0) AS cost_contribution
FROM RankedSKUCosts r
JOIN MonthlyTotalCosts m ON r.month = m.month
WHERE r.rank <= 5
ORDER BY r.month, r.rank;
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
