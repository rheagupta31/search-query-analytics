-- ============================================================
-- ETL PIPELINE — Daily Aggregation Layer
-- Run nightly to build summary tables for dashboards.
-- Pattern: raw tables → staging → mart (star schema)
-- ============================================================


-- ------------------------------------------------------------
-- STEP 1: STAGING — Enrich raw queries
--    Joins queries with session/user context.
--    This is the "wide" row used by all downstream marts.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_query_events AS
SELECT
    q.query_id,
    q.session_id,
    q.user_id,
    q.query_text_normalized,
    q.submitted_at,
    DATE(q.submitted_at)                          AS query_date,
    DATE_TRUNC('week', q.submitted_at)            AS query_week,
    DATE_TRUNC('month', q.submitted_at)           AS query_month,
    q.result_count,
    q.response_time_ms,
    q.is_reformulation,
    q.query_category,
    q.query_position,
    u.country_code,
    u.device_type,
    u.user_type,
    s.platform,
    s.session_source,
    -- Click indicators (joined in)
    COALESCE(ce_agg.click_count, 0)               AS click_count,
    ce_agg.avg_dwell_ms,
    ce_agg.max_dwell_ms,
    CASE WHEN q.result_count = 0 THEN TRUE
         ELSE FALSE END                           AS is_zero_result,
    CASE WHEN ce_agg.click_count IS NULL
          AND q.result_count > 0 THEN TRUE
         ELSE FALSE END                           AS is_abandoned
FROM queries q
JOIN sessions s ON s.session_id = q.session_id
JOIN users    u ON u.user_id    = q.user_id
LEFT JOIN (
    SELECT
        query_id,
        COUNT(*)          AS click_count,
        AVG(dwell_time_ms) AS avg_dwell_ms,
        MAX(dwell_time_ms) AS max_dwell_ms
    FROM click_events
    GROUP BY query_id
) ce_agg ON ce_agg.query_id = q.query_id;

-- Index for downstream joins
CREATE INDEX IF NOT EXISTS idx_stg_query_date ON stg_query_events(query_date);
CREATE INDEX IF NOT EXISTS idx_stg_user_id    ON stg_query_events(user_id);


-- ------------------------------------------------------------
-- STEP 2: MART — Daily Search Summary
--    One row per day. Used for trend dashboards.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart_daily_search_summary (
    summary_date          DATE        PRIMARY KEY,
    total_queries         INT,
    unique_users          INT,
    unique_sessions       INT,
    zero_result_queries   INT,
    zero_result_rate      NUMERIC(5,4),
    abandoned_queries     INT,
    abandonment_rate      NUMERIC(5,4),
    total_clicks          INT,
    overall_ctr           NUMERIC(5,4),
    avg_response_time_ms  NUMERIC(8,2),
    p95_response_time_ms  NUMERIC(8,2),
    reformulation_queries INT,
    reformulation_rate    NUMERIC(5,4)
);

