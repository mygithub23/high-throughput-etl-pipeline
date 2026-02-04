# NDJSON to Parquet Pipeline

A high-throughput, serverless AWS pipeline that converts NDJSON files to optimized Parquet format using batch processing, distributed locking, and manifest-based orchestration.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Pipeline Components](#pipeline-components)
- [Data Flow](#data-flow)
- [End-of-Day Orphan Flush](#end-of-day-orphan-flush)
- [DynamoDB Operations](#dynamodb-operations)
- [Step Functions Orchestration](#step-functions-orchestration)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [File Processing Lifecycle](#file-processing-lifecycle)
- [Configuration](#configuration)
- [Testing](#testing)
- [Cost Optimization](#cost-optimization)

---

## Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   S3 Input      │    │     SQS         │    │    Lambda       │    │  Step Functions │
│   Bucket        │───▶│    Queue        │───▶│ Manifest Builder│───▶│    Workflow     │
│  (NDJSON files) │    │ (Event Buffer)  │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └────────┬────────┘    └────────┬────────┘
                                                       │                      │
                                                       ▼                      ▼
                                              ┌─────────────────┐    ┌─────────────────┐
                                              │   DynamoDB      │    │   Glue ETL      │
                                              │ File Tracking   │◀───│     Job         │
                                              │                 │    │                 │
                                              └─────────────────┘    └────────┬────────┘
                                                                              │
                                                                              ▼
                                                                     ┌─────────────────┐
                                                                     │   S3 Output     │
                                                                     │    Bucket       │
                                                                     │ (Parquet files) │
                                                                     └─────────────────┘
```

---

## Pipeline Components

### 1. S3 Input Bucket
- Receives NDJSON files from data producers
- Configured with S3 Event Notifications to trigger processing
- Files are expected in format: `pipeline/input/{date}-{name}.ndjson`

### 2. SQS Queue
- Buffers S3 ObjectCreated events
- Provides decoupling between file arrival and processing
- Configured batch size: 10 messages per Lambda invocation
- Dead Letter Queue (DLQ) captures failed messages after 3 retries

### 3. Lambda Manifest Builder
- Triggered by SQS queue
- Validates incoming files (extension, size)
- Tracks files in DynamoDB with `pending` status
- Uses distributed locking to prevent race conditions
- Creates manifest files when threshold reached (10 files)
- Triggers Step Functions workflow

### 4. DynamoDB Tables

#### File Tracking Table
| Attribute | Type | Description |
|-----------|------|-------------|
| `date_prefix` | String (PK) | Date partition key (YYYY-MM-DD) |
| `file_key` | String (SK) | Filename or "LOCK"/"MANIFEST" |
| `status` | String | pending, manifested, processing, completed, failed |
| `file_path` | String | Full S3 URI of the file |
| `file_size_mb` | Number | File size in megabytes |
| `manifest_path` | String | Associated manifest S3 path |
| `created_at` | String | ISO timestamp |
| `ttl` | Number | TTL for automatic cleanup |

#### Metrics Table
| Attribute | Type | Description |
|-----------|------|-------------|
| `metric_type` | String (PK) | Type of metric |
| `timestamp` | Number (SK) | Unix timestamp |
| `value` | Number | Metric value |
| `ttl` | Number | TTL for automatic cleanup |

### 5. S3 Manifest Bucket
- Stores manifest JSON files listing batch contents
- Path format: `manifests/{date}/batch-{num}-{timestamp}.json`
- Manifest structure:
```json
{
  "fileLocations": [
    {
      "URIPrefixes": [
        "s3://input-bucket/pipeline/input/file1.ndjson",
        "s3://input-bucket/pipeline/input/file2.ndjson"
      ]
    }
  ]
}
```

### 6. Step Functions Workflow
- Standard workflow type (required for `.sync` Glue integration)
- Orchestrates Glue job execution with status tracking
- Updates DynamoDB status at each stage
- Sends SNS alerts on failure

### 7. Glue ETL Job
- PySpark job that reads NDJSON and writes Parquet
- Processes files listed in manifest
- Uses Snappy compression by default
- Adds processing metadata columns

### 8. S3 Output Bucket
- Stores converted Parquet files
- Path format: `merged-parquet-{date}/part-*.snappy.parquet`

---

## Data Flow

### Step-by-Step Process

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 1: FILE ARRIVAL                                                           │
│  ────────────────────                                                           │
│  Data producer uploads NDJSON file to S3 input bucket                          │
│  S3 generates ObjectCreated event and sends to SQS queue                       │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 2: LAMBDA TRIGGER                                                         │
│  ──────────────────────                                                         │
│  SQS triggers Lambda with batch of up to 10 messages                           │
│  Lambda parses S3 events from SQS messages                                     │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 3: FILE VALIDATION & TRACKING                                             │
│  ──────────────────────────────────                                             │
│  For each file:                                                                 │
│    • Validate extension (.ndjson required)                                      │
│    • Validate file size (within tolerance of expected size)                    │
│    • Extract date from filename (YYYY-MM-DD)                                   │
│    • Write to DynamoDB: status='pending'                                        │
│  Invalid files are moved to quarantine bucket                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 4: DISTRIBUTED LOCK ACQUISITION                                           │
│  ────────────────────────────────────                                           │
│  Lambda attempts to acquire lock for manifest creation                         │
│  Lock key: LOCK#manifest-{date_prefix}                                         │
│  If lock fails → another Lambda instance is processing (normal behavior)       │
│  Lock TTL: 300 seconds (prevents deadlocks)                                    │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 5: BATCH THRESHOLD CHECK                                                  │
│  ────────────────────────────────                                               │
│  Query DynamoDB for pending files with same date_prefix                        │
│  If count >= MAX_FILES_PER_MANIFEST (default: 10):                             │
│    → Proceed to manifest creation                                              │
│  Else:                                                                         │
│    → Wait for more files, release lock, exit                                   │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 6: MANIFEST CREATION                                                      │
│  ─────────────────────────                                                      │
│  Create JSON manifest with list of S3 URIs                                     │
│  Upload to manifest bucket                                                     │
│  Update all included files: status='manifested'                                │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 7: STEP FUNCTIONS TRIGGER                                                 │
│  ──────────────────────────────                                                 │
│  Lambda starts Step Functions execution with:                                  │
│    • manifest_path: S3 URI of manifest                                         │
│    • date_prefix: Date partition                                               │
│    • file_count: Number of files in batch                                      │
│    • timestamp: Processing start time                                          │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 8: STATUS UPDATE (PROCESSING)                                             │
│  ──────────────────────────────────                                             │
│  Step Functions updates DynamoDB:                                              │
│    • Key: date_prefix + "MANIFEST"                                             │
│    • status='processing'                                                       │
│    • processing_start_time                                                     │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  STEP 9: GLUE JOB EXECUTION                                                     │
│  ──────────────────────────                                                     │
│  Step Functions starts Glue job with .sync (waits for completion)              │
│  Arguments passed:                                                             │
│    • --MANIFEST_PATH: S3 URI of manifest                                       │
│    • --MANIFEST_BUCKET: Bucket containing manifests                            │
│    • --OUTPUT_BUCKET: Destination for Parquet files                            │
│    • --COMPRESSION_TYPE: Compression codec (snappy)                            │
│                                                                                 │
│  Glue job:                                                                     │
│    1. Reads manifest JSON                                                      │
│    2. Loads all NDJSON files from manifest                                     │
│    3. Merges into single DataFrame                                             │
│    4. Adds _processing_timestamp and _source_file columns                      │
│    5. Writes as Parquet with Snappy compression                                │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                              ┌─────────┴─────────┐
                              ▼                   ▼
┌──────────────────────────────────┐  ┌──────────────────────────────────┐
│  STEP 10a: SUCCESS               │  │  STEP 10b: FAILURE               │
│  ─────────────────               │  │  ─────────────────               │
│  Update DynamoDB:                │  │  Update DynamoDB:                │
│    • status='completed'          │  │    • status='failed'             │
│    • completed_time              │  │    • failed_time                 │
│    • glue_job_run_id             │  │    • error_message               │
│                                  │  │                                  │
│  Workflow ends successfully      │  │  Send SNS alert notification     │
└──────────────────────────────────┘  └──────────────────────────────────┘
```

---

## End-of-Day Orphan Flush

### The Problem

When using batch processing with a file count threshold (e.g., 10 files per manifest), files can become "orphaned" if the day changes before reaching the threshold.

**Example Scenario:**
- On 2026-01-12, 500 NDJSON files arrive
- With `MAX_FILES_PER_MANIFEST=200`, the Lambda creates 2 manifests (400 files)
- 100 files remain with `status=pending` for date `2026-01-12`
- Midnight passes, it's now 2026-01-13
- New files arrive with date prefix `2026-01-13`
- The 100 files from `2026-01-12` would never be processed!

### The Solution: Automatic Orphan Flush

The Lambda automatically detects and processes orphaned files from previous days:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  ORPHAN DETECTION LOGIC                                                         │
│  ──────────────────────                                                         │
│                                                                                 │
│  When processing a file with date_prefix:                                       │
│                                                                                 │
│    today = current UTC date (e.g., "2026-01-13")                               │
│    file_date = date from filename (e.g., "2026-01-12")                         │
│                                                                                 │
│    if file_date < today:                                                        │
│      → This is an ORPHAN from a previous day                                   │
│      → Use MIN_FILES_FOR_PARTIAL_BATCH threshold (default: 1)                  │
│      → Create manifest with ALL remaining files (partial batch OK)             │
│    else:                                                                        │
│      → Normal processing                                                        │
│      → Use MAX_FILES_PER_MANIFEST threshold (default: 10)                      │
│      → Only create full batches                                                │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### How It Works

1. **New file arrives** with date `2026-01-12` (but today is `2026-01-13`)
2. **Lambda detects** the file's date is in the past
3. **Orphan flush triggered** - Lambda queries all pending files for `2026-01-12`
4. **Partial batch created** - Even if only 100 files, a manifest is created
5. **Normal processing** - Step Functions and Glue process the manifest

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_FILES_PER_MANIFEST` | 10 | Threshold for current day batches |
| `MIN_FILES_FOR_PARTIAL_BATCH` | 1 | Minimum files for orphan flush (previous days) |

### Trigger Mechanisms

Orphan flush is triggered automatically when:

1. **New file arrives for old date** - A file with a previous day's date prefix triggers flush for that date
2. **Late-arriving files** - Files that arrive after midnight with yesterday's date

### Example Timeline

```
Day 1 (2026-01-12):
  09:00  File arrives → tracked as pending (date: 2026-01-12)
  09:01  File arrives → tracked as pending (date: 2026-01-12)
  ...
  23:59  95 files pending for 2026-01-12 (threshold: 100 not reached)

Day 2 (2026-01-13):
  00:01  New file arrives (date: 2026-01-13) → normal processing
  00:05  Late file arrives (date: 2026-01-12)
         → Lambda detects 2026-01-12 < 2026-01-13
         → Orphan flush triggered!
         → Manifest created with all 96 pending files from 2026-01-12
         → Step Functions processes the batch
```

### Log Messages

When orphan flush occurs, you'll see these log messages:

```
INFO: Date 2026-01-12 is from a previous day (today: 2026-01-13)
INFO: Triggering end-of-day flush for orphaned files
INFO: Processing 96 orphaned files from 2026-01-12
INFO: Including partial batch with 96 files (orphan flush)
INFO: Manifest created: s3://manifest-bucket/manifests/2026-01-12/batch-0001-...
```

---

## DynamoDB Operations

### Operation Matrix

| Operation | When | Table | Key | Purpose |
|-----------|------|-------|-----|---------|
| **PutItem** | File arrival | File Tracking | date_prefix + file_key | Track new file with status='pending' |
| **PutItem** | Lock acquire | File Tracking | LOCK#manifest-{date} + LOCK | Distributed lock for manifest creation |
| **DeleteItem** | Lock release | File Tracking | LOCK#manifest-{date} + LOCK | Release distributed lock |
| **Query** | Threshold check | File Tracking | date_prefix | Get pending files count |
| **UpdateItem** | Manifest created | File Tracking | date_prefix + file_key | Update status='manifested' |
| **UpdateItem** | Job starting | File Tracking | date_prefix + MANIFEST | status='processing' |
| **UpdateItem** | Job completed | File Tracking | date_prefix + MANIFEST | status='completed' |
| **UpdateItem** | Job failed | File Tracking | date_prefix + MANIFEST | status='failed' |

### Distributed Locking Mechanism

The Lambda function uses DynamoDB conditional writes for distributed locking:

```python
# Acquire lock
table.put_item(
    Item={
        'date_prefix': 'LOCK#manifest-2025-01-17',
        'file_key': 'LOCK',
        'lock_id': 'unique_instance_id',
        'ttl': current_time + 300
    },
    ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now'
)

# Release lock
table.delete_item(
    Key={'date_prefix': 'LOCK#manifest-2025-01-17', 'file_key': 'LOCK'},
    ConditionExpression='lock_id = :lock_id'
)
```

**Why Locking?**
- Multiple Lambda instances may run concurrently
- Prevents duplicate manifest creation for same batch
- Lock TTL ensures recovery from crashed instances

### File Status Transitions

```
pending ──────┬──────▶ manifested ──────▶ processing ──────┬──────▶ completed
              │                                            │
              │                                            └──────▶ failed
              │
              └──────▶ quarantined (invalid files)
```

---

## Step Functions Orchestration

### State Machine Definition

```
┌─────────────────────────────────────────────────────────────────┐
│                    Step Functions Workflow                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌───────────────────────────┐                                │
│   │  UpdateStatusProcessing   │ ◀── Entry Point                │
│   │  (DynamoDB UpdateItem)    │                                │
│   └─────────────┬─────────────┘                                │
│                 │                                               │
│                 ▼                                               │
│   ┌───────────────────────────┐                                │
│   │      StartGlueJob         │                                │
│   │  (Glue StartJobRun.sync)  │ ── Retry on concurrent runs    │
│   └─────────────┬─────────────┘                                │
│                 │                                               │
│        ┌───────┴───────┐                                       │
│        │               │                                        │
│        ▼               ▼                                        │
│   ┌─────────┐    ┌─────────────┐                               │
│   │ Success │    │   Failure   │                               │
│   └────┬────┘    └──────┬──────┘                               │
│        │                │                                       │
│        ▼                ▼                                       │
│   ┌─────────────┐  ┌─────────────┐                             │
│   │ UpdateStatus│  │ UpdateStatus│                             │
│   │  Completed  │  │   Failed    │                             │
│   └─────────────┘  └──────┬──────┘                             │
│                          │                                      │
│                          ▼                                      │
│                    ┌─────────────┐                              │
│                    │SendFailure  │                              │
│                    │   Alert     │                              │
│                    │   (SNS)     │                              │
│                    └─────────────┘                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Input/Output

**Input (from Lambda):**
```json
{
  "manifest_path": "s3://manifest-bucket/manifests/2025-01-17/batch-0001-20250117-143022.json",
  "date_prefix": "2025-01-17",
  "file_count": 10,
  "timestamp": "2025-01-17T14:30:22.000Z"
}
```

**Arguments Passed to Glue:**
| Argument | Source | Description |
|----------|--------|-------------|
| `--MANIFEST_PATH` | Input | S3 path to manifest file |
| `--MANIFEST_BUCKET` | Config | Bucket containing manifests |
| `--OUTPUT_BUCKET` | Config | Destination bucket for Parquet |
| `--COMPRESSION_TYPE` | Config | Compression codec (snappy) |

### Retry Policy

The Glue job step includes retry logic:
- **Error**: `Glue.ConcurrentRunsExceededException`
- **Initial Interval**: 60 seconds
- **Max Attempts**: 3
- **Backoff Rate**: 2.0x

---

## Monitoring and Alerting

### CloudWatch Dashboard

A pre-configured dashboard displays key metrics:

**Lambda Metrics Panel:**
- Invocations (Sum)
- Errors (Sum)
- Throttles (Sum)
- Duration (Average)
- Concurrent Executions (Maximum)

**DynamoDB Metrics Panel:**
- Consumed Read Capacity Units
- Consumed Write Capacity Units
- User Errors
- System Errors

**Glue Job Metrics Panel:**
- Completed Tasks
- Failed Tasks
- Killed Tasks

### CloudWatch Alarms

| Alarm | Threshold | Severity | Description |
|-------|-----------|----------|-------------|
| Lambda-Errors | > 10 in 5 min | CRITICAL | Lambda function execution errors |
| Lambda-Throttles | > 5 in 5 min | CRITICAL | Lambda function throttling |
| Lambda-ConcurrentExecutions | > 40 | WARNING | Approaching concurrency limit |
| FileTracking-ReadThrottle | > 5 in 5 min | WARNING | DynamoDB read throttling |
| FileTracking-WriteThrottle | > 5 in 5 min | WARNING | DynamoDB write throttling |
| GlueJob-Failures | > 10 in 5 min | CRITICAL | Glue job task failures |

### SNS Alerts

**Alert Topic:** `ndjson-parquet-alerts-{environment}`

Alerts are triggered for:
- Step Functions workflow failures
- CloudWatch alarm state changes

**Alert Payload (Step Functions Failure):**
```json
{
  "FunctionError": "Glue job failed for manifest: s3://...",
  "DatePrefix": "2025-01-17",
  "ManifestPath": "s3://...",
  "Error": { "Cause": "...", "Error": "..." },
  "Timestamp": "2025-01-17T14:35:00.000Z",
  "ExecutionArn": "arn:aws:states:...",
  "StateMachineName": "ndjson-parquet-processor-dev"
}
```

### CloudWatch Log Groups

| Component | Log Group | Retention |
|-----------|-----------|-----------|
| Lambda | `/aws/lambda/ndjson-parquet-manifest-builder-{env}` | 14 days |
| Step Functions | `/aws/states/ndjson-parquet-processor-{env}` | 14 days |
| Glue Job | `/aws-glue/jobs/{job-name}` | Default |

---

## File Processing Lifecycle

### Timeline Example

```
T+0ms     File uploaded to S3
T+100ms   S3 event sent to SQS
T+500ms   Lambda triggered by SQS batch
T+600ms   File validated and tracked in DynamoDB (status: pending)
T+700ms   Lock acquired for manifest creation
T+800ms   Pending files queried (count: 10)
T+900ms   Manifest created and uploaded to S3
T+1000ms  Files updated (status: manifested)
T+1100ms  Step Functions execution started
T+1200ms  DynamoDB updated (status: processing)
T+1500ms  Glue job started
T+180000ms  Glue job completed (~3 minutes)
T+180100ms  DynamoDB updated (status: completed)
T+180200ms  Parquet files available in output bucket
```

### Path Transformations

```
Input:    s3://input-bucket/pipeline/input/2025-01-17-test0001-143022-uuid.ndjson
                                    ↓
Manifest: s3://manifest-bucket/manifests/2025-01-17/batch-0001-20250117-143100.json
                                    ↓
Output:   s3://output-bucket/merged-parquet-2025-01-17/part-00000.snappy.parquet
```

---

## Configuration

### Environment Variables (Lambda)

| Variable | Description | Default |
|----------|-------------|---------|
| `MANIFEST_BUCKET` | S3 bucket for manifests | Required |
| `TRACKING_TABLE` | DynamoDB table name | Required |
| `STEP_FUNCTION_ARN` | Step Functions ARN | Required |
| `MAX_FILES_PER_MANIFEST` | Batch threshold for current day | 10 |
| `MIN_FILES_FOR_PARTIAL_BATCH` | Min files for orphan flush (previous days) | 1 |
| `EXPECTED_FILE_SIZE_MB` | Expected file size | 3.5 |
| `SIZE_TOLERANCE_PERCENT` | Size tolerance | 10 |
| `LOCK_TTL_SECONDS` | Lock timeout | 300 |
| `QUARANTINE_BUCKET` | Bucket for invalid files | Optional |

### Terraform Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `environment` | Environment name | dev |
| `dynamodb_read_capacity` | DynamoDB RCU | 5 |
| `dynamodb_write_capacity` | DynamoDB WCU | 25 |
| `enable_autoscaling` | Enable DynamoDB autoscaling | true |
| `lambda_memory_size` | Lambda memory MB | 256 |
| `lambda_timeout` | Lambda timeout seconds | 60 |
| `glue_worker_type` | Glue worker type | G.1X |
| `glue_number_of_workers` | Glue worker count | 2 |

---

## Testing

### Cost-Optimized Test

Use the provided test script for controlled testing:

```bash
cd ndjson-manifest-parquet
python cost_optimized_test.py
```

This generates 12 small test files (~100KB each) to trigger exactly one pipeline run.

### Check Pipeline Status

```bash
python cost_optimized_test.py status
```

### Monitor Execution

```bash
# Lambda logs
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow

# Step Functions executions
aws stepfunctions list-executions \
  --state-machine-arn <ARN> \
  --max-results 5
```

---

## Cost Optimization

### Cost Breakdown (Estimated)

| Component | % of Total | Notes |
|-----------|------------|-------|
| Glue ETL | ~90% | $0.44/DPU-hour minimum |
| Lambda | ~5% | $0.0000166667/GB-second |
| DynamoDB | ~3% | Provisioned capacity |
| S3 | ~2% | Storage + requests |

### Optimization Strategies

1. **Batch Size**: Larger batches reduce Glue job invocations
2. **DynamoDB Capacity**: Use auto-scaling or on-demand
3. **Glue Workers**: Minimize workers for small batches
4. **File Validation**: Quarantine invalid files early
5. **TTL**: Enable DynamoDB TTL for automatic cleanup

---

## Project Structure

```
high-throughputh-ingestion-pipeline/
├── terraform/
│   ├── main.tf                 # Root module
│   ├── variables.tf            # Input variables
│   ├── outputs.tf              # Output values
│   └── modules/
│       ├── s3/                 # S3 buckets
│       ├── sqs/                # SQS queues
│       ├── lambda/             # Lambda function
│       ├── dynamodb/           # DynamoDB tables
│       ├── step_functions/     # Step Functions workflow
│       ├── glue/               # Glue ETL job
│       ├── iam/                # IAM roles/policies
│       └── monitoring/         # CloudWatch alarms/dashboard
├── environments/
│   └── dev/
│       ├── lambda/             # Lambda source code
│       └── glue/               # Glue job script
├── docs/
│   ├── ARCHITECTURE.md         # Mermaid diagrams
│   ├── architecture_diagram.py # PNG diagram generator
│   └── data_flow_diagram.py    # Data flow diagram generator
└── ndjson-manifest-parquet/
    ├── TestDataGenerator.py    # Load testing tool
    └── cost_optimized_test.py  # Cost-efficient testing
```

---

## Deployment

```bash
# Initialize Terraform
cd terraform
terraform init

# Plan changes
terraform plan -out=tfplan

# Apply infrastructure
terraform apply tfplan

# Deploy Lambda code
cd ../environments/dev/lambda
zip lambda.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-manifest-builder-dev \
  --zip-file fileb://lambda.zip

# Upload Glue script
aws s3 cp ../glue/glue_batch_job.py s3://<scripts-bucket>/glue/
```

---

## License

Internal use only.
