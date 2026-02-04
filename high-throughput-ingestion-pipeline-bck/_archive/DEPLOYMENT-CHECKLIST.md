# Deployment Checklist - Batch Mode Configuration

## ✅ What's Been Updated

All scripts and configurations have been updated to use **BATCH MODE (glueetl)** processing.

---

## Pre-Deployment Verification

### 1. Verify Current Configuration

Run these commands to check current settings:

```bash
# Check Lambda configuration
aws lambda get-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --region us-east-1 \
  --query 'Environment.Variables' \
  --output json

# Check Glue job configuration
aws glue get-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --query 'Job.{Command:Command.Name,Workers:NumberOfWorkers,Type:WorkerType,Concurrent:ExecutionProperty.MaxConcurrentRuns}' \
  --output json
```

**Expected Results:**
- Lambda: Should have `MAX_FILES_PER_MANIFEST` and `MAX_BATCH_SIZE_GB` set
- Glue: `Command.Name` should be `glueetl` (NOT `gluestreaming`)

---

## Development Environment Deployment

### Step 1: Deploy Dev Lambda

```bash
cd environments/dev/lambda

# Package Lambda
zip -r lambda.zip lambda_manifest_builder.py

# Deploy
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://lambda.zip \
  --region us-east-1

# Update configuration
aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --environment "Variables={
    TRACKING_TABLE=ndjson-parquet-sqs-file-tracking,
    METRICS_TABLE=ndjson-parquet-sqs-metrics,
    MANIFEST_BUCKET=ndjson-manifests-<ACCOUNT>,
    GLUE_JOB_NAME=ndjson-parquet-sqs-streaming-processor,
    MAX_FILES_PER_MANIFEST=50,
    MAX_BATCH_SIZE_GB=200,
    QUARANTINE_BUCKET=ndjson-quarantine-<ACCOUNT>,
    EXPECTED_FILE_SIZE_MB=10,
    SIZE_TOLERANCE_PERCENT=50,
    LOCK_TABLE=ndjson-parquet-sqs-file-tracking,
    LOCK_TTL_SECONDS=300
  }" \
  --memory-size 512 \
  --timeout 300 \
  --region us-east-1
```

**Verification:**
```bash
aws lambda get-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --region us-east-1 \
  --query 'Environment.Variables.MAX_FILES_PER_MANIFEST'
# Should output: "50"
```

### Step 2: Update Dev Glue Job

```bash
aws glue update-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update '{
    "Command": {"Name": "glueetl"},
    "WorkerType": "G.1X",
    "NumberOfWorkers": 10,
    "ExecutionProperty": {"MaxConcurrentRuns": 5},
    "GlueVersion": "4.0",
    "Timeout": 60,
    "MaxRetries": 1
  }' \
  --region us-east-1
```

**Verification:**
```bash
aws glue get-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --query 'Job.Command.Name' \
  --output text
# Should output: "glueetl"
```

### Step 3: Test Dev Environment

```bash
cd environments/dev/scripts

# Generate test data
./generate-test-data.sh 10 100

# Upload to S3
./upload-test-data.sh

# Monitor processing
watch -n 10 './check-lambda-logs.sh'

# Check DynamoDB
./check-dynamodb-files.sh

# Wait for processing (should take 5-10 minutes)
# Then check output
aws s3 ls s3://ndjson-output-sqs-<ACCOUNT>/parquet/ --recursive
```

**Expected Results:**
- 10 files tracked in DynamoDB
- 1 manifest created (10 files ÷ 50 per manifest, rounds to 1)
- 1 Glue job executed
- Parquet files in output bucket

---

## Production Environment Deployment

### Step 1: Review Configuration

Before deploying to production, review the configuration:

```bash
cd environments/prod/scripts

# Review deployment scripts
cat deploy-lambda.sh
cat deploy-glue.sh

# Check CONFIG-REFERENCE.md
cat ../CONFIG-REFERENCE.md
```

**Key Production Settings:**
- `MAX_FILES_PER_MANIFEST=100` (100 files per batch)
- `MAX_BATCH_SIZE_GB=500` (up to 450GB per batch)
- `EXPECTED_FILE_SIZE_MB=3500` (3.5 GB typical)
- `MaxConcurrentRuns=30` (30 Glue jobs in parallel)
- `NumberOfWorkers=20` (20 workers per job)
- `WorkerType=G.2X` (16 GB RAM per worker)

### Step 2: Deploy Production Lambda

```bash
cd environments/prod/scripts
./deploy-lambda.sh
```

