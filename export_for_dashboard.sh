#!/bin/bash
# Run this once from your project folder to export all dashboard data
# Usage: bash export_for_dashboard.sh

DB="psql -U postgres -d search_analytics"

echo "Exporting dashboard data..."

# 1. Top queries + CTR
$DB -c "COPY (
  SELECT q.query_text_normalized,
    COUNT(DISTINCT q.query_id) as searches,
    ROUND(COUNT(DISTINCT ce.click_id)::NUMERIC / NULLIF(COUNT(DISTINCT q.query_id),0) * 100, 1) as ctr_pct,
    q.query_category
  FROM queries q
  LEFT JOIN click_events ce ON ce.query_id = q.query_id
  GROUP BY q.query_text_normalized, q.query_category
  ORDER BY searches DESC LIMIT 10
) TO STDOUT WITH CSV HEADER" > data_top_queries.csv

# 2. Daily volume + zero result rate (last 30 days)
$DB -c "COPY (
  SELECT DATE(submitted_at) as day,
    COUNT(*) as queries,
    ROUND(SUM(CASE WHEN result_count=0 THEN 1 ELSE 0 END)::NUMERIC / COUNT(*) * 100, 1) as zero_pct
  FROM queries
  WHERE submitted_at >= NOW() - INTERVAL '30 days'
  GROUP BY DATE(submitted_at) ORDER BY day
) TO STDOUT WITH CSV HEADER" > data_daily.csv

# 3. Position bias CTR
$DB -c "COPY (
  SELECT sr.rank as position,
    COUNT(DISTINCT sr.result_id) as shown,
    COUNT(DISTINCT ce.click_id) as clicks,
    ROUND(COUNT(DISTINCT ce.click_id)::NUMERIC / NULLIF(COUNT(DISTINCT sr.result_id),0) * 100, 1) as ctr_pct
  FROM search_results sr
  LEFT JOIN click_events ce ON ce.result_id = sr.result_id
  GROUP BY sr.rank ORDER BY sr.rank
) TO STDOUT WITH CSV HEADER" > data_position_bias.csv

# 4. Dwell time buckets
$DB -c "COPY (
  SELECT
    CASE
      WHEN dwell_time_ms IS NULL THEN 'No return'
      WHEN dwell_time_ms < 5000 THEN 'Under 5s'
      WHEN dwell_time_ms < 30000 THEN '5-30s'
      WHEN dwell_time_ms < 120000 THEN '30s-2min'
      WHEN dwell_time_ms < 600000 THEN '2-10min'
      ELSE 'Over 10min'
    END as bucket,
    COUNT(*) as clicks
  FROM click_events
  GROUP BY bucket ORDER BY MIN(COALESCE(dwell_time_ms, -1))
) TO STDOUT WITH CSV HEADER" > data_dwell.csv

# 5. Session depth
$DB -c "COPY (
  SELECT query_position as depth, COUNT(*) as sessions
  FROM (
    SELECT session_id, MAX(query_position) as query_position
    FROM queries GROUP BY session_id
  ) s
  GROUP BY query_position ORDER BY query_position
) TO STDOUT WITH CSV HEADER" > data_depth.csv

# 6. Device split
$DB -c "COPY (
  SELECT u.device_type, COUNT(DISTINCT q.query_id) as queries
  FROM queries q JOIN users u ON u.user_id = q.user_id
  GROUP BY u.device_type
) TO STDOUT WITH CSV HEADER" > data_devices.csv

# 7. KPI summary
$DB -c "COPY (
  SELECT
    COUNT(*) as total_queries,
    ROUND(COUNT(DISTINCT ce.click_id)::NUMERIC / NULLIF(COUNT(DISTINCT q.query_id),0) * 100, 1) as overall_ctr,
    ROUND(SUM(CASE WHEN q.result_count=0 THEN 1 ELSE 0 END)::NUMERIC / COUNT(*) * 100, 1) as zero_result_rate,
    ROUND(SUM(CASE WHEN q.result_count>0 AND ce.click_id IS NULL THEN 1 ELSE 0 END)::NUMERIC / NULLIF(SUM(CASE WHEN q.result_count>0 THEN 1 ELSE 0 END),0) * 100, 1) as abandonment_rate
  FROM queries q
  LEFT JOIN click_events ce ON ce.query_id = q.query_id
) TO STDOUT WITH CSV HEADER" > data_kpis.csv

echo ""
echo "Done! Files created:"
ls data_*.csv
echo ""
echo "Now open index.html in your browser."