-- Upsert daily metrics
INSERT INTO mart_daily_search_summary
SELECT
    query_date                                        AS summary_date,
    COUNT(*)                                          AS total_queries,
    COUNT(DISTINCT user_id)                           AS unique_users,
    COUNT(DISTINCT session_id)                        AS unique_sessions,
    SUM(CASE WHEN is_zero_result THEN 1 ELSE 0 END)  AS zero_result_queries,
    ROUND(AVG(is_zero_result::INT)::NUMERIC, 4)       AS zero_result_rate,
    SUM(CASE WHEN is_abandoned   THEN 1 ELSE 0 END)  AS abandoned_queries,
    ROUND(AVG(is_abandoned::INT)::NUMERIC, 4)         AS abandonment_rate,
    SUM(click_count)                                  AS total_clicks,
    ROUND(
        SUM(CASE WHEN click_count > 0 THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(COUNT(*), 0), 4
    )                                                 AS overall_ctr,
    ROUND(AVG(response_time_ms)::NUMERIC, 2)                  AS avg_response_time_ms,
    ROUND(
        PERCENTILE_CONT(0.95) WITHIN GROUP
            (ORDER BY response_time_ms)::NUMERIC, 2
    )                                                 AS p95_response_time_ms,
    SUM(CASE WHEN is_reformulation THEN 1 ELSE 0 END) AS reformulation_queries,
    ROUND(AVG(is_reformulation::INT)::NUMERIC, 4)     AS reformulation_rate
FROM stg_query_events
GROUP BY query_date
ON CONFLICT (summary_date) DO UPDATE SET
    total_queries        = EXCLUDED.total_queries,
    unique_users         = EXCLUDED.unique_users,
    unique_sessions      = EXCLUDED.unique_sessions,
    zero_result_queries  = EXCLUDED.zero_result_queries,
    zero_result_rate     = EXCLUDED.zero_result_rate,
    abandoned_queries    = EXCLUDED.abandoned_queries,
    abandonment_rate     = EXCLUDED.abandonment_rate,
    total_clicks         = EXCLUDED.total_clicks,
    overall_ctr          = EXCLUDED.overall_ctr,
    avg_response_time_ms = EXCLUDED.avg_response_time_ms,
    p95_response_time_ms = EXCLUDED.p95_response_time_ms,
    reformulation_queries= EXCLUDED.reformulation_queries,
    reformulation_rate   = EXCLUDED.reformulation_rate;


-- ------------------------------------------------------------
-- STEP 3: MART — Top Queries (Rolling 7-day)
--    Updated daily. Top 1000 queries by volume.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart_top_queries (
    query_text_normalized  TEXT        NOT NULL,
    window_start           DATE        NOT NULL,
    window_end             DATE        NOT NULL,
    search_volume          INT,
    unique_users           INT,
    ctr                    NUMERIC(5,4),
    avg_dwell_ms           NUMERIC(10,2),
    zero_result_count      INT,
    rank                   INT,
    PRIMARY KEY (query_text_normalized, window_start)
);

INSERT INTO mart_top_queries
SELECT
    query_text_normalized,
    CURRENT_DATE - INTERVAL '7 days'              AS window_start,
    CURRENT_DATE                                  AS window_end,
    COUNT(*)                                      AS search_volume,
    COUNT(DISTINCT user_id)                       AS unique_users,
    ROUND(AVG(CASE WHEN click_count > 0 THEN 1.0 ELSE 0.0 END)::NUMERIC, 4) AS ctr,
    ROUND(AVG(avg_dwell_ms)::NUMERIC, 2)                   AS avg_dwell_ms,
    SUM(CASE WHEN is_zero_result THEN 1 ELSE 0 END) AS zero_result_count,
    RANK() OVER (ORDER BY COUNT(*) DESC)          AS rank
FROM stg_query_events
WHERE query_date >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY query_text_normalized
ORDER BY search_volume DESC
LIMIT 1000
ON CONFLICT (query_text_normalized, window_start) DO UPDATE SET
    search_volume    = EXCLUDED.search_volume,
    unique_users     = EXCLUDED.unique_users,
    ctr              = EXCLUDED.ctr,
    avg_dwell_ms     = EXCLUDED.avg_dwell_ms,
    zero_result_count= EXCLUDED.zero_result_count,
    rank             = EXCLUDED.rank;


-- ------------------------------------------------------------
-- STEP 4: MART — Device & Platform Breakdown (Daily)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mart_daily_device_breakdown (
    summary_date   DATE        NOT NULL,
    device_type    VARCHAR(20),
    platform       VARCHAR(20),
    query_count    INT,
    ctr            NUMERIC(5,4),
    zero_result_rate NUMERIC(5,4),
    PRIMARY KEY (summary_date, device_type, platform)
);

INSERT INTO mart_daily_device_breakdown
SELECT
    query_date,
    device_type,
    platform,
    COUNT(*)                                      AS query_count,
    ROUND(AVG(CASE WHEN click_count > 0 THEN 1.0 ELSE 0.0 END)::NUMERIC, 4) AS ctr,
    ROUND(AVG(is_zero_result::INT)::NUMERIC, 4)   AS zero_result_rate
FROM stg_query_events
GROUP BY query_date, device_type, platform
ON CONFLICT (summary_date, device_type, platform) DO UPDATE SET
    query_count      = EXCLUDED.query_count,
    ctr              = EXCLUDED.ctr,
    zero_result_rate = EXCLUDED.zero_result_rate;


-- ------------------------------------------------------------
-- PIPELINE AUDIT LOG — Track each ETL run
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id          BIGSERIAL   PRIMARY KEY,
    run_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    pipeline_name   TEXT        NOT NULL,
    rows_processed  INT,
    duration_ms     INT,
    status          VARCHAR(20) CHECK (status IN ('success', 'failure', 'partial')),
    error_message   TEXT
);

-- Log this run (example)
INSERT INTO pipeline_runs (pipeline_name, rows_processed, status)
VALUES ('daily_search_summary', 0, 'success');
