# COMPREHENSIVE CODE & ARCHITECTURE REVIEW

## High-Throughput NDJSON to Parquet ETL Pipeline

**AWS Private Cloud Environment (Dedicated/Non-Shared)**

---

| | |
|---|---|
| **Components Reviewed** | Lambda Function (1,042 lines) \| Glue Job (389 lines) \| Terraform Modules (IAM, Lambda, Glue) |
| **Review Date** | February 2, 2026 |
| **Prepared by** | Claude (Anthropic) |
| **Document Version** | 4.0 |

---

## Production Parameters

| Parameter | Value |
|-----------|-------|
| File size | **3.5 MB** |
| Daily ingestion | **8,000 files/day** |
| Hourly ingestion (average) | ~333 files/hour |
| Peak hourly ingestion (estimated) | ~1,000 files/hour |
| Files per second | ~0.09 files/sec (avg), ~0.28/sec (peak) |
| Daily data volume | **28 GB/day** |
| Monthly data volume | **~840 GB/month** |
| Annual data volume | **~10 TB/year** |
| Batch size (planned) | **200 files/manifest** |
| AWS Environment | **Dedicated (Non-Shared)** |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Question 1: Is the System Optimized?](#2-question-1-is-the-system-optimized)
3. [Question 2: System Limits and Breaking Points](#3-question-2-system-limits-and-breaking-points)
4. [Question 3: Optimal Files per Manifest](#4-question-3-optimal-files-per-manifest)
5. [Lambda Function Review](#5-lambda-function-review)
6. [Glue Job Review](#6-glue-job-review)
7. [Terraform Infrastructure Review](#7-terraform-infrastructure-review)
8. [Scalability Analysis](#8-scalability-analysis)
9. [Cost Analysis](#9-cost-analysis)
10. [Prioritized Action Plan](#10-prioritized-action-plan)
11. [Summary of All Findings](#11-summary-of-all-findings)
12. [Conclusion](#12-conclusion)

---

# 1. Executive Summary

## 1.1 Overall Assessment

This comprehensive review analyzes a production AWS ETL pipeline designed to process NDJSON files (3.5 MB each) to Parquet format at a rate of 8,000 files per day. The system uses Lambda for manifest building, Step Functions for orchestration, Glue for batch processing, and DynamoDB for state tracking.

**Key Finding:** At 8,000 files/day with 200-file batches, the system is **significantly over-provisioned** and will operate at less than 1% capacity. This is excellent for reliability but presents cost optimization opportunities.

| Category | Rating | Assessment |
|----------|--------|------------|
| Performance | ★★★★★ (5/5) | Massively over-provisioned for current load |
| Cost Efficiency | ★★★★☆ (4/5) | Good with 200-file batches; optimization possible |
| Reliability | ★★★☆☆ (3/5) | Race conditions and idempotency gaps need fixing |
| Security | ★★★★☆ (4/5) | IAM acceptable (dedicated env); VPC needed |
| Scalability | ★★★★★ (5/5) | Can handle 100x+ growth without changes |
| **OVERALL** | **★★★★☆ (4.0/5)** | **Well-designed; reliability fixes needed** |

## 1.2 Quick Answers to Your Questions

| Question | Answer |
|----------|--------|
| **Q1: Is it optimized?** | ✅ **Yes for performance.** System operates at <1% capacity. Reliability fixes needed. |
| **Q2: Breaking point?** | **4.8M files/day** (600x current load) with default Glue limits |
| **Q3: Optimal batch size?** | **50-100 files** is optimal for 8K/day; 200 works but creates fewer, larger jobs |
| **Q4: Full review?** | See sections 5-7 below |

## 1.3 Top 5 Findings

| # | Finding | Severity | Impact |
|---|---------|----------|--------|
| 1 | Distributed lock race condition | 🔴 Critical | Data duplication risk |
| 2 | Missing VPC configuration | 🔴 Critical | Compliance failure |
| 3 | Missing idempotency in track_file | 🟠 High | Duplicate records on retry |
| 4 | Orphaned MANIFEST records possible | 🟠 High | Data loss if SF fails |
| 5 | Batch size could be optimized | 🟢 Low | 50-100 more optimal than 200 |

---

# 2. Question 1: Is the System Optimized?

## ✅ Yes - Performance is Excellent

At 8,000 files/day with 200-file batches, the system is **heavily under-utilized**:

### Load Analysis

| Component | Capacity | Current Load | Utilization |
|-----------|----------|--------------|-------------|
| SQS | 3,000 msgs/sec | 0.09 msgs/sec | **0.003%** |
| Lambda Concurrency | 1,000 | ~1-2 | **0.2%** |
| DynamoDB Writes | 40,000 WCU | ~0.1 WCU/sec | **0.0003%** |
| DynamoDB Reads | 40,000 RCU | ~0.01 RCU/sec | **0.00003%** |
| Glue Concurrent Jobs | 50 | ~1-2 | **2-4%** |
| Step Functions | 2,000/sec | 0.0005/sec | **0.00003%** |

### Daily Processing Profile

```
Daily files: 8,000
Batch size: 200 files
Manifests created: 8,000 ÷ 200 = 40 manifests/day
Glue jobs: 40 jobs/day = 1.67 jobs/hour

Data per job: 200 files × 3.5 MB = 700 MB
Total daily data: 28 GB

Job duration (estimated): 3-5 minutes for 700 MB
```

### Performance Verdict

| Aspect | Status | Notes |
|--------|--------|-------|
| Throughput | ✅ Excellent | 0.003% of SQS capacity used |
| Latency | ✅ Excellent | Jobs complete in 3-5 min |
| Concurrency | ✅ Excellent | Never more than 1-2 concurrent jobs |
| Memory | ✅ Excellent | 700 MB batches easily fit |
| Cost | ✅ Good | ~$500-800/month estimated |

## ⚠️ Reliability Issues Remain

While performance is excellent, these **reliability issues need fixing**:

| Issue | Risk | Priority |
|-------|------|----------|
| Distributed lock race condition | Data duplication | 🔴 Critical |
| Missing idempotency | Duplicate records | 🟠 High |
| Orphaned MANIFEST records | Data loss | 🟠 High |
| Missing VPC | Compliance failure | 🔴 Critical |

---

# 3. Question 2: System Limits and Breaking Points

## Primary Bottleneck: Glue Job Concurrency

With 200-file batches, Glue concurrency is the limiting factor:

### Scaling Limits

| Ingestion Rate | Glue Jobs/Day | Jobs/Hour | Concurrent Needed | Status |
|----------------|---------------|-----------|-------------------|--------|
| **8,000/day (current)** | 40 | 1.7 | ~1 | ✅ OK |
| 40,000/day (5x) | 200 | 8.3 | ~1 | ✅ OK |
| 200,000/day (25x) | 1,000 | 42 | ~4 | ✅ OK |
| 500,000/day (62x) | 2,500 | 104 | ~9 | ✅ OK |
| 1,000,000/day (125x) | 5,000 | 208 | ~17 | ✅ OK |
| 2,400,000/day (300x) | 12,000 | 500 | ~42 | ⚠️ Near limit |
| **4,800,000/day (600x)** | **24,000** | **1,000** | **~50** | **🔴 AT LIMIT** |

### Breaking Point Summary

| Configuration | Breaking Point | Growth Headroom |
|---------------|----------------|-----------------|
| **Current (200 files, default Glue 50)** | **4.8M files/day** | **600x** |
| With Glue limit 100 | 9.6M files/day | 1,200x |
| With Glue limit 200 | 19.2M files/day | 2,400x |
| With 500-file batches + Glue 200 | 48M files/day | 6,000x |

### Component-by-Component Limits

| Component | Theoretical Limit | Breaking Point (files/day) | Bottleneck? |
|-----------|-------------------|---------------------------|-------------|
| **Glue Concurrency** | 50 (default) | **4.8M** | **🔴 PRIMARY** |
| Lambda Concurrency | 1,000 | ~100M | No |
| DynamoDB Writes | 40,000 WCU | ~500M | No |
| DynamoDB GSI | 3,000/sec/partition | ~50M | No |
| SQS | 3,000/sec | ~260M | No |
| S3 PUT | 5,500/sec/prefix | ~475M | No |
| Step Functions | 2,000/sec | ~170M | No |

### When to Take Action

| Growth Level | Files/Day | Action Required |
|--------------|-----------|-----------------|
| 1x - 50x | 8K - 400K | ✅ No changes needed |
| 50x - 100x | 400K - 800K | Monitor Glue utilization |
| 100x - 300x | 800K - 2.4M | Consider Glue limit increase |
| 300x - 600x | 2.4M - 4.8M | Request Glue limit to 100 |
| 600x+ | 4.8M+ | Increase batch size + Glue limit |

---

# 4. Question 3: Optimal Files per Manifest

## Analysis: What's the Right Batch Size?

### Trade-offs

| Factor | Smaller Batches (50) | Medium Batches (200) | Larger Batches (500) |
|--------|---------------------|---------------------|---------------------|
| Latency | ✅ Lower (faster processing) | ⚠️ Medium | ❌ Higher (wait for files) |
| Cost | ❌ More Glue jobs | ✅ Balanced | ✅ Fewer Glue jobs |
| Blast radius | ✅ Smaller (less data at risk) | ⚠️ Medium | ❌ Larger (more data if fails) |
| Glue efficiency | ❌ More overhead | ✅ Good | ✅ Best |
| Recovery time | ✅ Fast (retry small batch) | ⚠️ Medium | ❌ Slow (retry large batch) |

### Calculations for 8,000 Files/Day

| Batch Size | Manifests/Day | Data/Batch | Wait Time for Batch | Monthly Cost |
|------------|---------------|------------|---------------------|--------------|
| 10 | 800 | 35 MB | ~2 min | ~$8,000 |
| 50 | 160 | 175 MB | ~9 min | ~$1,600 |
| **100** | **80** | **350 MB** | **~18 min** | **~$800** |
| **200** | **40** | **700 MB** | **~36 min** | **~$500** |
| 500 | 16 | 1.75 GB | ~90 min | ~$300 |

### Recommendation: 50-100 Files is Optimal

For **8,000 files/day**, the optimal batch size is **50-100 files**:

| Criteria | 50 files | 100 files | 200 files (planned) |
|----------|----------|-----------|---------------------|
| Latency | ✅ 9 min | ✅ 18 min | ⚠️ 36 min |
| Cost | $1,600/mo | **$800/mo** | $500/mo |
| Blast radius | ✅ 175 MB | ✅ 350 MB | ⚠️ 700 MB |
| Jobs/day | 160 | 80 | 40 |
| **Verdict** | Good | **Best Balance** | Acceptable |

### Why 200 Files is Still Acceptable

Your planned **200 files/batch is acceptable** because:

1. ✅ Cost is reasonable (~$500/month)
2. ✅ 36-minute wait is tolerable (not real-time requirement)
3. ✅ 700 MB blast radius is manageable with retry logic
4. ✅ Provides more headroom for growth

**Recommendation:** Keep 200 files/batch if latency requirements are >30 minutes. Switch to 100 if you need faster processing.

---

# 5. Lambda Function Review

**File:** `lambda_manifest_builder.py` (1,042 lines)

## 5.1 Security Findings

### Finding LAMBDA-SEC-001: Module-Level Boto3 Clients

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 36-39 |
| **Assessment** | ✅ CORRECT - Boto3 clients are thread-safe. Module-level is best practice for Lambda warm starts. |

### Finding LAMBDA-SEC-002: Sensitive Data in Logs

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 275: `logger.debug(f"Event received: {json.dumps(event)}")` |
| **Impact** | Full S3 event logged; may contain sensitive bucket names/keys. |
| **Fix** | Remove event dump or redact sensitive fields. Use INFO level in production. |

```python
# Fix: Use environment-controlled log level
import os
logger.setLevel(getattr(logging, os.environ.get('LOG_LEVEL', 'INFO')))

# Fix: Redact sensitive data
logger.debug(f"Event received: {len(event.get('Records', []))} records")
```

### Finding LAMBDA-SEC-003: DynamoDB Expression Safety

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 812-819 |
| **Assessment** | ✅ SAFE - Properly uses ExpressionAttributeNames and ExpressionAttributeValues. No injection risk. |

## 5.2 Reliability Findings

### Finding LAMBDA-REL-001: Distributed Lock Race Condition

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | Lines 81-145 (DistributedLock), Line 674 (release in finally) |
| **Impact** | Lock released before Step Functions completes. Race window allows duplicate manifests. |

**Root Cause:**

```
Timeline:
1. Lambda A acquires lock
2. Lambda A creates manifest for files [1-200]
3. Lambda A starts Step Functions
4. Lambda A releases lock (finally block) ← TOO EARLY
5. Lambda B acquires lock
6. Lambda B sees files [1-200] still in 'pending' (DynamoDB eventual consistency)
7. Lambda B creates DUPLICATE manifest for same files
```

**Fix:** Use conditional DynamoDB updates instead of distributed lock:

```python
# Instead of lock, use conditional update on file status
for file in files:
    try:
        table.update_item(
            Key={'date_prefix': file['date_prefix'], 'file_key': file['file_key']},
            UpdateExpression='SET #status = :new_status, manifest_id = :mid',
            ConditionExpression='#status = :expected',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':new_status': 'manifested',
                ':expected': 'pending',
                ':mid': manifest_id
            }
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            # File already claimed by another Lambda - skip
            continue
        raise
```

### Finding LAMBDA-REL-002: Missing Idempotency

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 566: `table.put_item(Item=item)` |
| **Impact** | SQS retries can create duplicate file records. |

**Fix:**

```python
table.put_item(
    Item=item,
    ConditionExpression='attribute_not_exists(file_key)'
)
```

### Finding LAMBDA-REL-003: Orphaned MANIFEST Records

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Lines 1017 (put_item), 1023 (start_execution) |
| **Impact** | If Step Functions fails to start after MANIFEST created, files are stuck in 'manifested' status. |

**Fix:** Reorder operations - start Step Functions first:

```python
try:
    # Start Step Functions FIRST
    execution_arn = sfn_client.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        input=json.dumps(manifest_input)
    )
    
    # Only create MANIFEST record if SF started successfully
    manifest_record['execution_arn'] = execution_arn
    table.put_item(Item=manifest_record)
    
except Exception as e:
    # Rollback: Reset file statuses to 'pending'
    _update_file_status(batch_files, 'pending', None)
    raise
```

## 5.3 Performance Findings

### Finding LAMBDA-PERF-001: Memory Management

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (at 8K files/day) |
| **Location** | Lines 800-857: `_get_pending_files()` |
| **Assessment** | At 8K files/day, max pending ~333 files. Memory usage: ~333 KB. No issue. |

**Still Recommended:** Add Limit parameter for safety at scale:

```python
query_params = {
    'KeyConditionExpression': 'date_prefix = :prefix',
    'FilterExpression': '#status = :status',
    'Limit': MAX_FILES_PER_MANIFEST + 1,  # Only fetch what we need
    ...
}
```

### Finding LAMBDA-PERF-002: Suboptimal Retry Logic

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 420-450: Fixed delays (100ms, 500ms) |
| **Fix** | Use exponential backoff with jitter. |

```python
import random

def exponential_backoff(attempt, base=0.1, max_delay=5.0):
    delay = min(base * (2 ** attempt) + random.uniform(0, 0.1), max_delay)
    time.sleep(delay)
```

### Finding LAMBDA-PERF-003: Sequential DynamoDB Updates

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 949-986: Sequential update_item calls |
| **Impact** | With 200-file batches: 200 × 50ms = 10 seconds. Acceptable but improvable. |

**Fix:** Use BatchWriteItem:

```python
def _update_file_status_batch(files, status, manifest_path):
    with table.batch_writer() as batch:
        for f in files:
            batch.put_item(Item={
                'date_prefix': f['date_prefix'],
                'file_key': f['filename'],
                'status': status,
                'manifest_path': manifest_path,
                'ttl': calculate_ttl()
            })
```

## 5.4 Code Quality Findings

### Finding LAMBDA-CQ-001: TTL Calculation Duplication

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 551, 956, 1006 |
| **Fix** | Extract to helper: `def calculate_ttl(): return int(time.time()) + (TTL_DAYS * 86400)` |

### Finding LAMBDA-CQ-002: Hardcoded Log Level

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Line 33: `logger.setLevel(logging.DEBUG)` |
| **Fix** | Use environment variable for per-environment control. |

---

# 6. Glue Job Review

**File:** `glue_batch_job.py` (389 lines)

## 6.1 Performance Findings

### Finding GLUE-PERF-001: Hardcoded Shuffle Partitions

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Line 87: `spark.conf.set("spark.sql.shuffle.partitions", "100")` |
| **Assessment** | For 700 MB batches, 100 partitions is actually too high. 10-20 would be more efficient. |

**Fix:**

```python
# Calculate based on data volume
estimated_size_mb = file_count * 3.5  # 3.5 MB per file
partitions = max(4, min(int(estimated_size_mb / 50), 100))  # ~50 MB per partition
spark.conf.set('spark.sql.shuffle.partitions', str(partitions))
```

### Finding GLUE-PERF-002: DataFrame Caching Strategy

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Line 183: `df.cache()` |
| **Assessment** | ✅ Appropriate for 700 MB batches. Cache before count() and write() prevents recomputation. |

### Finding GLUE-PERF-003: Worker Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Terraform Glue configuration |
| **Assessment** | For 700 MB batches, 2 G.1X workers may be over-provisioned. Consider G.0.25X or reducing to 1 worker for cost savings. |

## 6.2 Reliability Findings

### Finding GLUE-REL-001: Generic Exception Handling

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 109, 142, 157, 207: `except Exception as e` |
| **Impact** | Generic exceptions hide specific errors. |
| **Fix** | Catch specific Spark exceptions (Py4JJavaError, AnalysisException). |

## 6.3 Code Quality Findings

### Finding GLUE-CQ-001: Unused CloudWatch Client

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Line 41: `cloudwatch = boto3.client('cloudwatch')` |
| **Fix** | Remove or implement custom metrics. |

---

# 7. Terraform Infrastructure Review

## 7.1 Lambda Module (`modules/lambda/main.tf` - 157 lines)

### Finding TF-LAMBDA-001: Missing VPC Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | aws_lambda_function resource (lines 29-76) |
| **Impact** | Lambda runs outside VPC. Required for private cloud compliance. |

**Fix:**

```hcl
resource "aws_lambda_function" "manifest_builder" {
  # ... existing config ...
  
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }
}
```

### Finding TF-LAMBDA-002: Missing Dead Letter Queue

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | aws_lambda_function resource |
| **Impact** | Failed invocations lost with no recovery mechanism. |

**Fix:**

```hcl
dead_letter_config {
  target_arn = var.lambda_dlq_arn
}
```

### Finding TF-LAMBDA-003: Missing X-Ray Tracing

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | aws_lambda_function resource |
| **Fix** | Add `tracing_config { mode = "Active" }` |

### Finding TF-LAMBDA-004: Missing LOG_LEVEL Environment Variable

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | environment.variables block |
| **Fix** | Add `LOG_LEVEL = var.environment == "prod" ? "INFO" : "DEBUG"` |

### Finding TF-LAMBDA-005: Missing KMS Encryption

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | aws_lambda_function resource |
| **Fix** | Add `kms_key_arn = var.lambda_env_kms_key_arn` |

### Finding TF-LAMBDA-006: No Alarm Actions

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | CloudWatch alarms (lines 102-157) |
| **Fix** | Add `alarm_actions = var.alarm_sns_topic_arns` |

## 7.2 IAM Module (`modules/iam/main.tf` - 485 lines)

> **Note:** Since AWS environment is **dedicated (non-shared)**, all IAM wildcard findings are 🟢 Low severity.

### Finding TF-IAM-001: Lambda Step Functions Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (Dedicated Environment) |
| **Location** | Line 136: `Resource = "*"` for states:StartExecution |
| **Assessment** | Acceptable in dedicated environment. Optional fix for future-proofing. |

### Finding TF-IAM-002: State Management Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (Dedicated Environment) |
| **Location** | Line 232: `Resource = "*"` for glue:GetJob* |
| **Assessment** | Acceptable in dedicated environment. |

### Finding TF-IAM-003: Step Functions Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (Dedicated Environment) |
| **Location** | Line 396: `Resource = "*"` for glue:StartJobRun |
| **Assessment** | Acceptable in dedicated environment. |

### Finding TF-IAM-004: EventBridge Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (Dedicated Environment) |
| **Location** | Line 480: `Resource = "*"` for glue:StartJobRun |
| **Assessment** | Acceptable in dedicated environment. |

### Finding TF-IAM-005: Missing Permission Boundaries

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low (Dedicated Environment) |
| **Location** | All IAM roles |
| **Assessment** | Optional for dedicated environment. |

## 7.3 Glue Module (`modules/glue/main.tf` - 183 lines)

### Finding TF-GLUE-001: Missing Security Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | aws_glue_job resource |
| **Impact** | No encryption for CloudWatch logs, job bookmarks, or S3 data. |

**Fix:**

```hcl
resource "aws_glue_security_configuration" "etl_security" {
  name = "ndjson-parquet-security-${var.environment}"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn               = var.kms_key_arn
    }
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}
```

### Finding TF-GLUE-002: Missing VPC Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | aws_glue_job resource |
| **Impact** | Glue jobs must run in VPC for private cloud compliance. |

**Fix:**

```hcl
resource "aws_glue_connection" "vpc_connection" {
  name            = "glue-vpc-${var.environment}"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    security_group_id_list = [var.glue_security_group_id]
    subnet_id              = var.private_subnet_id
  }
}

resource "aws_glue_job" "batch_processor" {
  # ... existing config ...
  connections = [aws_glue_connection.vpc_connection.name]
}
```

### Finding TF-GLUE-003: Missing COMPRESSION_TYPE

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | default_arguments block |
| **Fix** | Add `"--COMPRESSION_TYPE" = var.compression_type` |

### Finding TF-GLUE-004: Alarms Only in Production

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 145-183 |
| **Fix** | Enable alarms in all environments with different thresholds. |

### Finding TF-GLUE-005: Missing Job Run State Alarm

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Fix** | Add alarm for job failures. |

### Finding TF-GLUE-006: Consider Glue Flex

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Opportunity** | Glue Flex offers ~34% cost savings. At 40 jobs/day, saves ~$150/month. |

---

# 8. Scalability Analysis

## 8.1 Current Load Profile

| Metric | Value | Assessment |
|--------|-------|------------|
| Files/day | 8,000 | Light load |
| Files/hour (avg) | 333 | Very manageable |
| Files/second | 0.09 | Minimal |
| Data/day | 28 GB | Small |
| Glue jobs/day | 40 | Low |
| Concurrent jobs | 1-2 | Minimal |

## 8.2 System Capacity vs Current Load

| Component | Current Load | Max Capacity | Utilization | Headroom |
|-----------|--------------|--------------|-------------|----------|
| SQS | 0.09/sec | 3,000/sec | 0.003% | **33,000x** |
| Lambda | ~2 concurrent | 1,000 | 0.2% | **500x** |
| DynamoDB | ~0.1 WCU | 40,000 WCU | 0.0003% | **400,000x** |
| Glue | 40 jobs/day | 28,800 jobs/day | 0.14% | **720x** |
| Step Functions | 40/day | ~170M/day | 0.00002% | **4.3M x** |

## 8.3 Growth Scenarios

| Scenario | Files/Day | Glue Jobs/Day | Monthly Cost | Changes Needed |
|----------|-----------|---------------|--------------|----------------|
| **Current** | 8,000 | 40 | ~$500 | None |
| 5x growth | 40,000 | 200 | ~$1,200 | None |
| 25x growth | 200,000 | 1,000 | ~$4,500 | None |
| 100x growth | 800,000 | 4,000 | ~$15,000 | None |
| 300x growth | 2,400,000 | 12,000 | ~$45,000 | Monitor Glue |
| **600x growth** | **4,800,000** | **24,000** | **~$90,000** | **At limit** |

---

# 9. Cost Analysis

## 9.1 Monthly Cost Breakdown (8,000 files/day)

| Component | Calculation | Monthly Cost |
|-----------|-------------|--------------|
| Lambda | 40 invocations/day × 10s × $0.0000166667/GB-s | ~$5 |
| Glue (G.1X, 2 workers) | 40 jobs/day × 5 min × $0.44/DPU-hr | ~$220 |
| DynamoDB (On-Demand) | ~8,000 writes/day + reads | ~$10 |
| S3 Storage | 840 GB/month × $0.023/GB | ~$20 |
| S3 Requests | ~8,000 PUT + GET/day | ~$5 |
| Step Functions | 40 transitions/day | ~$1 |
| CloudWatch Logs | ~1 GB/month | ~$5 |
| **TOTAL** | | **~$270/month** |

## 9.2 Cost Optimization Opportunities

| Optimization | Current | Optimized | Monthly Savings |
|--------------|---------|-----------|-----------------|
| Glue Flex | Standard | Flex | ~$75 (34%) |
| Reduce to G.0.25X | G.1X (2 workers) | G.0.25X (2 workers) | ~$165 (75%) |
| S3 Intelligent-Tiering | Standard | IT | ~$8 (40% on storage) |
| **Total Potential Savings** | ~$270/mo | **~$50/mo** | **~$220/mo (81%)** |

## 9.3 Cost at Different Batch Sizes

| Batch Size | Glue Jobs/Day | Glue Cost/Month | Total Cost/Month |
|------------|---------------|-----------------|------------------|
| 50 files | 160 | ~$880 | ~$930 |
| 100 files | 80 | ~$440 | ~$490 |
| **200 files** | **40** | **~$220** | **~$270** |
| 500 files | 16 | ~$88 | ~$140 |

---

# 10. Prioritized Action Plan

## 10.1 Phase 1: Critical Fixes (Week 1)

| # | Action | Effort | Impact | Priority |
|---|--------|--------|--------|----------|
| 1 | Add ConditionExpression to track_file | 10 min | Idempotency | 🔴 Critical |
| 2 | Reorder SF start before MANIFEST record | 2 hrs | Data integrity | 🔴 Critical |
| 3 | Add LOG_LEVEL environment variable | 15 min | Security | 🟠 High |
| 4 | Remove DEBUG logging in production | 30 min | Security | 🟠 High |
| 5 | Add Dead Letter Queue to Lambda | 1 hr | Error recovery | 🟠 High |
| 6 | Add alarm_actions to CloudWatch alarms | 30 min | Alerting | 🟡 Medium |

**Phase 1 Effort: ~5 hours**

## 10.2 Phase 2: Compliance & Security (Weeks 2-3)

| # | Action | Effort | Impact | Priority |
|---|--------|--------|--------|----------|
| 1 | Add VPC configuration to Lambda | 2 hrs | Compliance | 🔴 Critical |
| 2 | Add VPC configuration to Glue | 4 hrs | Compliance | 🔴 Critical |
| 3 | Add Glue security configuration | 2 hrs | Encryption | 🟠 High |
| 4 | Add KMS encryption to Lambda env vars | 1 hr | Security | 🟡 Medium |
| 5 | Add X-Ray tracing | 2 hrs | Debugging | 🟡 Medium |
| 6 | Implement BatchWriteItem | 4 hrs | Performance | 🟡 Medium |

**Phase 2 Effort: ~15 hours (2 days)**

## 10.3 Phase 3: Optimization (Month 2)

| # | Action | Effort | Impact | Priority |
|---|--------|--------|--------|----------|
| 1 | Fix distributed lock race condition | 1 day | Reliability | 🔴 Critical |
| 2 | Enable Glue Flex | 2 hrs | Cost (-34%) | 🟢 Low |
| 3 | Reduce Glue to G.0.25X | 1 hr | Cost (-75%) | 🟢 Low |
| 4 | Add S3 Intelligent-Tiering | 15 min | Cost (-40% storage) | 🟢 Low |
| 5 | Dynamic Spark partitions | 2 hrs | Performance | 🟢 Low |
| 6 | Implement exponential backoff | 2 hrs | Reliability | 🟢 Low |

**Phase 3 Effort: ~2 days**

---

# 11. Summary of All Findings

## 11.1 All Findings by Severity

| ID | Finding | Severity | Phase |
|----|---------|----------|-------|
| **Critical (3)** | | | |
| LAMBDA-REL-001 | Distributed lock race condition | 🔴 Critical | Phase 3 |
| TF-LAMBDA-001 | Missing VPC configuration | 🔴 Critical | Phase 2 |
| TF-GLUE-002 | Missing VPC configuration | 🔴 Critical | Phase 2 |
| **High (5)** | | | |
| LAMBDA-SEC-002 | Sensitive data in logs | 🟠 High | Phase 1 |
| LAMBDA-REL-002 | Missing idempotency | 🟠 High | Phase 1 |
| LAMBDA-REL-003 | Orphaned MANIFEST records | 🟠 High | Phase 1 |
| TF-LAMBDA-002 | Missing Dead Letter Queue | 🟠 High | Phase 1 |
| TF-GLUE-001 | Missing security configuration | 🟠 High | Phase 2 |
| **Medium (8)** | | | |
| LAMBDA-PERF-002 | Suboptimal retry logic | 🟡 Medium | Phase 3 |
| LAMBDA-PERF-003 | Sequential DynamoDB updates | 🟡 Medium | Phase 2 |
| LAMBDA-CQ-002 | Hardcoded log level | 🟡 Medium | Phase 1 |
| GLUE-REL-001 | Generic exception handling | 🟡 Medium | Phase 3 |
| TF-LAMBDA-003 | Missing X-Ray tracing | 🟡 Medium | Phase 2 |
| TF-LAMBDA-004 | Missing LOG_LEVEL env var | 🟡 Medium | Phase 1 |
| TF-LAMBDA-005 | Missing KMS encryption | 🟡 Medium | Phase 2 |
| TF-LAMBDA-006 | No alarm actions | 🟡 Medium | Phase 1 |
| TF-GLUE-004 | Alarms only in production | 🟡 Medium | Phase 2 |
| TF-GLUE-005 | Missing job run state alarm | 🟡 Medium | Phase 2 |
| **Low (12)** | | | |
| LAMBDA-SEC-001 | Module-level boto3 (OK) | 🟢 Low | N/A |
| LAMBDA-SEC-003 | DynamoDB safety (OK) | 🟢 Low | N/A |
| LAMBDA-PERF-001 | Memory management (OK at scale) | 🟢 Low | Phase 3 |
| LAMBDA-CQ-001 | TTL duplication | 🟢 Low | Phase 3 |
| GLUE-PERF-001 | Hardcoded shuffle partitions | 🟢 Low | Phase 3 |
| GLUE-PERF-002 | DataFrame caching (OK) | 🟢 Low | N/A |
| GLUE-CQ-001 | Unused CloudWatch client | 🟢 Low | Phase 3 |
| TF-IAM-001 | Lambda SF wildcard (dedicated) | 🟢 Low | Optional |
| TF-IAM-002 | State Mgmt Glue wildcard (dedicated) | 🟢 Low | Optional |
| TF-IAM-003 | SF Glue wildcard (dedicated) | 🟢 Low | Optional |
| TF-IAM-004 | EventBridge wildcard (dedicated) | 🟢 Low | Optional |
| TF-IAM-005 | Permission boundaries (dedicated) | 🟢 Low | Optional |
| TF-GLUE-003 | Missing COMPRESSION_TYPE | 🟢 Low | Phase 1 |
| TF-GLUE-006 | Consider Glue Flex | 🟢 Low | Phase 3 |

## 11.2 Finding Distribution

**Total Findings: 28**

| Severity | Count | Percentage |
|----------|-------|------------|
| 🔴 Critical | 3 | 11% |
| 🟠 High | 5 | 18% |
| 🟡 Medium | 8 | 29% |
| 🟢 Low | 12 | 43% |

---

# 12. Conclusion

## 12.1 Answers to Your Questions

### Q1: Is the system optimized?

**✅ Yes for performance and cost.** At 8,000 files/day with 200-file batches:
- System operates at <1% capacity
- Estimated cost: ~$270/month
- No performance bottlenecks

**⚠️ Reliability fixes needed:**
- Distributed lock race condition (Critical)
- Missing idempotency (High)
- Orphaned MANIFEST handling (High)

**⚠️ Compliance fixes needed:**
- VPC configuration for Lambda and Glue (Critical)

### Q2: What is the breaking point?

| Configuration | Breaking Point | Headroom |
|---------------|----------------|----------|
| Current (200 files, default Glue) | **4.8M files/day** | **600x** |
| With Glue limit 100 | 9.6M files/day | 1,200x |
| With Glue limit 200 | 19.2M files/day | 2,400x |

**Primary bottleneck:** Glue job concurrency (default 50)

### Q3: Optimal batch size?

| Batch Size | Verdict | When to Use |
|------------|---------|-------------|
| 50-100 | **Best balance** | If latency <20 min needed |
| **200 (planned)** | **Good choice** | General use, cost-efficient |
| 500 | Maximum efficiency | If latency >90 min acceptable |

**Recommendation:** Your planned 200-file batches are a good choice. Consider 100 if you need faster processing.

## 12.2 Summary

The ETL pipeline is **well-designed and performs excellently** at the current load of 8,000 files/day. The architecture can handle **600x growth** (4.8M files/day) without any changes.

**Priority actions:**
1. 🔴 Fix VPC configuration (compliance)
2. 🔴 Add idempotency to track_file
3. 🔴 Fix orphaned MANIFEST handling
4. 🟡 Fix distributed lock (can defer but important)

**Estimated effort:**
- Phase 1 (Critical reliability): ~5 hours
- Phase 2 (Compliance): ~2 days
- Phase 3 (Optimization): ~2 days

---

**Document Version History:**

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 1, 2026 | Initial review (1K files assumed) |
| 2.0 | Feb 1, 2026 | Added Terraform findings |
| 3.0 | Feb 1, 2026 | Revised for 3.5 MB files, 7K files/hr |
| 4.0 | Feb 2, 2026 | Updated for 8K files/day, 200-file batches, dedicated environment |

---

*— End of Review Document —*
