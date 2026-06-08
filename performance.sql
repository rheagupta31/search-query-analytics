-- ============================================================
-- PERFORMANCE OPTIMIZATION
-- Query plans, indexes, and tuning notes
-- ============================================================


-- ------------------------------------------------------------
-- EXPLAIN ANALYZE: CTR query
--    Run this to see the query plan and identify bottlenecks.
--    Look for: Seq Scan on large tables (bad), Index Scan (good),
--    high actual rows vs estimated rows (bad stats).
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    q.query_text_normalized,
    COUNT(DISTINCT q.query_id)  AS total_queries,
    COUNT(DISTINCT ce.query_id) AS queries_with_clicks,
    ROUND(
        COUNT(DISTINCT ce.query_id)::NUMERIC
        / NULLIF(COUNT(DISTINCT q.query_id), 0) * 100, 2
    ) AS ctr_percent
FROM queries q
LEFT JOIN click_events ce ON ce.query_id = q.query_id
WHERE q.result_count > 0
  AND q.submitted_at >= NOW() - INTERVAL '30 days'
GROUP BY q.query_text_normalized
ORDER BY total_queries DESC;


-- ------------------------------------------------------------
-- COVERING INDEX: Avoid heap fetches for common CTR query
--    Includes all columns needed so PostgreSQL never touches
--    the main table (index-only scan).
-- ------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_queries_ctr_covering
ON queries (submitted_at DESC, result_count, query_text_normalized, query_id)
WHERE result_count > 0;


-- ------------------------------------------------------------
-- PARTIAL INDEX: Zero-result queries only
--    Much smaller than a full index since zero-results
--    are a minority subset. Speeds up zero-result monitoring.
-- ------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_queries_zero_result
ON queries (submitted_at DESC, session_id, user_id)
WHERE result_count = 0;


-- ------------------------------------------------------------
-- MATERIALIZED VIEW: Daily CTR (fast dashboard queries)
--    Precomputes the most expensive aggregation.
--    Refresh nightly via: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_ctr;
-- ------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_ctr AS
SELECT
    DATE(q.submitted_at)                         AS query_date,
    q.query_text_normalized,
    COUNT(DISTINCT q.query_id)                   AS total_queries,
    COUNT(DISTINCT ce.query_id)                  AS clicked_queries,
    ROUND(
        COUNT(DISTINCT ce.query_id)::NUMERIC
        / NULLIF(COUNT(DISTINCT q.query_id), 0), 4
    )                                            AS ctr
FROM queries q
LEFT JOIN click_events ce ON ce.query_id = q.query_id
WHERE q.result_count > 0
GROUP BY DATE(q.submitted_at), q.query_text_normalized;

-- Index on the materialized view for fast date filtering
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_daily_ctr_pk
    ON mv_daily_ctr(query_date, query_text_normalized);

-- Refresh command (run in cron/Airflow nightly):
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_ctr;


-- ------------------------------------------------------------
-- TABLE STATISTICS: Keep stats fresh for the query planner
-- ------------------------------------------------------------
ANALYZE queries;
ANALYZE click_events;
ANALYZE search_results;
ANALYZE sessions;


-- ------------------------------------------------------------
-- VACUUM: Reclaim space from dead rows (after heavy writes)
-- ------------------------------------------------------------
-- VACUUM ANALYZE queries;  -- Uncomment when running manually


-- ------------------------------------------------------------
-- SLOW QUERY DETECTION: pg_stat_statements
--    Enable in postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
--    Then identify the most expensive queries in production:
-- ------------------------------------------------------------
SELECT
    LEFT(query, 80)                              AS query_snippet,
    calls,
    ROUND(total_exec_time::NUMERIC / calls, 2)   AS avg_ms,
    ROUND(total_exec_time::NUMERIC, 0)           AS total_ms,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;


-- ------------------------------------------------------------
-- CONNECTION POOLING NOTE:
--    In production, use PgBouncer in transaction mode.
--    Set pool_size = (num_cores * 2) + effective_spindle_count
--    Typical: 20–50 connections for analytics workloads.
-- ------------------------------------------------------------
