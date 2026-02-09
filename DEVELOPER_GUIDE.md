# NDJSON-to-Parquet ETL Pipeline: Developer Guide

A serverless, high-throughput ETL pipeline that converts NDJSON files to Parquet format using AWS managed services. Designed for production-scale workloads (338K+ files/day) with automatic batching, distributed concurrency control, and end-to-end status tracking.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow](#2-data-flow)
3. [DynamoDB Schema](#3-dynamodb-schema)
4. [Lambda Functions](#4-lambda-functions)
5. [Step Functions State Machine](#5-step-functions-state-machine)
6. [Glue Job](#6-glue-job)
7. [Configuration Reference](#7-configuration-reference)
8. [Key Design Decisions](#8-key-design-decisions)
9. [Project Structure](#9-project-structure)
10. [Deployment](#10-deployment)
11. [Monitoring & Alerting](#11-monitoring--alerting)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

### Pipeline Diagram

```
  .ndjson files
       |
       v
  +---------+    +-----+    +-------------------+    +----------+
  |   S3    | -> | SQS | -> | Lambda            | -> | DynamoDB |
  | (input) |    +-----+    | (manifest_builder)|    | (track)  |
  +---------+               +-------------------+    +----------+
                                     |
                             creates manifest
                                     v
                             +---------------+
                             | S3 (manifest) |
                             +---------------+
                                     |
                        EventBridge or direct invoke
                                     v
                             +----------------+    +--------------+
                             | Step Functions | -> |  Glue Job    |
                             +----------------+    | (Spark ETL)  |
                                                   +--------------+
                                                         |
                                  +-------------------+  |  +-------------+
                                  | Lambda            |<-+->| S3 (output) |
                                  | (batch_status_    |     | .parquet    |
                                  |  updater)         |     +-------------+
                                  +-------------------+
```

### AWS Components

| Service | Resource Name Pattern | Purpose |
|---|---|---|
| S3 | `ndjson-parquet-input-sqs-{env}-{account}` | Receives incoming NDJSON files |
| S3 | `ndjson-parquet-manifest-{env}-{account}` | Stores manifest JSON + metadata reports |
| S3 | `ndjson-parquet-output-{env}-{account}` | Parquet output with date partitions |
| S3 | `ndjson-parquet-quarantine-{env}-{account}` | Invalid files moved here |
| S3 | `ndjson-parquet-scripts-{env}-{account}` | Lambda/Glue deployment packages |
| SQS | `ndjson-parquet-file-events-{env}` | Buffers S3 events for Lambda |
| SQS | `ndjson-parquet-dlq-{env}` | Dead letter queue (14-day retention) |
| Lambda | `ndjson-parquet-manifest-builder-{env}` | File ingestion, validation, manifest creation |
| Lambda | `ndjson-parquet-batch-status-updater-{env}` | Post-Glue file status updates |
| Lambda | `ndjson-parquet-stream-manifest-creator-{env}` | DynamoDB Streams manifest creation (Phase 3) |
| DynamoDB | `ndjson-parquet-sqs-file-tracking-{env}` | File tracking with GSI |
| DynamoDB | `ndjson-parquet-sqs-metrics-{env}` | Pipeline metrics |
| Step Functions | `ndjson-parquet-processor-{env}` | Orchestrates Glue job with status tracking |
| Glue | `ndjson-parquet-batch-job-{env}` | Spark NDJSON-to-Parquet conversion |
| EventBridge | `ndjson-parquet-etl-{env}` | Decoupled Step Functions trigger (Phase 3) |
| SNS | `ndjson-parquet-alerts-{env}` | Pipeline failure alerts |
| CloudWatch | `ndjson-parquet-pipeline-{env}` | Dashboard for pipeline metrics |

---

## 2. Data Flow

### Step-by-Step Trace

1. **File Upload** -- NDJSON file lands in S3 input bucket under `pipeline/input/YYYY-MM-DD/filename.ndjson`.

2. **S3 Event Notification** -- S3 fires `s3:ObjectCreated:*` event, filtered to `.ndjson` suffix, sent to SQS.

3. **SQS Buffering** -- SQS queue buffers events with 6-minute visibility timeout. Long polling enabled (20s). Messages retried up to 3 times before moving to DLQ.

4. **Lambda Invocation** -- SQS triggers `manifest_builder` Lambda with batch of up to 10 messages per invocation.

5. **File Validation** -- Lambda validates each file: must have `.ndjson` extension and size within tolerance of expected size (`expected_file_size_mb +/- size_tolerance_percent`). Invalid files are copied to the quarantine bucket.

6. **DynamoDB Tracking** -- Valid files are recorded in the file tracking table with status `pending#N` (where N is a deterministic shard derived from MD5 of the filename). Idempotent via `ConditionExpression: attribute_not_exists(file_key)`.

7. **Threshold Check** -- Lambda queries for pending files on the same `date_prefix`. When count reaches `MAX_FILES_PER_MANIFEST` (default: 10), manifest creation begins.

8. **Atomic File Claiming** -- Each file is claimed individually via conditional update: `pending#N -> manifested#N`. Only files that were still pending are claimed. This replaces distributed locking with optimistic concurrency control.

9. **Manifest Creation** -- A manifest JSON is written to S3 at `manifests/{date_prefix}/batch-NNNN-YYYYMMDD-HHMMSS.json`. Contains `fileLocations[].URIPrefixes[]` listing all claimed file S3 paths.

10. **Workflow Trigger** -- Lambda either publishes a `ManifestReady` event to EventBridge (Phase 3) or directly starts a Step Functions execution, passing `manifest_path`, `date_prefix`, `file_count`, and `file_key` (MANIFEST# record key).

11. **Step Functions Orchestration** -- The state machine updates the MANIFEST meta-record to `processing`, starts the Glue job with `.sync` (waits for completion), then updates status to `completed` or `failed`.

12. **Glue Spark Processing** -- Glue reads all NDJSON files listed in the manifest, casts all columns to StringType, writes Parquet with Snappy compression to `s3://output-bucket/pipeline/output/merged-parquet-{date_prefix}/`.

13. **Batch Status Update** -- Step Functions invokes `batch_status_updater` Lambda, which queries all individual file records matching the manifest's `date_prefix` and `manifest_path`, and transitions each from `manifested#N` to `completed#N` (or `failed#N`).

14. **Orphan Flush** -- On every Lambda invocation, `flush_orphaned_dates()` scans all GSI shards for pending files from previous days and creates partial manifests for them (threshold: `MIN_FILES_FOR_PARTIAL_BATCH`, default: 1).

### Status Lifecycle

```
  pending#N ──> manifested#N ──> completed#N
                     |
                     └──────────> failed#N
```

Shard suffix (`#N`) is preserved across all transitions. The MANIFEST meta-record uses unsharded status values: `pending -> processing -> completed/failed`.

---

## 3. DynamoDB Schema

### File Tracking Table

**Table name:** `ndjson-parquet-sqs-file-tracking-{env}`

| Attribute | Type | Role | Description |
|---|---|---|---|
| `date_prefix` | S | Partition Key | Date string `YYYY-MM-DD` extracted from S3 key |
| `file_key` | S | Sort Key | Filename, or `MANIFEST#filename` / `LOCK#key` for meta-records |
| `file_path` | S | -- | Full S3 URI: `s3://bucket/path/file.ndjson` |
| `file_size_mb` | N | -- | File size in MB (Decimal) |
| `status` | S | GSI Hash Key | Sharded status: `pending#3`, `manifested#3`, `completed#3`, `failed#3` |
| `shard_id` | N | -- | Shard number (0 to NUM_STATUS_SHARDS-1) |
| `manifest_path` | S | -- | S3 URI of the manifest this file belongs to |
| `created_at` | S | -- | ISO 8601 timestamp |
| `updated_at` | S | -- | ISO 8601 timestamp of last status change |
| `completed_time` | S | -- | ISO 8601 timestamp (set on completion) |
| `failed_time` | S | -- | ISO 8601 timestamp (set on failure) |
| `glue_job_run_id` | S | -- | Glue job run ID (set on completion) |
| `error_message` | S | -- | Error details (set on failure, truncated to 1000 chars) |
| `ttl` | N | TTL | Unix timestamp for automatic record expiration (default: 30 days) |

**GSI: `status-index`**
- Hash key: `status`
- Range key: `date_prefix`
- Projection: ALL
- Used for: querying pending files across all dates (orphan flush), counting files by status

### Meta-Record Patterns

Records sharing the same table but distinguished by `file_key` prefix:

| Pattern | `date_prefix` | `file_key` | Purpose |
|---|---|---|---|
| File record | `2026-02-01` | `data-001.ndjson` | Individual file tracking |
| Manifest record | `2026-02-01` | `MANIFEST#batch-0001-20260201-120000.json` | Tracks manifest/workflow lifecycle |
| Lock record | `LOCK#2026-02-01` | `LOCK` | Distributed lock (legacy, replaced by atomic claims) |

### Metrics Table

**Table name:** `ndjson-parquet-sqs-metrics-{env}`

| Attribute | Type | Role |
|---|---|---|
| `metric_type` | S | Partition Key |
| `timestamp` | N | Sort Key |
| `ttl` | N | TTL attribute |

### DynamoDB Restriction: FilterExpression on Primary Keys

DynamoDB **prohibits** using partition key or sort key attributes in `FilterExpression`. This includes `file_key` (sort key). To filter out `MANIFEST#` and `LOCK#` meta-records when querying by `date_prefix`, filtering must be done in application code after the query returns. See `lambda_batch_status_updater.py:130-148`.

---

## 4. Lambda Functions

### manifest_builder

**File:** `environments/{env}/lambda/lambda_manifest_builder.py`
**Trigger:** SQS event source mapping (batch size: 10)
**Runtime:** Python 3.x, 512 MB memory (dev), 1024 MB (prod), 180s timeout

**Purpose:** Receives S3 file events via SQS, validates files, tracks them in DynamoDB, and creates manifest batches when the file count threshold is reached.

**Environment Variables:**

| Variable | Description | Dev Default |
|---|---|---|
| `MANIFEST_BUCKET` | S3 bucket for manifests | (created by Terraform) |
| `TRACKING_TABLE` | DynamoDB file tracking table name | `ndjson-parquet-sqs-file-tracking-dev` |
| `GLUE_JOB_NAME` | Glue job name for reference | `ndjson-parquet-batch-job-dev` |
| `MAX_FILES_PER_MANIFEST` | Files per batch threshold | `10` |
| `QUARANTINE_BUCKET` | S3 bucket for invalid files | (created by Terraform) |
| `EXPECTED_FILE_SIZE_MB` | Expected file size center | `10` |
| `SIZE_TOLERANCE_PERCENT` | Size validation tolerance | `99` |
| `STEP_FUNCTION_ARN` | Step Functions ARN for direct invoke | (deterministic ARN) |
| `MIN_FILES_FOR_PARTIAL_BATCH` | Minimum files for orphan flush | `1` |
| `TTL_DAYS` | DynamoDB record TTL | `30` |
| `NUM_STATUS_SHARDS` | GSI write-sharding count | `10` |
| `EVENT_BUS_NAME` | EventBridge bus name (Phase 3) | `""` (disabled) |
| `ENABLE_STREAM_MANIFEST_CREATION` | Use DynamoDB Streams instead | `false` |
| `LOG_LEVEL` | Logging level | `DEBUG` (dev), `INFO` (prod) |

**Key Functions:**

- `lambda_handler()` -- Entry point; iterates SQS records, calls `process_file()` for each.
- `process_file()` -- Validates, tracks, and triggers manifest creation.
- `_claim_files_atomically()` -- Per-file conditional writes for concurrency-safe claiming.
- `create_manifests_if_ready()` -- Checks threshold, creates batches, claims files, writes manifest, triggers workflow.
- `flush_orphaned_dates()` -- Scans all GSI shards in parallel for pending files from previous days.
- `publish_manifest_event()` -- Routes to EventBridge (with circuit breaker) or direct Step Functions.

**Concurrency Model:** Reserved concurrency of 2 (dev) / 50 (prod). SQS scaling config limits concurrent Lambda invocations. Multiple concurrent Lambdas are safe because file claiming uses per-file conditional writes -- no two Lambdas can claim the same file.

### batch_status_updater

**File:** `environments/{env}/lambda/lambda_batch_status_updater.py`
**Trigger:** Invoked by Step Functions after Glue job completes
**Runtime:** Python 3.x

**Purpose:** After a Glue job succeeds or fails, this Lambda batch-updates all individual file records belonging to that manifest. Step Functions can't loop over DynamoDB records natively, so this Lambda handles the batch operation.

**Input Schema (from Step Functions):**

```json
{
  "manifest_path": "s3://bucket/manifests/2026-02-01/batch-001.json",
  "date_prefix": "2026-02-01",
  "new_status": "completed",
  "glue_job_run_id": "jr_xxx",
  "error_message": "..."
}
```

**Shard-Preserving Logic:** When transitioning status, the Lambda extracts the shard suffix from the current status (e.g., `manifested#3`) and appends it to the new status (e.g., `completed#3`). This preserves GSI distribution.

### stream_manifest_creator

**File:** `environments/{env}/lambda/lambda_stream_manifest_creator.py`
**Trigger:** DynamoDB Streams (NEW_AND_OLD_IMAGES)
**Feature Flag:** `ENABLE_STREAM_MANIFEST_CREATION` (default: `false`)

**Purpose:** Event-driven alternative to the polling-based manifest creation in `manifest_builder`. Triggered by DynamoDB Streams when new file records are inserted. Groups INSERT events by `date_prefix` and creates manifests when the batch threshold is reached.

When this flag is enabled, the `manifest_builder` Lambda skips its own manifest creation logic (see `process_file()` line 521-522) and relies entirely on the stream-based approach.

---

## 5. Step Functions State Machine

**Name:** `ndjson-parquet-processor-{env}`
**Type:** Standard (required for `.sync` Glue integration)

### State Diagram

```
  [Start]
     |
     v
  UpdateStatusProcessing ──(error)──> UpdateStatusFailed
     |                                       |
     v                                       v
  StartGlueJob ──────────(error)──> UpdateStatusFailed
     |                                       |
     v                                       v
  UpdateStatusCompleted              BatchUpdateFailed
     |                                       |
     v                                       v
  BatchUpdateCompleted               SendFailureAlert
     |                                       |
     v                                       v
  PipelineSucceeded                   [End]
```

### States

| State | Resource | Purpose |
|---|---|---|
| `UpdateStatusProcessing` | DynamoDB UpdateItem | Sets MANIFEST meta-record status to `processing` |
| `StartGlueJob` | Glue StartJobRun.sync | Starts Glue job and waits for completion |
| `UpdateStatusCompleted` | DynamoDB UpdateItem | Sets MANIFEST meta-record to `completed` |
| `BatchUpdateCompleted` | Lambda Invoke | Updates individual file records to `completed` |
| `PipelineSucceeded` | Succeed | Terminal success state |
| `UpdateStatusFailed` | DynamoDB UpdateItem | Sets MANIFEST meta-record to `failed` |
| `BatchUpdateFailed` | Lambda Invoke | Updates individual file records to `failed` |
| `SendFailureAlert` | SNS Publish | Sends failure notification email |

### Retry & Error Handling

- **Glue ConcurrentRunsExceededException:** Retries 3 times with 60s interval, 2x backoff.
- **Lambda failures (batch updater):** Retries 2 times with 5s interval, 2x backoff. Failures are caught and the pipeline still succeeds (best-effort batch update).
- **All other errors:** Caught at each state, routed to the failure path.

### Deterministic ARN Construction

To avoid circular Terraform module dependencies, the Step Functions and IAM modules receive hardcoded function name strings instead of module outputs. The batch status updater function name is constructed as `ndjson-parquet-batch-status-updater-{env}` (see `terraform/main.tf:415`).

---

## 6. Glue Job

**File:** `environments/{env}/glue/glue_batch_job.py`
**Runtime:** Glue 4.0, PySpark

| Setting | Dev | Prod |
|---|---|---|
| Worker Type | G.1X | G.2X |
| Number of Workers | 2 | 20 |
| Max Concurrent Runs | 3 | 30 |
| Timeout | 2880 min (48h) | 2880 min (48h) |
| Max Retries | 1 | 1 |

### Processing Flow

1. Receives `--MANIFEST_PATH` argument pointing to a manifest JSON in S3.
2. Reads the manifest to extract file paths from `fileLocations[].URIPrefixes[]`.
3. Reads all NDJSON files using `spark.read.json()` with `multiLine=False`.
4. Adds `_processing_timestamp` and `_source_file` metadata columns.
5. Casts **all columns to StringType** for schema-agnostic storage.
6. Coalesces partitions based on estimated size (target: 128 MB per partition).
7. Writes Parquet with Snappy compression in append mode.

**Output path:** `s3://{output_bucket}/pipeline/output/merged-parquet-{date_prefix}/`

---

## 7. Configuration Reference

### Terraform Variables

| Variable | Type | Dev Default | Description |
|---|---|---|---|
| `environment` | string | `dev` | Environment name (`dev` or `prod`) |
| `aws_region` | string | `us-east-1` | AWS region |
| `max_files_per_manifest` | number | `10` | Batch size threshold |
| `expected_file_size_mb` | number | `10` | File validation center (MB) |
| `size_tolerance_percent` | number | `99` | Validation tolerance percentage |
| `dynamodb_read_capacity` | number | `5` | DynamoDB RCU |
| `dynamodb_write_capacity` | number | `25` | DynamoDB WCU |
| `dynamodb_ttl_days` | number | `30` | Record expiration (days) |
| `lambda_manifest_memory` | number | `512` | Lambda memory (MB) |
| `lambda_manifest_timeout` | number | `180` | Lambda timeout (seconds) |
| `lambda_manifest_concurrency` | number | `2` | Reserved concurrency |
| `glue_worker_type` | string | `G.1X` | Glue worker size |
| `glue_number_of_workers` | number | `2` | Glue workers |
| `glue_max_concurrent_runs` | number | `3` | Max parallel Glue jobs |
| `sqs_batch_size` | number | `10` | SQS -> Lambda batch size |
| `sqs_visibility_timeout` | number | `360` | SQS visibility timeout (s) |
| `sqs_max_receive_count` | number | `3` | Max retries before DLQ |
| `log_retention_days` | number | `3` | CloudWatch log retention |
| `enable_eventbridge_decoupling` | bool | `false` | Phase 3: EventBridge routing |
| `num_status_shards` | number | `10` | Phase 3: GSI shard count |
| `enable_stream_manifest_creation` | bool | `false` | Phase 3: DynamoDB Streams |

### Lambda Environment Variables

See the [manifest_builder section](#manifest_builder) for the complete table of environment variables injected by Terraform.

---

## 8. Key Design Decisions

### GSI Write-Sharding

**Problem:** All pending files write `status=pending` to the same GSI partition, creating a hot partition under high throughput.

**Solution:** Each file's status is suffixed with a shard number derived from MD5 of its filename: `pending#3`, `pending#7`, etc. This distributes writes across `NUM_STATUS_SHARDS` (default: 10) GSI partitions. Queries use `begins_with(status, 'pending')` to match all shards including the legacy unsharded `pending` value.

**Code:** `lambda_manifest_builder.py:97-122`

### Atomic Per-File Claims (Claim-First Pattern)

**Problem:** Multiple concurrent Lambda invocations could create overlapping manifests for the same files.

**Solution (v1 -- distributed lock):** Used a DynamoDB-based `DistributedLock` class. Abandoned due to race conditions when manifest creation happened before claiming.

**Solution (v2 -- claim-first):** Each file is claimed individually via conditional update (`ConditionExpression: status = expected_status`). The flow is: claim files with placeholder manifest path -> check if enough files were claimed -> create manifest -> update manifest path. If not enough files were claimed, release them back to `pending`.

**Code:** `lambda_manifest_builder.py:661-705`

### Circuit Breaker for EventBridge

**Problem:** If EventBridge is unavailable, every Lambda invocation would fail trying to publish events, wasting time and creating noise.

**Solution:** A circuit breaker (CLOSED -> OPEN -> HALF_OPEN) tracks consecutive EventBridge failures. After 3 failures, it opens for 300 seconds, rejecting calls immediately. After recovery timeout, it allows one test call (HALF_OPEN) and resets on success.

**Code:** `lambda_manifest_builder.py:124-185`

### Orphan Flush (End-of-Day Partial Batches)

**Problem:** If fewer than `MAX_FILES_PER_MANIFEST` files arrive for a given date, they sit in `pending` state forever.

**Solution:** On every Lambda invocation, `flush_orphaned_dates()` queries all GSI shards in parallel for `pending` files from dates before today. For these previous-day files, the threshold drops to `MIN_FILES_FOR_PARTIAL_BATCH` (default: 1), creating partial-batch manifests for any remaining files.

**Code:** `lambda_manifest_builder.py:825-920`

### Deterministic ARN Construction

**Problem:** Terraform circular dependencies when Lambda module needs Step Functions ARN (for triggering) and Step Functions module needs Lambda ARN (for batch updater).

**Solution:** Both ARNs are constructed deterministically using known naming patterns (`arn:aws:states:{region}:{account}:stateMachine:ndjson-parquet-processor-{env}`) and passed as strings, bypassing module output dependencies.

**Code:** `terraform/main.tf:126-134`

### FilterExpression Cannot Reference Primary Keys

**Problem:** `lambda_batch_status_updater` initially used `file_key` (sort key) in `FilterExpression` to exclude `MANIFEST#` and `LOCK#` records. DynamoDB rejects this with `ValidationException`.

**Solution:** Filter in application code after the query returns, not in the DynamoDB query itself.

**Code:** `lambda_batch_status_updater.py:130-148`

---

## 9. Project Structure

```
high-throughput-etl-pipeline-RELEASE/
|-- DEVELOPER_GUIDE.md              <-- this file
|-- environments/
|   |-- dev/
|   |   |-- lambda/
|   |   |   |-- lambda_manifest_builder.py
|   |   |   |-- lambda_batch_status_updater.py
|   |   |   |-- lambda_stream_manifest_creator.py
|   |   |-- glue/
|   |   |   |-- glue_batch_job.py
|   |   |-- scripts/                <-- operational/diagnostic scripts
|   |   |   |-- deploy-lambda.sh
|   |   |   |-- pipeline-status.sh
|   |   |   |-- diagnose-pipeline.sh
|   |   |   |-- check-dynamodb-files.sh
|   |   |   |-- cleanup-pipeline.sh
|   |   |   |-- README-LOCK-RECOVERY.md
|   |   |   |-- README-TIMEZONE.md
|   |   |   |-- ...
|   |-- prod/
|   |   |-- lambda/                 <-- production Lambda code
|   |   |-- glue/                   <-- production Glue code
|   |   |-- scripts/                <-- production operational scripts
|-- terraform/
|   |-- main.tf                     <-- root module wiring
|   |-- variables.tf                <-- all input variables
|   |-- terraform.tfvars            <-- dev defaults
|   |-- outputs.tf
|   |-- modules/
|   |   |-- s3/                     <-- bucket creation + lifecycle
|   |   |-- sqs/                    <-- queue, DLQ, event source mapping
|   |   |-- dynamodb/               <-- tables, GSI, auto-scaling
|   |   |-- lambda/                 <-- function definitions, env vars
|   |   |-- iam/                    <-- roles, policies
|   |   |-- glue/                   <-- job definition
|   |   |-- step_functions/         <-- state machine definition
|   |   |-- monitoring/             <-- alarms, dashboard, SNS
|-- codeReview/                     <-- architecture review documents
```

---

## 10. Deployment

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Python 3.x (for Lambda code)

### Infrastructure Deployment

```bash
cd terraform/

# Initialize Terraform
terraform init

# Plan changes
terraform plan -var-file="terraform.tfvars"

# Apply
terraform apply -var-file="terraform.tfvars"
```

### Lambda Code Deployment

Lambda code lives in `environments/{env}/lambda/`. Deploy using the helper script:

```bash
cd environments/dev/scripts/
./deploy-lambda.sh
```

This zips the Lambda code, uploads to the scripts S3 bucket, and updates the Lambda function.

### Glue Job Code Deployment

The Glue script is uploaded to the scripts S3 bucket. Terraform manages the Glue job definition, but the script file must be synced separately after code changes.

### Phase 3 Feature Flag Activation

Phase 3 features are behind feature flags that default to `false`. To enable:

```hcl
# In terraform.tfvars
enable_eventbridge_decoupling     = true   # EventBridge routing
enable_stream_manifest_creation   = true   # DynamoDB Streams
```

Apply with `terraform apply`. Both flags can be enabled independently. Enabling `enable_stream_manifest_creation` creates a DynamoDB Stream on the tracking table and deploys the `stream_manifest_creator` Lambda.

---

## 11. Monitoring & Alerting

### CloudWatch Alarms

Alarms are created in production only (`create_alarms = var.environment == "prod"`).

| Alarm Name | Severity | Threshold | Description |
|---|---|---|---|
| `Lambda-Errors` | CRITICAL | > 10 errors / 5 min | Lambda function errors |
| `Lambda-Throttles` | CRITICAL | > 5 throttles / 5 min | Lambda throttling |
| `Lambda-ConcurrentExecutions` | WARNING | > 40 concurrent | Approaching concurrency limit |
| `Lambda-DurationHigh` | WARNING | > 80% of timeout | Performance degradation |
| `Lambda-IteratorAgeHigh` | WARNING | > 60s | SQS processing backlog |
| `GlueJob-Failures` | CRITICAL | > 10 failed tasks / 5 min | Glue processing failures |
| `StepFunctions-ExecutionFailed` | CRITICAL | > 0 failures / 5 min | Workflow execution failure |
| `StepFunctions-ExecutionTimeout` | CRITICAL | > 0 timeouts / 5 min | Workflow timeout |
| `StepFunctions-ExecutionThrottled` | WARNING | > 5 throttles / 5 min | Capacity issue |
| `FileTracking-ReadThrottle` | WARNING | > 5 errors / 5 min | DynamoDB read throttling |
| `FileTracking-WriteThrottle` | WARNING | > 5 events / 5 min | DynamoDB write throttling |
| `FileTracking-SystemErrors` | CRITICAL | > 1 error / 5 min | AWS service issue |
| `SQS-QueueDepth` | WARNING | > 1000 messages | Queue backlog |
| `SQS-MessageAge` | WARNING | > 1 hour | Stale messages |
| `DLQ-Messages` | CRITICAL | > 1 message | Failed messages in DLQ |

### Log Groups

| Log Group | Source |
|---|---|
| `/aws/lambda/ndjson-parquet-manifest-builder-{env}` | manifest_builder Lambda |
| `/aws/lambda/ndjson-parquet-batch-status-updater-{env}` | batch_status_updater Lambda |
| `/aws/states/ndjson-parquet-processor-{env}` | Step Functions execution logs |
| Glue job logs | Stored in `logs/glue/` prefix in manifest bucket |

### SNS Topic

`ndjson-parquet-alerts-{env}` -- receives Step Functions failure alerts and CloudWatch alarm notifications. Email subscription configured via `alert_email` variable.

### Metadata Reports

Both Lambda and Glue upload execution metadata reports to S3:

- **Lambda:** `s3://{manifest_bucket}/logs/lambda/{date}-T{time}-{uuid}.json`
- **Glue:** `s3://{manifest_bucket}/logs/glue/{date}-T{time}-{uuid}.json`

Reports include execution timing, files processed, manifests created, and error details.

---

## 12. Troubleshooting

### Common Issues

| Symptom | Likely Cause | Fix |
|---|---|---|
| Files stuck in `pending` forever | Not enough files to reach `MAX_FILES_PER_MANIFEST` threshold | Wait for orphan flush (runs on next Lambda invocation for previous days), or lower `MAX_FILES_PER_MANIFEST` |
| Files stuck in `manifested` forever | `batch_status_updater` Lambda failed silently | Check Step Functions execution history; re-run the batch updater manually or use `remediate-manifested-files.sh` |
| DynamoDB `ValidationException` on FilterExpression | Primary key attribute used in FilterExpression | Filter `file_key` (sort key) in application code, not in DynamoDB query |
| Duplicate manifests created | Race condition in manifest creation | Verify atomic claim-first pattern is active; check that `_claim_files_atomically` is used |
| Glue `ConcurrentRunsExceededException` | Too many parallel Glue jobs | Step Functions retries automatically (3 attempts, 60s backoff); increase `glue_max_concurrent_runs` if persistent |
| Messages in DLQ | Lambda failures exceeding `sqs_max_receive_count` | Check Lambda CloudWatch logs; inspect DLQ messages with `aws sqs receive-message` |
| Pipeline alerts not received | SNS subscription not confirmed | Check email for SNS confirmation link; verify `alert_email` is set |
| EventBridge events not triggering Step Functions | Circuit breaker is OPEN | Check Lambda logs for "Circuit breaker OPEN" messages; wait for 300s recovery or restart Lambda |
| Files quarantined unexpectedly | File size outside tolerance range | Check `EXPECTED_FILE_SIZE_MB` and `SIZE_TOLERANCE_PERCENT`; dev uses 99% tolerance |

### Diagnostic Scripts

Scripts in `environments/dev/scripts/`:

| Script | Purpose |
|---|---|
| `pipeline-status.sh` | Overall pipeline health check |
| `diagnose-pipeline.sh` | Full diagnostic report |
| `check-dynamodb-files.sh` | Query DynamoDB file records |
| `check-lambda-logs.sh` | Tail Lambda CloudWatch logs |
| `check-manifest-records.sh` | Inspect MANIFEST meta-records |
| `check-locks.sh` | Check for stale lock records |
| `diagnose-batch-updater.sh` | Debug batch status updater issues |
| `dynamodb-queries.sh` | Common DynamoDB query templates |
| `stepfunctions-queries.sh` | Step Functions execution queries |
| `glue-queries.sh` | Glue job run queries |
| `remediate-manifested-files.sh` | Fix files stuck in `manifested` status |
| `reprocess-failed.sh` | Re-queue failed files for reprocessing |
| `cleanup-pipeline.sh` | Clean up test/stale data |