**Verification:**
```bash
aws lambda get-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --region us-east-1 \
  --query '{
    MAX_FILES: Environment.Variables.MAX_FILES_PER_MANIFEST,
    MAX_SIZE: Environment.Variables.MAX_BATCH_SIZE_GB,
    FILE_SIZE: Environment.Variables.EXPECTED_FILE_SIZE_MB
  }' \
  --output json

# Should show:
# {
#   "MAX_FILES": "100",
#   "MAX_SIZE": "500",
#   "FILE_SIZE": "3500"
# }
```

### Step 3: Deploy Production Glue Job

```bash
./deploy-glue.sh
```

**Verification:**
```bash
aws glue get-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --query '{
    Mode: Command.Name,
    Workers: NumberOfWorkers,
    Type: WorkerType,
    Concurrent: ExecutionProperty.MaxConcurrentRuns
  }' \
  --output json

# Should show:
# {
#   "Mode": "glueetl",
#   "Workers": 20,
#   "Type": "G.2X",
#   "Concurrent": 30
# }
```

### Step 4: Progressive Load Testing

**Phase 1: Small Scale (10 files)**
```bash
cd environments/prod/scripts
./test-production-scale.sh
# Select: 1 (10 files)

# Expected:
# - Time: 5-10 minutes
# - Cost: $5-10
# - 1 manifest, 1 Glue job
```

**Phase 2: Medium Scale (100 files)**
```bash
./test-production-scale.sh
# Select: 2 (100 files)

# Expected:
# - Time: 10-15 minutes
# - Cost: $20-30
# - 1 manifest, 1 Glue job with 100 files
```

**Phase 3: Large Scale (1,000 files)**
```bash
./test-production-scale.sh
# Select: 3 (1,000 files)

# Expected:
# - Time: 30-60 minutes
# - Cost: $200-300
# - 10 manifests, up to 10 Glue jobs
```

**Phase 4: Full Scale (10,000 files)**
```bash
./test-production-scale.sh
# Select: 4 (10,000 files)

# Expected:
# - Time: 3-5 hours
# - Cost: $2,000-3,000
# - 100 manifests, 30 concurrent jobs processing in batches
```

### Step 5: Monitor Production

```bash
# Real-time monitoring
./monitor-pipeline.sh

# Watch specific metrics
watch -n 30 './monitor-pipeline.sh'

# Check for errors
./check-glue-errors.sh
```

---

## Post-Deployment Validation

### 1. Verify Batch Processing

```bash
# Check that jobs are running in batch mode
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --max-results 10 \
  --query 'JobRuns[*].{Started:StartedOn,State:JobRunState,Duration:ExecutionTime}' \
  --output table

# Jobs should:
# - Have discrete start/end times (not continuous)
# - Complete in 3-10 minutes each
# - Show SUCCEEDED or RUNNING status
```

### 2. Verify File Batching

```bash
# Check manifest contents
aws s3 cp s3://ndjson-manifests-<ACCOUNT>/manifests/$(date +%Y-%m-%d)/manifest-001.json - | jq '.files | length'

# Should output around 100 (or 50 for dev)
```

### 3. Verify Concurrent Processing

```bash
# Check concurrent jobs
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --max-results 50 \
  --query 'JobRuns[?JobRunState==`RUNNING`]' \
  --output json | jq 'length'

# Should show multiple jobs running (up to 30 in prod, 5 in dev)
```

### 4. Check Costs

```bash
# Monitor daily costs
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '1 day ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=SERVICE \
  --filter file://<(echo '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["AWS Glue", "AWS Lambda", "Amazon S3"]
    }
  }')
```

---

## Rollback Procedure

If issues occur, rollback to previous configuration:

### Rollback Lambda

```bash
# List previous versions
aws lambda list-versions-by-function \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --region us-east-1

# Rollback to specific version
aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --region us-east-1 \
  --environment "Variables={...previous config...}"
```

### Rollback Glue

```bash
# Revert to previous settings
aws glue update-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update '{
    "Command": {"Name": "glueetl"},
    "WorkerType": "G.1X",
    "NumberOfWorkers": 2,
    "ExecutionProperty": {"MaxConcurrentRuns": 1}
  }' \
  --region us-east-1
```

---

## Monitoring Checklist

After deployment, monitor these metrics daily:

- [ ] **Glue Job Success Rate**: Should be >95%
  ```bash
  ./check-glue-errors.sh
  ```

- [ ] **Processing Latency**: Files should be processed within 30 minutes
  ```bash
  ./monitor-pipeline.sh  # Check "Current Processing Rate"
  ```

- [ ] **Queue Depth**: SQS queue should stay below 1,000 messages
  ```bash
  ./monitor-pipeline.sh  # Check "SQS Queue Status"
  ```

- [ ] **Daily Costs**: Should match estimates in CONFIG-REFERENCE.md
  ```bash
  ./monitor-pipeline.sh  # Check "Estimated Cost (Today)"
  ```

