# Development Scripts

Helper scripts for testing, debugging, and managing the NDJSON to Parquet pipeline.

## Quick Start

```bash
# Make scripts executable
chmod +x *.sh

# Run a quick end-to-end test
./quick-test.sh

# Check pipeline status
./pipeline-status.sh
```

## Scripts Overview

### Testing & Data Generation

| Script | Description |
|--------|-------------|
| `quick-test.sh` | End-to-end test with monitoring |
| `generate-test-files.sh` | Generate NDJSON test files |

**Examples:**
```bash
# Quick test with defaults (10 files, 1MB each)
./quick-test.sh

# Custom test (20 files, 5MB each)
./quick-test.sh 20 5

# Clean previous data before test
./quick-test.sh 10 1 --clean

# Just generate files (no upload)
./generate-test-files.sh 50 2

# Generate and upload in one step
./generate-test-files.sh 50 2 2026-01-20 --upload
```

---

### DynamoDB Queries (PartiQL)

| Script | Description |
|--------|-------------|
| `dynamodb-queries.sh` | Query file tracking table using PartiQL |

**Commands:**
```bash
# Show file counts by status
./dynamodb-queries.sh status

# Show all pending files
./dynamodb-queries.sh pending

# Show files for a specific date
./dynamodb-queries.sh date 2026-01-20

# Show all MANIFEST records
./dynamodb-queries.sh manifests

# Show all LOCK records
./dynamodb-queries.sh locks

# Delete all records for a date
./dynamodb-queries.sh delete-date 2025-12-25

# Run raw PartiQL query
./dynamodb-queries.sh raw "SELECT * FROM \"table\" WHERE status='failed'"
```

---

### Step Functions Queries

| Script | Description |
|--------|-------------|
| `stepfunctions-queries.sh` | Query and manage Step Functions executions |

**Commands:**
```bash
# List recent executions
./stepfunctions-queries.sh list

# Show running executions
./stepfunctions-queries.sh running

# Show failed executions
./stepfunctions-queries.sh failed

# Show execution details
./stepfunctions-queries.sh details <execution-arn>

# Show execution event history
./stepfunctions-queries.sh history <execution-arn>

# Show error summary
./stepfunctions-queries.sh errors

# Show statistics
./stepfunctions-queries.sh stats

# Stop a running execution
./stepfunctions-queries.sh stop <execution-arn>

# Stop all running executions
./stepfunctions-queries.sh stop-all
```

---

### Glue Job Queries

| Script | Description |
|--------|-------------|
| `glue-queries.sh` | Query and manage Glue job runs |

**Commands:**
```bash
# List recent job runs
./glue-queries.sh list

# Show running jobs
./glue-queries.sh running

# Show failed jobs
./glue-queries.sh failed

# Show job run details
./glue-queries.sh details <run-id>

# Show CloudWatch logs
./glue-queries.sh logs <run-id>

# Show error summary
./glue-queries.sh errors

# Show statistics
./glue-queries.sh stats

# Show job configuration
./glue-queries.sh config

# Stop a running job
./glue-queries.sh stop <run-id>
```

---

### Pipeline Management

| Script | Description |
|--------|-------------|
| `pipeline-status.sh` | Dashboard showing all component status |
| `cleanup-pipeline.sh` | Clean up test data and reset pipeline state |

**Status:**
```bash
# Full status dashboard
./pipeline-status.sh

# Quick summary
./pipeline-status.sh --quick
```

**Cleanup:**
```bash
# Show current state
./cleanup-pipeline.sh status

# Clean everything (S3 + DynamoDB + stop executions)
./cleanup-pipeline.sh all

# Clean specific date
./cleanup-pipeline.sh date 2025-12-25

# Clean only S3 buckets
./cleanup-pipeline.sh s3

# Clean only DynamoDB
./cleanup-pipeline.sh dynamodb

# Clean only pending records
./cleanup-pipeline.sh dynamodb-pending

# Stop all Step Function executions
./cleanup-pipeline.sh stop-executions

# Skip confirmation prompts
./cleanup-pipeline.sh all --force
```

---

## Common Workflows

### 1. Fresh Test Run
```bash
# Clean previous data
./cleanup-pipeline.sh date $(date +%Y-%m-%d) --force

# Run test
./quick-test.sh 20 2

# Check results
./pipeline-status.sh
```

### 2. Debug Failed Execution
```bash
# Find failed executions
./stepfunctions-queries.sh failed

# Get details
./stepfunctions-queries.sh details <arn>

# Check Glue logs
./glue-queries.sh errors
./glue-queries.sh logs <run-id>
```

### 3. Check Orphaned Files
```bash
# Show files from previous days still pending
./dynamodb-queries.sh pending

# Look for old date_prefix values
./dynamodb-queries.sh raw "SELECT date_prefix, COUNT(*) FROM \"table\" GROUP BY date_prefix"
```

### 4. Monitor Running Pipeline
```bash
# Watch status
watch -n 5 './pipeline-status.sh --quick'

# Or manual checks
./dynamodb-queries.sh status
./stepfunctions-queries.sh running
./glue-queries.sh running
```

---

## Environment Variables

Scripts use these default values:

| Variable | Default |
|----------|---------|
| `ENV` | `dev` |
| `REGION` | `us-east-1` |
| `TABLE_NAME` | `ndjson-parquet-sqs-file-tracking-dev` |
| `GLUE_JOB_NAME` | `ndjson-parquet-batch-job-dev` |
| `STATE_MACHINE_NAME` | `ndjson-parquet-processor-dev` |

To use different values, edit the script or export environment variables.

---

## Troubleshooting

### "Table not found" errors
Verify the table name matches your Terraform deployment:
```bash
aws dynamodb list-tables --region us-east-1
```

### "Permission denied"
Make scripts executable:
```bash
chmod +x *.sh
```

### PartiQL syntax errors
Table names with hyphens need quotes:
```bash
# Correct
./dynamodb-queries.sh raw "SELECT * FROM \"ndjson-parquet-sqs-file-tracking-dev\""
```

### No results from queries
Check that:
1. Resources exist in the correct region
2. Table/bucket names match your environment
3. Date prefix format is YYYY-MM-DD
