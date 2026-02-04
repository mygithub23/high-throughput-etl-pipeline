# Configuration Reference - Batch Mode Settings

## Overview

This document provides the complete configuration reference for both **dev** and **prod** environments running in **BATCH MODE** (glueetl).

**IMPORTANT:** All configurations have been updated to use Glue batch processing, NOT streaming.

---

## Environment Comparison

| Setting | Dev Environment | Prod Environment |
|---------|----------------|------------------|
| **Purpose** | Testing, debugging | Production scale (338K files/day) |
| **Logging Level** | DEBUG | INFO |
| **Test File Size** | 10-20 KB | 3.5-4 GB |
| **Test File Count** | 10-100 files | 5-10,000 files |
| **Glue Mode** | glueetl (batch) | glueetl (batch) |
| **Concurrent Jobs** | 5 | 30 |
| **Workers per Job** | 10 | 20 |

---

## Lambda Configuration

### Environment Variables (Both Environments)

```bash
# DynamoDB Tables
TRACKING_TABLE=ndjson-parquet-sqs-file-tracking
METRICS_TABLE=ndjson-parquet-sqs-metrics
LOCK_TABLE=ndjson-parquet-sqs-file-tracking

# S3 Buckets
MANIFEST_BUCKET=ndjson-manifests-${AWS_ACCOUNT_ID}
QUARANTINE_BUCKET=ndjson-quarantine-${AWS_ACCOUNT_ID}

# Glue Job
GLUE_JOB_NAME=ndjson-parquet-sqs-streaming-processor  # Name kept for compatibility
```

### Batch Processing Settings

**Development:**
```bash
MAX_FILES_PER_MANIFEST=50          # Smaller batches for testing
MAX_BATCH_SIZE_GB=200              # 50 files × 4GB max
EXPECTED_FILE_SIZE_MB=10           # Dev uses KB files
SIZE_TOLERANCE_PERCENT=50          # More lenient for testing
```

**Production:**
```bash
MAX_FILES_PER_MANIFEST=100         # 100 files per manifest
MAX_BATCH_SIZE_GB=500              # 100 files × 4.5GB = 450GB max
EXPECTED_FILE_SIZE_MB=3500         # 3.5 GB expected
SIZE_TOLERANCE_PERCENT=20          # 3.5-4.5 GB range (±20%)
```

### Lambda Function Settings

**Development:**
```bash
Memory: 512 MB                     # Sufficient for dev testing
Timeout: 300 seconds               # 5 minutes
Reserved Concurrency: 5            # Limit concurrent executions
```

**Production:**
```bash
Memory: 1024 MB                    # Handle larger batches
Timeout: 300 seconds               # 5 minutes
Reserved Concurrency: 10           # Allow more parallel processing
```

### Locking Configuration (Both)

```bash
LOCK_TTL_SECONDS=300               # 5-minute lock timeout
MAX_LOCK_WAIT_SECONDS=10           # Don't wait too long for lock
```

---

## Glue Job Configuration

### Command Type (CRITICAL)

**Both environments use BATCH mode:**
```json
{
  "Command": {
    "Name": "glueetl",              // BATCH mode - NOT gluestreaming
    "ScriptLocation": "s3://aws-glue-scripts-${ACCOUNT}/glue_batch_job.py"
  }
}
```

### Development Settings

```json
{
  "GlueVersion": "4.0",
  "WorkerType": "G.1X",              // 8 GB RAM per worker
  "NumberOfWorkers": 10,             // Moderate parallelism
  "MaxConcurrentRuns": 5,            // Limit concurrent jobs
  "Timeout": 60,                     // 1 hour max per job
  "MaxRetries": 1,                   // Retry failed jobs once
  "DefaultArguments": {
    "--enable-metrics": "true",
    "--enable-spark-ui": "true",
    "--enable-job-insights": "true",
    "--enable-auto-scaling": "false" // Fixed workers for predictability
  }
}
```

### Production Settings

