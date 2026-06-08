-- ============================================================
-- ANALYTICS QUERIES
-- Core SQL patterns for search behavior analysis
-- ============================================================


-- ------------------------------------------------------------
-- 1. CLICK-THROUGH RATE (CTR) BY QUERY
--    For each query that had results, what % of sessions
--    resulted in at least one click?
-- ------------------------------------------------------------
SELECT
    q.query_text_normalized,
    COUNT(DISTINCT q.query_id)                        AS total_queries,
    COUNT(DISTINCT ce.query_id)                       AS queries_with_clicks,
    ROUND(
        COUNT(DISTINCT ce.query_id)::NUMERIC
        / NULLIF(COUNT(DISTINCT q.query_id), 0) * 100, 2
    )                                                 AS ctr_percent
FROM queries q
LEFT JOIN click_events ce ON ce.query_id = q.query_id
WHERE q.result_count > 0
GROUP BY q.query_text_normalized
HAVING COUNT(DISTINCT q.query_id) > 1
ORDER BY total_queries DESC, ctr_percent DESC;


-- ------------------------------------------------------------
-- 2. ZERO-RESULT RATE — Daily
--    What fraction of searches return no results each day?
--    A rising zero-result rate signals index coverage issues.
-- ------------------------------------------------------------
SELECT
    DATE(submitted_at)                                AS query_date,
    COUNT(*)                                          AS total_queries,
    SUM(CASE WHEN result_count = 0 THEN 1 ELSE 0 END) AS zero_result_queries,
    ROUND(
        SUM(CASE WHEN result_count = 0 THEN 1 ELSE 0 END)::NUMERIC
        / COUNT(*) * 100, 2
    )                                                 AS zero_result_rate_pct
FROM queries
GROUP BY DATE(submitted_at)
ORDER BY query_date DESC;


-- ------------------------------------------------------------
-- 3. QUERY REFORMULATION CHAINS
--    For each original query, list the full chain of
--    refinements a user made within the same session.
--    Uses a recursive CTE to traverse parent_query_id.
-- ------------------------------------------------------------
WITH RECURSIVE reformulation_chain AS (
    -- Base: original queries (no parent)
    SELECT
        query_id,
        parent_query_id,
        session_id,
        query_text,
        submitted_at,
        1                   AS depth,
        ARRAY[query_id]     AS path
    FROM queries
    WHERE parent_query_id IS NULL

    UNION ALL

    -- Recursive: each refinement step
    SELECT
        q.query_id,
        q.parent_query_id,
        q.session_id,
        q.query_text,
        q.submitted_at,
        rc.depth + 1,
        rc.path || q.query_id
    FROM queries q
    JOIN reformulation_chain rc ON rc.query_id = q.parent_query_id
)
SELECT
    session_id,
    depth,
    query_id,
    query_text,
    submitted_at,
    path AS reformulation_path
FROM reformulation_chain
ORDER BY session_id, submitted_at;


-- ------------------------------------------------------------
-- 4. SESSION DEPTH & ABANDONMENT FUNNEL
--    How many users search once, twice, three times, etc.?
--    Abandonment = session with 1 query and 0 clicks.
-- ------------------------------------------------------------
WITH session_stats AS (
    SELECT
        s.session_id,
        COUNT(DISTINCT q.query_id)              AS query_count,
        COUNT(DISTINCT ce.click_id)             AS click_count,
        MAX(q.query_position)                   AS max_depth,
        MIN(q.submitted_at)                     AS first_query_at,
        MAX(q.submitted_at)                     AS last_query_at
    FROM sessions s
    LEFT JOIN queries      q  ON q.session_id  = s.session_id
    LEFT JOIN click_events ce ON ce.query_id   = q.query_id
    GROUP BY s.session_id
)
SELECT
    query_count                                  AS queries_in_session,
    COUNT(*)                                     AS session_count,
    SUM(CASE WHEN click_count = 0 THEN 1 END)   AS abandoned_sessions,
    ROUND(
        SUM(CASE WHEN click_count = 0 THEN 1 END)::NUMERIC
        / COUNT(*) * 100, 2
    )                                            AS abandonment_rate_pct,
    ROUND(AVG(
        EXTRACT(EPOCH FROM (last_query_at - first_query_at))
    ), 2)                                        AS avg_session_duration_secs
