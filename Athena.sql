-- Both Lambda and Glue write JSON reports to the same S3 bucket under different prefixes:

-- Source	S3 path	Example
-- Lambda	logs/lambda/YYYY-MM-DD-Ttime-uuid-0001.json	logs/lambda/2025-02-11-T120530-a1b2c3d4-0001.json
-- Glue	logs/glue/YYYY-MM-DD-Ttime-uuid-0001.json	logs/glue/2025-02-11-T121045-e5f6a7b8-0001.json
-- Both are stored in the manifest bucket (MANIFEST_BUCKET).

-- To query them easily:


-- # List all Lambda reports
-- aws s3 ls s3://YOUR-MANIFEST-BUCKET/logs/lambda/ --recursive

-- # List all Glue reports
-- aws s3 ls s3://YOUR-MANIFEST-BUCKET/logs/glue/ --recursive

-- # View a specific report
-- aws s3 cp s3://YOUR-MANIFEST-BUCKET/logs/lambda/2025-02-11-T120530-a1b2c3d4-0001.json - | python3 -m json.tool

-- # Download all reports for a specific date
-- aws s3 cp s3://YOUR-MANIFEST-BUCKET/logs/ ./output/logs/ --recursive --exclude "*" --include "*/2025-02-11*"

-- # Quick summary of all Lambda reports for a date (files processed, manifests, errors)
-- aws s3 ls s3://YOUR-MANIFEST-BUCKET/logs/lambda/2025-02-11 --recursive | awk '{print $4}' | while read key; do
--   aws s3 cp "s3://YOUR-MANIFEST-BUCKET/$key" - 2>/dev/null | python3 -c "
-- import json,sys
-- d=json.load(sys.stdin)
-- s=d['processing_summary']
-- print(f\"{d['execution_metrics']['start_time'][:19]}  files={s['files_processed']}  manifests={s['manifests_created']}  errors={s['errors_count']}  status={s['status']}\")
-- "
-- done
-- For bulk querying across many reports, you could also use S3 Select or Athena — point Athena at the logs/lambda/ and logs/glue/ prefixes as JSON tables and run SQL queries against them. But for day-to-day use, the CLI commands above are the simplest approach.

-- Can query and extract insight from these json file using athena?
-- Yes, Athena can query those JSON files directly in S3. You'd create two tables — one for Lambda reports and one for Glue reports — then run SQL against them.

Setup

-- Create a database
CREATE DATABASE IF NOT EXISTS etl_pipeline;

-- Lambda reports table
CREATE EXTERNAL TABLE etl_pipeline.lambda_reports (
  execution_info struct<
    request_id: string,
    function_name: string,
    function_version: string,
    memory_limit_mb: string,
    log_group: string,
    log_stream: string
  >,
  execution_metrics struct<
    start_time: string,
    end_time: string,
    duration_seconds: double,
    remaining_time_ms: int
  >,
  processing_summary struct<
    files_processed: int,
    files_quarantined: int,
    manifests_created: int,
    errors_count: int,
    status: string
  >,
  manifests array<string>,
  errors array<string>,
  configuration struct<
    max_files_per_manifest: int,
    expected_file_size_mb: double,
    size_tolerance_percent: double,
    min_files_for_partial_batch: int
  >,
  report_metadata struct<
    generated_at: string,
    report_version: string,
    environment: string
  >
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://YOUR-MANIFEST-BUCKET/logs/lambda/'
TBLPROPERTIES ('has_encrypted_data'='false');

-- Glue reports table
CREATE EXTERNAL TABLE etl_pipeline.glue_reports (
  job_info struct<
    job_name: string,
    job_run_id: string,
    start_time: string,
    end_time: string,
    duration_seconds: double
  >,
  processing_summary struct<
    manifest_processed: string,
    batches_processed: int,
    records_processed: int,
    parquet_files_created: int,
    errors_count: int,
    status: string
  >,
  parquet_files array<string>,
  error_message string,
  report_metadata struct<
    generated_at: string,
    report_version: string,
    environment: string
  >
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://YOUR-MANIFEST-BUCKET/logs/glue/'
TBLPROPERTIES ('has_encrypted_data'='false');
Example queries

-- Daily summary: files processed, manifests created, errors
SELECT 
  substr(execution_metrics.start_time, 1, 10) AS date,
  COUNT(*) AS lambda_invocations,
  SUM(processing_summary.files_processed) AS total_files,
  SUM(processing_summary.manifests_created) AS total_manifests,
  SUM(processing_summary.files_quarantined) AS total_quarantined,
  SUM(processing_summary.errors_count) AS total_errors
FROM etl_pipeline.lambda_reports
GROUP BY substr(execution_metrics.start_time, 1, 10)
ORDER BY date DESC;

-- Failed Lambda executions
SELECT 
  execution_metrics.start_time,
  execution_info.request_id,
  processing_summary.status,
  errors
FROM etl_pipeline.lambda_reports
WHERE processing_summary.status = 'failed'
ORDER BY execution_metrics.start_time DESC;

-- Average Lambda duration and memory headroom
SELECT 
  substr(execution_metrics.start_time, 1, 10) AS date,
  ROUND(AVG(execution_metrics.duration_seconds), 2) AS avg_duration_s,
  ROUND(MAX(execution_metrics.duration_seconds), 2) AS max_duration_s,
  ROUND(AVG(execution_metrics.remaining_time_ms / 1000.0), 1) AS avg_remaining_s
FROM etl_pipeline.lambda_reports
GROUP BY substr(execution_metrics.start_time, 1, 10)
ORDER BY date DESC;

-- Glue job performance per run
SELECT 
  job_info.job_run_id,
  job_info.start_time,
  ROUND(job_info.duration_seconds, 1) AS duration_s,
  processing_summary.records_processed,
  processing_summary.parquet_files_created,
  processing_summary.status
FROM etl_pipeline.glue_reports
ORDER BY job_info.start_time DESC;

-- Glue failures with error details
SELECT 
  job_info.start_time,
  job_info.job_run_id,
  error_message
FROM etl_pipeline.glue_reports
WHERE processing_summary.status = 'failed'
ORDER BY job_info.start_time DESC;

-- End-to-end: Lambda → Glue correlation by manifest
SELECT 
  l.execution_metrics.start_time AS lambda_time,
  l.manifests AS manifest_paths,
  g.job_info.start_time AS glue_time,
  ROUND(g.job_info.duration_seconds, 1) AS glue_duration_s,
  g.processing_summary.records_processed,
  g.processing_summary.status AS glue_status
FROM etl_pipeline.lambda_reports l
CROSS JOIN UNNEST(l.manifests) AS t(manifest_path)
JOIN etl_pipeline.glue_reports g
  ON g.processing_summary.manifest_processed = t.manifest_path
ORDER BY l.execution_metrics.start_time DESC;
-- Cost
-- Athena charges $5 per TB scanned. These JSON report files are tiny (a few KB each), 
-- so even thousands of reports would cost fractions of a cent per query. 
-- This is essentially the metrics table functionality for free — no extra DynamoDB writes, 
-- no code changes, just SQL on top of data you're already generating.