```json
{
  "GlueVersion": "4.0",
  "WorkerType": "G.2X",              // 16 GB RAM per worker
  "NumberOfWorkers": 20,             // High parallelism
  "MaxConcurrentRuns": 30,           // 30 jobs in parallel
  "Timeout": 120,                    // 2 hours max per job
  "MaxRetries": 2,                   // Retry failed jobs twice
  "DefaultArguments": {
    "--enable-metrics": "true",
    "--enable-spark-ui": "true",
    "--enable-job-insights": "true",
    "--enable-auto-scaling": "true", // Auto-scale workers based on load
    "--enable-continuous-cloudwatch-log": "true"
  }
}
```

### Spark Configuration (Both)

Embedded in Glue job script:
```python
spark_conf = {
    "spark.sql.files.maxPartitionBytes": "512MB",
    "spark.sql.shuffle.partitions": "200",
    "spark.default.parallelism": "200",
    "spark.serializer": "org.apache.spark.serializer.KryoSerializer",
    "spark.kryoserializer.buffer.max": "512m"
}
```

---

## Processing Capacity

### Development Environment

```
Batch Configuration:
- 50 files per manifest
- 5 concurrent jobs
- 10 workers per job

Parallel Capacity:
- 250 files can be processed simultaneously (5 jobs × 50 files)
- 50 total workers (5 jobs × 10 workers)

Expected Performance:
- Small files (10-20 KB): Minutes to process hundreds of files
- Testing latency: Very fast for debugging
```

### Production Environment

```
Batch Configuration:
- 100 files per manifest
- 30 concurrent jobs
- 20 workers per job

Parallel Capacity:
- 3,000 files can be processed simultaneously (30 jobs × 100 files)
- 600 total workers (30 jobs × 20 workers)

Expected Performance for 338K files/day:
- Manifests created: 3,380 per day (338,000 ÷ 100)
- Processing batches: 113 batches (3,380 ÷ 30)
- Time per batch: ~5 minutes
- Total time: 4-8 hours per day

Throughput:
- Peak: 3,000 files per 5 minutes = 36,000 files/hour
- Daily capacity: 576,000 files (well above 338K target)
```

---

## File Size Validation

### Development (Lenient)

```python
EXPECTED_FILE_SIZE_MB = 10          # Expecting KB files, but set to 10MB
SIZE_TOLERANCE_PERCENT = 50         # Accept 5-15 MB

# Validation is lenient for testing diverse scenarios
```

### Production (Strict)

```python
EXPECTED_FILE_SIZE_MB = 3500        # 3.5 GB
SIZE_TOLERANCE_PERCENT = 20         # Accept 2.8-4.2 GB

# Files outside this range go to quarantine bucket
# Covers 3.5-4.5 GB production files with buffer
```

---

## S3 Bucket Structure

### Input Bucket
```
s3://ndjson-input-sqs-${ACCOUNT}/
├── 2025-12-23-file-001.ndjson
├── 2025-12-23-file-002.ndjson
└── ...
```

### Manifest Bucket
```
s3://ndjson-manifests-${ACCOUNT}/
└── manifests/
    └── 2025-12-23/
        ├── manifest-001.json
        ├── manifest-002.json
        └── ...

Each manifest contains paths to 100 files
```

### Output Bucket
```
s3://ndjson-output-sqs-${ACCOUNT}/
└── parquet/
    └── 2025-12-23/
        ├── part-00000.parquet
        ├── part-00001.parquet
        └── ...
```

### Quarantine Bucket
```
s3://ndjson-quarantine-${ACCOUNT}/
└── 2025-12-23/
    ├── too-large/
    │   └── file-xxx.ndjson
    └── too-small/
        └── file-yyy.ndjson
```

---

## DynamoDB Schema

### File Tracking Table

