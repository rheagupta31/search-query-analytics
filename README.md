# 🔍 Search Query Analytics Platform

A production-style, end-to-end data engineering project modeling how users interact with a search engine — built as a Google interview portfolio project.

**[Live Dashboard →](https://rheagupta31.github.io/search-query-analytics/)**

---

## What This Project Does

This platform tracks and analyzes search behavior across five core dimensions:

- **Query volume & trends** — what people search for, how often, and when
- **Click-through rate (CTR)** — which results get clicked, by position and query type
- **Zero-result detection** — queries that return no results, a key search quality signal
- **Session depth & abandonment** — how many queries users submit before leaving
- **Reformulation chains** — how users refine their searches to find what they need

Real data is sourced from **Google Trends** via the `pytrends` API.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Database | PostgreSQL (local) · BigQuery (cloud) |
| Transformation | dbt (staging → mart models) |
| Orchestration | Apache Airflow + Docker Compose |
| Ingestion | Python (pytrends · psycopg2 · BigQuery SDK) |
| Dashboard | HTML · JavaScript · Chart.js |
| Data | Google Trends public dataset |

---

## Project Structure

```
search-analytics/
│
├── 01_create_tables.sql        # Normalized schema: 5 tables, 8 indexes, partitioning
├── analytics.sql               # 8 core analytics queries (window functions, recursive CTEs)
├── daily_pipeline.sql          # ETL: raw → staging → mart (star schema, upserts)
├── performance.sql             # EXPLAIN ANALYZE, covering indexes, materialized views
│
├── load_real_data.py           # Pulls real Google Trends data → PostgreSQL
├── export_for_dashboard.sh     # Exports 7 CSV files for the live dashboard
│
├── index.html                  # Live analytics dashboard
│
├── data_kpis.csv               # Real KPI metrics
├── data_daily.csv              # Daily volume + zero-result rate (30 days)
├── data_position_bias.csv      # CTR by search result rank
├── data_dwell.csv              # Post-click dwell time distribution
├── data_depth.csv              # Session depth distribution
├── data_devices.csv            # Device type breakdown
└── data_top_queries.csv        # Top queries by volume with CTR
```

---

## Schema Design

Five normalized tables (3NF) connected by foreign keys:

```
users ──< sessions ──< queries ──< search_results
                              └──< click_events
```

**Key design decisions:**

- `parent_query_id` self-referencing FK on `queries` enables recursive CTE traversal of reformulation chains
- Monthly `PARTITION BY RANGE (submitted_at)` on the raw event table for time-range query performance
- Partial index on `WHERE result_count = 0` for fast zero-result monitoring
- Covering index on CTR query eliminates heap fetches via index-only scan

---

## Analytics Queries

| Query | SQL Technique |
|-------|--------------|
| CTR by query | `LEFT JOIN` · `COUNT DISTINCT` · `NULLIF` |
| Zero-result rate (daily) | `CASE WHEN` aggregation |
| Reformulation chains | Recursive CTE with `ARRAY` path tracking |
| Session depth & abandonment | CTE + window aggregation |
| Top queries (7-day rolling) | `RANK() OVER()` |
| Position bias (SERP CTR) | Multi-table join + rank aggregation |
| Cohort retention | Self-join on `DATE_TRUNC` week buckets |
| Dwell time distribution | `CASE WHEN` bucketing + `SUM() OVER()` for % |

---

## ETL Pipeline

**Pattern:** `raw tables → stg_query_events → mart_*`

```sql
-- Staging: denormalized wide table joining all raw sources
CREATE TABLE stg_query_events AS ...

-- Mart 1: one row per day, upserted with ON CONFLICT
INSERT INTO mart_daily_search_summary ... ON CONFLICT (summary_date) DO UPDATE ...

-- Mart 2: rolling 7-day top queries with RANK()
INSERT INTO mart_top_queries ...

-- Audit log: every pipeline run tracked
INSERT INTO pipeline_runs (pipeline_name, rows_processed, status) ...
```

---

## Performance Optimization

- `EXPLAIN (ANALYZE, BUFFERS)` to identify sequential scans
- Covering index eliminates heap fetches for the CTR query
- Partial index on zero-result queries (minority subset — much smaller than full index)
- Materialized view (`mv_daily_ctr`) for dashboard queries — refresh nightly
- `pg_stat_statements` integration for slow query detection in production

---

## Running Locally

### Prerequisites
- PostgreSQL 14+
- Python 3.10+

### Setup

```bash
# Clone the repo
git clone https://github.com/rheagupta/search-analytics.git
cd search-analytics

# Install Python dependencies
pip install pytrends pandas psycopg2-binary

# Create the database
createdb search_analytics

# Build the schema
psql -U postgres -d search_analytics -f 01_create_tables.sql

# Load real Google Trends data (~2 min)
python load_real_data.py

# Run the ETL pipeline
psql -U postgres -d search_analytics -f daily_pipeline.sql

# Run analytics queries
psql -U postgres -d search_analytics -f analytics.sql

# Export data for the dashboard
bash export_for_dashboard.sh

# Serve the dashboard locally
python3 -m http.server 8080
# Open http://localhost:8080
```

---

## Dashboard

The live dashboard shows 7 real-data visualizations:

- **Daily query volume** with zero-result rate overlay
- **Position bias CTR** — exponential click decay by search result rank
- **Session depth** distribution
- **Device type** breakdown
- **Dwell time** buckets (bounce → deep read)
- **Top queries** table with real Google Trends terms, volume, and CTR

All charts pull from CSV exports of the live PostgreSQL database.

---


## BigQuery Extension

The project includes a BigQuery layer (`bigquery_setup.sql`) that:
- Ingests from `bigquery-public-data.google_trends.top_terms`
- Uses `FARM_FINGERPRINT` for distributed surrogate key generation
- Applies `PARTITION BY DATE(submitted_at)` + `CLUSTER BY query_text_normalized`
- Simulates clicks using a position-decay CTR model: `0.42 × e^(−0.4 × (rank−1))`

---

## dbt Project

Full dbt project (`search-analytics-v2/dbt/`) with:
- 3 staging models (views) — clean and validate raw data
- 2 mart models — incremental daily summary + rolling top queries
- `sources.yml` + `schema.yml` — column-level data tests
- Custom singular test — detects zero-result rate spikes automatically
- Reusable macros — `safe_divide`, `rolling_metric`, `generate_date_spine`

---

*Built as an end-to-end SQL portfolio project targeting data engineering roles at Google.*