- [ ] **DynamoDB Status**: Pending files should clear within 1 hour
  ```bash
  ./monitor-pipeline.sh  # Check "DynamoDB File Tracking"
  ```

---

## Performance Benchmarks

### Development Environment

**Expected Performance:**
- 10 KB files: Process 100 files in 2-3 minutes
- Latency: <5 minutes end-to-end
- Cost: <$1 per test run

### Production Environment

**Expected Performance (338K files/day):**

| Metric | Target | How to Verify |
|--------|--------|---------------|
| Manifests/day | 3,380 | `./monitor-pipeline.sh` |
| Processing time | 4-8 hours | Monitor Glue jobs |
| Concurrent jobs | 15-30 | `aws glue get-job-runs` |
| Success rate | >98% | `./check-glue-errors.sh` |
| Files/hour | 14,000-50,000 | Calculate from logs |
| Daily cost | $2,500-$3,500 | CloudWatch billing |

---

## Troubleshooting Guide

### Issue: Jobs Not Starting

**Symptom:** Manifests created but no Glue jobs running

**Check:**
```bash
# Verify Glue job exists
aws glue get-job --job-name ndjson-parquet-sqs-streaming-processor

# Check EventBridge rule (if using)
aws events list-rules --name-prefix trigger-glue
```

**Fix:** Manually trigger a job to test:
```bash
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --arguments='--manifest_path=s3://ndjson-manifests-<ACCOUNT>/manifests/2025-12-23/manifest-001.json'
```

### Issue: Jobs Failing with OOM

**Symptom:** Jobs fail with "OutOfMemoryError"

**Check:**
```bash
./check-glue-errors.sh
```

**Fix:** Increase worker size:
```bash
./update-batch-config.sh
# Select heavier configuration or increase worker type
```

### Issue: High Costs

**Symptom:** Daily costs exceed $5,000

**Check:**
```bash
./monitor-pipeline.sh  # Review cost estimate

# Check concurrent jobs
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --query 'JobRuns[?JobRunState==`RUNNING`] | length(@)'
```

**Fix:** Reduce concurrent jobs:
```bash
./update-batch-config.sh
# Select lighter preset (20 concurrent instead of 30)
```

### Issue: Slow Processing

**Symptom:** Takes >12 hours to process daily files

**Check:**
```bash
./monitor-pipeline.sh

# Check average job duration
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --max-results 20 \
  --query 'JobRuns[?JobRunState==`SUCCEEDED`].ExecutionTime' \
  --output json | jq 'add/length'
```

**Fix:** Increase parallelism:
```bash
./update-batch-config.sh
# Select heavier configuration (50 concurrent jobs)
```

---

## Success Criteria

Deployment is successful when:

- [x] Lambda configuration shows batch mode settings
- [x] Glue job shows `Command.Name = "glueetl"`
- [x] Dev test with 10 files completes successfully
- [x] Prod Phase 1 test (10 files) completes in <10 min
- [x] Prod Phase 2 test (100 files) completes in <15 min
- [x] Prod Phase 3 test (1,000 files) completes in <1 hour
- [x] All Parquet output validates correctly
- [x] No errors in CloudWatch logs
- [x] Costs align with estimates
- [x] Monitoring dashboard shows healthy status

---

## Next Steps After Successful Deployment

1. **Week 1-2: Monitor Closely**
   - Run `./monitor-pipeline.sh` daily
   - Check `./check-glue-errors.sh` for any failures
   - Track costs daily

2. **Week 3-4: Optimize**
   - Fine-tune concurrent jobs based on actual load patterns
   - Adjust batch sizes if needed
   - Consider time-based scaling (fewer jobs at night)

3. **Month 2: Cost Optimization**
   - Analyze cost breakdown
   - Plan EMR migration (see ARCHITECTURE-OPTIONS.md)
   - Target: Reduce costs by 60-70%

4. **Ongoing:**
   - Set up CloudWatch alarms
   - Create automated daily reports
   - Document any issues and solutions

---

## Summary

**All scripts and configurations have been updated to BATCH MODE.**

**Key Changes:**
- Glue Command: `glueetl` (batch, not streaming)
- Lambda: File-count batching (100 files per manifest)
- Concurrency: 30 parallel jobs in production
- Workers: 20 × G.2X per job

**Deployment Order:**
1. Dev environment → Test → Verify
2. Prod Phase 1 (10 files) → Test → Verify
3. Prod Phase 2-4 (progressive scale) → Test → Verify
4. Full production deployment

**Expected Performance:**
- 338K files/day processed in 4-8 hours
- Cost: $2,500-$3,500/day ($75K-$105K/month)
- Success rate: >98%

Good luck with the deployment! 🚀