```
Table: ndjson-parquet-sqs-file-tracking

Partition Key: date_prefix (String)    # Format: YYYY-MM-DD
Sort Key: file_key (String)            # S3 key

Attributes:
- status: String                        # pending, manifested, processing, completed
- file_size_mb: Number                  # File size in MB
- upload_time: String                   # ISO timestamp
- manifest_path: String                 # S3 path to manifest (when manifested)
- batch_id: String                      # Unique batch identifier
- ttl: Number                           # Auto-delete after 7 days

GSI: status-index
- Partition Key: status
- Sort Key: upload_time
- Used for: Finding pending files, monitoring progress
```

### Metrics Table

```
Table: ndjson-parquet-sqs-metrics

Partition Key: metric_date (String)     # Format: YYYY-MM-DD
Sort Key: metric_type (String)          # file_uploaded, manifest_created, etc.

Attributes:
- count: Number
- total_size_mb: Number
- timestamp: String
```

---

## Cost Estimates

### Development Environment

**Monthly costs:**
```
Lambda:
- Invocations: ~1,000/month
- Duration: ~10 seconds avg
- Cost: ~$5/month

Glue:
- Jobs: ~50 runs/month
- Duration: ~5 minutes avg
- Workers: 10 × G.1X
- Cost: 50 runs × 5 min × 10 workers × 1 DPU × $0.44/DPU-hour
       = ~$18/month

S3:
- Storage: ~10 GB
- Requests: ~2,000
- Cost: ~$5/month

DynamoDB:
- Reads: ~5,000/month
- Writes: ~2,000/month
- Storage: <1 GB
- Cost: ~$5/month

Total: ~$33/month
```

### Production Environment (338K files/day)

**Daily processing:**
```
Lambda:
- Invocations: ~350,000/day (file tracking + manifest creation)
- Duration: ~5 seconds avg
- Cost: ~$20/day = $600/month

Glue (Batch Mode):
- Manifests: 3,380/day
- Concurrent jobs: 30
- Batches: 113/day (3,380 ÷ 30)
- Time per batch: 5 minutes
- Total time: ~9.4 hours/day of processing
- Workers: 30 jobs × 20 workers × 2 DPU = 1,200 DPU
- Cost: 9.4 hours × 1,200 DPU × $0.44/DPU-hour
       = $4,953/day = $148,590/month

BUT with sequential batches (only 30 jobs running at a time):
- Active time: 113 batches × 5 min = 565 min = 9.4 hours
- Concurrent DPU: 30 jobs × 20 workers × 2 DPU = 1,200 DPU
- Cost: 9.4 hours × 1,200 DPU × $0.44 = $4,953/day
       = $148,590/month ❌ TOO HIGH!

OPTIMIZATION - Process in 2 shifts:
- Shift 1: 8 hours (daytime processing)
- Shift 2: 4 hours (peak processing)
- Average concurrent: 15 jobs
- Cost: 12 hours × 15 jobs × 20 workers × 2 DPU × $0.44
       = 12 × 600 × 0.44 = $3,168/day = $95,040/month

With auto-scaling (average 12 concurrent jobs):
- Cost: ~$2,500/day = $75,000/month

S3:
- Storage: 525 TB - 1.5 PB/month
- Standard: $0.023/GB = $12,000-$35,000/month
- Requests: ~350K PUT, ~350K GET
- Cost: ~$200/month
- Total S3: $12,200 - $35,200/month

DynamoDB:
- Writes: ~350,000/day
- Reads: ~100,000/day
- Storage: ~10 GB
- On-demand pricing: ~$450/month

SQS:
- Messages: ~350,000/day
- Cost: ~$50/month

Total: $30,000 - $95,000/month (depending on optimization)

RECOMMENDED: Migrate to EMR for $10,000-$15,000/month
```

---

## Deployment Commands

### Deploy Development Environment

```bash
cd environments/dev

# 1. Deploy Lambda
cd lambda
zip -r lambda.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://lambda.zip \
  --region us-east-1

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

# 2. Deploy Glue (or use deploy-glue.sh if created for dev)
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

### Deploy Production Environment

```bash
cd environments/prod/scripts

