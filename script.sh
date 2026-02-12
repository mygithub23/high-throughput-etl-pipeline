
# The user wants a command to export S3 bucket object metadata (filename, modified datetime, size) to a CSV file. This is a straightforward AWS CLI question.
aws s3api list-objects-v2 --bucket YOUR_BUCKET_NAME --prefix "pipeline/input/" --region us-east-1 --query 'Contents[*].[Key,LastModified,Size]' --output text | tr '\t' ',' | sed '1i\filename,modified,size_bytes' > output/s3-objects.csv


# Or for a cleaner output with human-readable sizes:
# Replace the bucket name and prefix as needed. For the output bucket use ndjson-output-sqs-804450520964-dev, etc.
aws s3api list-objects-v2 --bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/" --region us-east-1 --output json | python3 -c "
import sys, json, csv
data = json.load(sys.stdin)
w = csv.writer(sys.stdout)
w.writerow(['filename', 'modified', 'size_bytes', 'size_mb'])
for obj in data.get('Contents', []):
    name = obj['Key'].split('/')[-1]
    w.writerow([name, obj['LastModified'], obj['Size'], f\"{obj['Size']/1024/1024:.4f}\"])
" > output/s3-objects.csv


# For a specific date's objects, add --query filtering on the key pre
aws s3api list-objects-v2 --bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/2026-02-06" --region us-east-1 --output json | python3 -c "
import sys, json, csv
data = json.load(sys.stdin)
w = csv.writer(sys.stdout)
w.writerow(['filename', 'modified', 'size_bytes', 'size_mb'])
for obj in data.get('Contents', []):
    name = obj['Key'].split('/')[-1]
    w.writerow([name, obj['LastModified'], obj['Size'], f\"{obj['Size']/1024/1024:.4f}\"])
" > output/s3-input-2026-02-06.csv


# Just change the date in the --prefix value. Works for any bucket:

# Input bucket
--bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/2026-02-06"

# Output bucket (parquet files)
--bucket ndjson-output-sqs-804450520964-dev --prefix "pipeline/output/2026-02-06"

# Manifests
--bucket ndjson-manifest-sqs-804450520964-dev --prefix "manifests/2026-02-06"

# Create Athena database and table for s3 logs
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