FROM session_stats
GROUP BY query_count
ORDER BY query_count;


-- ------------------------------------------------------------
-- 5. TOP QUERIES — Rolling 7-Day Window
--    Most popular search terms in the last 7 days.
--    Window function shows each query's rank.
-- ------------------------------------------------------------
SELECT
    query_text_normalized                        AS query,
    COUNT(*)                                     AS search_volume,
    AVG(result_count)                            AS avg_results_shown,
    ROUND(AVG(response_time_ms), 0)              AS avg_latency_ms,
    RANK() OVER (ORDER BY COUNT(*) DESC)         AS popularity_rank
FROM queries
WHERE submitted_at >= NOW() - INTERVAL '7 days'
GROUP BY query_text_normalized
ORDER BY search_volume DESC
LIMIT 25;


-- ------------------------------------------------------------
-- 6. RESULT POSITION CTR (SERP Click Bias)
--    How does click rate vary by result rank?
--    Classic "position bias" analysis — rank 1 should dominate.
-- ------------------------------------------------------------
SELECT
    sr.rank                                      AS result_position,
    COUNT(DISTINCT sr.result_id)                 AS times_shown,
    COUNT(DISTINCT ce.click_id)                  AS total_clicks,
    ROUND(
        COUNT(DISTINCT ce.click_id)::NUMERIC
        / NULLIF(COUNT(DISTINCT sr.result_id), 0) * 100, 2
    )                                            AS ctr_pct,
    ROUND(AVG(ce.dwell_time_ms) / 1000.0, 1)    AS avg_dwell_secs
FROM search_results sr
LEFT JOIN click_events ce ON ce.result_id = sr.result_id
GROUP BY sr.rank
ORDER BY sr.rank;


-- ------------------------------------------------------------
-- 7. USER ENGAGEMENT COHORTS
--    Group users by their first week of activity and track
--    how many searched in subsequent weeks (retention).
-- ------------------------------------------------------------
WITH user_cohorts AS (
    SELECT
        u.user_id,
        DATE_TRUNC('week', u.first_seen_at)      AS cohort_week
    FROM users u
),
user_activity AS (
    SELECT
        q.user_id,
        DATE_TRUNC('week', q.submitted_at)       AS activity_week
    FROM queries q
    GROUP BY q.user_id, DATE_TRUNC('week', q.submitted_at)
)
SELECT
    c.cohort_week,
    EXTRACT(WEEK FROM (a.activity_week - c.cohort_week))::INT AS weeks_since_cohort,
    COUNT(DISTINCT c.user_id)                    AS cohort_size,
    COUNT(DISTINCT a.user_id)                    AS retained_users,
    ROUND(
        COUNT(DISTINCT a.user_id)::NUMERIC
        / COUNT(DISTINCT c.user_id) * 100, 2
    )                                            AS retention_rate_pct
FROM user_cohorts c
LEFT JOIN user_activity a
    ON  a.user_id      = c.user_id
    AND a.activity_week >= c.cohort_week
GROUP BY c.cohort_week, weeks_since_cohort
ORDER BY c.cohort_week, weeks_since_cohort;


-- ------------------------------------------------------------
-- 8. DWELL TIME ANALYSIS — Quality Signal
--    Long dwell = satisfied user. Short dwell = pogo-sticking.
--    Bucket clicks by dwell time to surface quality issues.
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN dwell_time_ms IS NULL        THEN 'no_return'
        WHEN dwell_time_ms < 5000         THEN '<5s (bounce)'
        WHEN dwell_time_ms < 30000        THEN '5–30s'
        WHEN dwell_time_ms < 120000       THEN '30s–2min'
        WHEN dwell_time_ms < 600000       THEN '2–10min'
        ELSE '>10min (deep read)'
    END                                          AS dwell_bucket,
    COUNT(*)                                     AS click_count,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 2) AS pct_of_clicks
FROM click_events
GROUP BY dwell_bucket
ORDER BY MIN(COALESCE(dwell_time_ms, -1));