# Use deployment scripts
./deploy-lambda.sh      # Deploys with production config
./deploy-glue.sh        # Deploys with batch mode, 30 concurrent jobs
```

---

## Monitoring Commands

### Development

```bash
cd environments/dev/scripts

# Check Lambda logs
./check-lambda-logs.sh

# Check DynamoDB
./check-dynamodb-files.sh

# Check SQS queue
./check-sqs-queue.sh

# Full diagnostic
./diagnose-pipeline.sh
```

### Production

```bash
cd environments/prod/scripts

# Real-time monitoring
./monitor-pipeline.sh

# Check for errors
./check-glue-errors.sh

# Run load test
./test-production-scale.sh

# Update configuration
./update-batch-config.sh
```

---

## Key Configuration Differences: Streaming vs Batch

### What Changed from Streaming

| Setting | OLD (Streaming) | NEW (Batch) |
|---------|----------------|-------------|
| Glue Command | gluestreaming | **glueetl** |
| Processing Model | Continuous | **Triggered per manifest** |
| Cost Model | 24/7 running | **Pay per job** |
| Batching | Time-based windows | **File-count based** |
| Latency | Real-time | **Minutes (acceptable)** |
| Max Concurrent | N/A (single stream) | **30 jobs** |

### Why Batch is Better for This Use Case

1. **Large files** (3.5-4.5 GB) - Batch handles large files better
2. **Predictable traffic** - Can batch efficiently
3. **No real-time requirement** - 30-minute latency is fine
4. **Cost control** - Pay only when processing
5. **Better visibility** - Each batch is a discrete job
6. **Easier scaling** - Add more concurrent jobs

---

## Testing Workflow

### Development Testing

```bash
# 1. Generate small test files
cd environments/dev/scripts
./generate-test-data.sh 10 100        # 10 files, 100 records

# 2. Upload to S3
./upload-test-data.sh

# 3. Monitor processing
watch -n 5 './check-lambda-logs.sh'

# 4. Verify output
aws s3 ls s3://ndjson-output-sqs-${ACCOUNT}/parquet/
```

### Production Testing

```bash
# 1. Start with small scale
cd environments/prod/scripts
./test-production-scale.sh            # Select Phase 1: 10 files

# 2. Monitor
./monitor-pipeline.sh

# 3. Check for errors
./check-glue-errors.sh

# 4. Gradually increase (Phase 2: 100 files, Phase 3: 1000 files)
./test-production-scale.sh

# 5. Full production deployment only after Phase 4 success
```

---

## Troubleshooting

### Common Issues

**Issue: Jobs timing out**
```bash
# Increase timeout or reduce files per manifest
./update-batch-config.sh              # Select lighter preset
```

**Issue: Out of memory**
```bash
# Check Glue worker type
# Upgrade from G.1X (8GB) to G.2X (16GB)
aws glue update-job --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update '{"WorkerType": "G.2X"}'
```

**Issue: Too many concurrent jobs**
```bash
# Check Glue account limits
aws service-quotas get-service-quota \
  --service-code glue \
  --quota-code L-5D963659              # Max concurrent runs

# Request increase if needed
```

**Issue: High costs**
```bash
# Monitor costs
./monitor-pipeline.sh                 # Check cost estimates

# Consider migrating to EMR
# See ARCHITECTURE-OPTIONS.md Option 3
```

---

## Summary

**All environments are now configured for BATCH mode (glueetl), NOT streaming.**

**Key Settings:**
- **Lambda:** File-count batching (50 dev, 100 prod)
- **Glue:** Batch processing with concurrent jobs (5 dev, 30 prod)
- **Workers:** G.1X for dev, G.2X for prod
- **Capacity:** Can handle 576K files/day (well above 338K target)

**Next Steps:**
1. Deploy to dev and test
2. Run progressive load tests in prod
3. Monitor costs closely
4. Consider EMR migration for long-term cost savings
