# COMPREHENSIVE CODE & ARCHITECTURE REVIEW

## High-Throughput NDJSON to Parquet ETL Pipeline

**AWS Private Cloud Environment**

---

| | |
|---|---|
| **Components Reviewed** | Lambda Function (1,042 lines) \| Glue Job (389 lines) \| Terraform Modules |
| **Review Date** | February 1, 2026 |
| **Prepared by** | Claude (Anthropic) |
| **Document Version** | 2.0 |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Lambda Function Review](#2-lambda-function-review)
3. [Glue Job Review](#3-glue-job-review)
4. [Terraform Infrastructure Review](#4-terraform-infrastructure-review)
5. [Answers to Specific Questions](#5-answers-to-specific-questions)
6. [Scalability Analysis](#6-scalability-analysis)
7. [Prioritized Action Plan](#7-prioritized-action-plan)
8. [Summary of All Findings](#8-summary-of-all-findings)
9. [Conclusion](#9-conclusion)

---

# 1. Executive Summary

## 1.1 Overall Assessment

This comprehensive review analyzes a production AWS ETL pipeline designed to process NDJSON files to Parquet format. The system uses Lambda for manifest building, Step Functions for orchestration, Glue for batch processing, and DynamoDB for state tracking.

The architecture demonstrates solid foundational design with appropriate separation of concerns. However, several critical issues must be addressed before scaling to the target throughput of 100,000-500,000 files per day.

| Category | Rating | Key Concern |
|----------|--------|-------------|
| Security | ★★★☆☆ (3/5) | IAM wildcards, dev encryption |
| Performance | ★★★☆☆ (3/5) | Memory at scale, GSI bottleneck |
| Reliability | ★★★★☆ (4/5) | Lock race condition |
| Scalability | ★★☆☆☆ (2/5) | Won't reach 500K/day target |
| Code Quality | ★★★★☆ (4/5) | Good structure, verbose logging |
| Infrastructure (Terraform) | ★★★☆☆ (3/5) | Missing VPC, security config |
| **OVERALL** | **★★★☆☆ (3.2/5)** | **Solid foundation, needs hardening** |

## 1.2 Top 5 Critical Issues

1. **Distributed Lock Vulnerability (Lambda:673-674):** Race conditions and potential duplicate processing due to distributed lock being released before Step Functions workflow completes.

2. **Memory Exhaustion Risk (Lambda:800-857):** Loading all pending files into memory will cause OOM failures at target scale of 500K files/day.

3. **No Idempotency Guarantee (Lambda:566):** SQS at-least-once delivery can cause duplicate file records since put_item has no conditional check.

4. **Orphaned MANIFEST Records (Lambda:1017-1041):** If Step Functions start fails after MANIFEST record creation, files are orphaned in 'manifested' status.

5. **Missing Glue Security Configuration (Terraform):** Glue jobs should run in VPC for private cloud compliance; security configuration for encryption is missing.

## 1.3 Top 5 Quick Wins

1. **Add ConditionExpression to track_file:** Single line change prevents duplicate processing on SQS retries. Implementation: 10 minutes.

2. **Remove DEBUG Logging in Production:** Change logger.setLevel(logging.DEBUG) to INFO and remove full event dump (line 275). Implementation: 15 minutes.

3. **Add Limit Parameter to DynamoDB Query:** Add Limit=MAX_FILES_PER_MANIFEST+1 to prevent loading all files. Implementation: 30 minutes.

4. **Add Missing COMPRESSION_TYPE Argument:** Add --COMPRESSION_TYPE to Glue default_arguments to match Python code expectations. Implementation: 5 minutes.

5. **Use DynamoDB BatchWriteItem:** Replace sequential update_item calls with batch operations for 10x throughput. Implementation: 2 hours.

---

# 2. Lambda Function Review

**File:** `lambda_manifest_builder.py` (1,042 lines)

## 2.1 Security Findings

### Finding LAMBDA-SEC-001: Module-Level Boto3 Clients

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 36-39 |
| **Assessment** | CORRECT AS IMPLEMENTED - Boto3 clients are thread-safe and use connection pooling. Module-level initialization is a best practice for Lambda warm start performance. |

### Finding LAMBDA-SEC-002: Sensitive Data in Logs

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 275: `logger.debug(f"Event received: {json.dumps(event)}")` |
| **Impact** | Full S3 event may contain bucket names, keys, and metadata that could be sensitive in CloudWatch logs. |
| **Fix** | Remove full event dump or redact sensitive fields. Set logging to INFO in production. |

### Finding LAMBDA-SEC-003: DynamoDB Expression Safety

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 812-819 |
| **Assessment** | SAFE - Code properly uses ExpressionAttributeNames and ExpressionAttributeValues for parameterized queries. No injection vulnerabilities detected. |

## 2.2 Reliability Findings

### Finding LAMBDA-REL-001: Distributed Lock Race Condition

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | Lines 81-145 (DistributedLock class), Line 674 (release in finally) |
| **Impact** | Lock released before Step Functions completes. Another Lambda can acquire lock and create duplicate manifests for the same files. |

**Root Cause:** The lock is released in the finally block (line 674) immediately after Step Functions is triggered, not after the workflow completes. This creates a race window where:
- Lambda A creates manifest, starts Step Functions, releases lock
- Lambda B acquires lock, sees same files still in 'pending' (eventual consistency)
- Lambda B creates duplicate manifest for same files

**Recommended Fix:** Change the locking strategy to protect only manifest creation, not the entire workflow. Use DynamoDB conditional updates on file status to prevent double-assignment:

```python
table.update_item(
    Key={'date_prefix': dp, 'file_key': fk},
    UpdateExpression='SET #status = :new_status',
    ConditionExpression='#status = :expected_status',
    ExpressionAttributeValues={':new_status': 'manifested', ':expected_status': 'pending'}
)
```

### Finding LAMBDA-REL-002: Missing Idempotency

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 566: `table.put_item(Item=item)` |
| **Impact** | SQS provides at-least-once delivery. If Lambda is retried, the same file is tracked again, potentially resetting its status. |

**Fix:** Add conditional expression:

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
| **Impact** | If start_execution fails after MANIFEST record creation, files are marked 'manifested' but workflow never runs, causing data loss. |

**Fix:** Reorder operations - start Step Functions first, then create MANIFEST record only on success:

```python
try:
    execution_arn = sfn_client.start_execution(...)  # Start SF FIRST
    manifest_record['execution_arn'] = execution_arn
    table.put_item(Item=manifest_record)  # Record AFTER success
except Exception:
    _update_file_status(batch_files, 'pending', None)  # Rollback
    raise
```

## 2.3 Performance Findings

### Finding LAMBDA-PERF-001: Memory Exhaustion at Scale

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | Lines 800-857: `_get_pending_files()` loads ALL pending files into memory |
| **Impact** | At 500K files/day with 10-file batches, pending queue could exceed Lambda memory limits. |

**Fix:** Add Limit parameter to fetch only needed records:

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
| **Impact** | Fixed delays cause thundering herd problem under high concurrency. |

**Fix:** Use exponential backoff with jitter:

```python
import random
delay = min(0.1 * (2 ** attempt) + random.uniform(0, 0.1), 5.0)
time.sleep(delay)
```

### Finding LAMBDA-PERF-003: Sequential DynamoDB Updates

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 949-986: `_update_file_status()` loops through files sequentially |
| **Impact** | 10 files × 50ms per update = 500ms minimum. Scales poorly. |

**Fix:** Use BatchWriteItem or TransactWriteItems for atomic batch updates.

## 2.4 Code Quality Findings

### Finding LAMBDA-CQ-001: TTL Calculation Duplication

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 551, 956, 1006 - identical TTL calculation repeated |
| **Fix** | Extract to helper function: `def calculate_ttl(): return int(time.time()) + (TTL_DAYS * 86400)` |

### Finding LAMBDA-CQ-002: Excessive Debug Logging

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Line 33: `logger.setLevel(logging.DEBUG)` |
| **Impact** | DEBUG logging in production increases CloudWatch costs and exposes sensitive data. |
| **Fix** | Use environment variable: `logger.setLevel(getattr(logging, os.environ.get('LOG_LEVEL', 'INFO')))` |

---

# 3. Glue Job Review

**File:** `glue_batch_job.py` (389 lines)

## 3.1 Performance Findings

### Finding GLUE-PERF-001: Hardcoded Shuffle Partitions

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Line 87: `spark.conf.set("spark.sql.shuffle.partitions", "100")` |
| **Impact** | Fixed 100 partitions suboptimal for varying workloads. AQE is enabled but initial setting affects first stages. |

**Recommendation:** Calculate based on data volume:

```python
num_workers = int(spark.conf.get('spark.executor.instances', '2'))
partitions = max(num_workers * 2, min(estimated_records // 100000, 200))
spark.conf.set('spark.sql.shuffle.partitions', str(partitions))
```

### Finding GLUE-PERF-002: DataFrame Caching Strategy

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Line 183: `df.cache()` |
| **Assessment** | ACCEPTABLE - Cache is used before count() and write(), avoiding recomputation. unpersist() on line 196 properly cleans up. |

**Enhancement:** Add memory threshold check for safety:

```python
if estimated_size_mb < 512:  # Only cache if fits in memory
    df.cache()
```

### Finding GLUE-PERF-003: Partition Size Estimation

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 187-188: `estimated_size_mb = record_count / 1024` |
| **Issue** | Assumes 1KB per record which may not be accurate. Consider using df.storageLevel or actual byte size. |

## 3.2 Reliability Findings

### Finding GLUE-REL-001: Generic Exception Handling

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 109, 142, 157, 207: `except Exception as e` |
| **Impact** | Generic exceptions hide specific errors. Consider catching Py4JJavaError, AnalysisException separately for better debugging. |

### Finding GLUE-REL-002: count() Before Write

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Lines 154, 184: `df.count()` triggers full scan |
| **Assessment** | ACCEPTABLE given caching - count() is needed for logging and partition calculation. Without cache this would double processing time. |

## 3.3 Code Quality Findings

### Finding GLUE-CQ-001: Unused CloudWatch Client

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | Line 41: `cloudwatch = boto3.client('cloudwatch')` |
| **Issue** | CloudWatch client is imported but never used. Remove or implement custom metrics. |

---

# 4. Terraform Infrastructure Review

## 4.1 Lambda Module Review

**File:** `modules/lambda/main.tf` (157 lines)

### Finding TF-LAMBDA-001: Missing VPC Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | aws_lambda_function resource (lines 29-76) |
| **Impact** | Lambda runs in AWS shared network space. For private cloud compliance, Lambda must run within VPC to meet network isolation requirements. |

**Fix:** Add VPC configuration:

```hcl
vpc_config {
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [var.lambda_security_group_id]
}
```

### Finding TF-LAMBDA-002: Missing Dead Letter Queue

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | aws_lambda_function resource (lines 29-76) |
| **Impact** | Failed Lambda invocations (after retries) are lost with no visibility or recovery mechanism. |

**Fix:** Add DLQ configuration:

```hcl
dead_letter_config {
  target_arn = var.lambda_dlq_arn  # SQS or SNS ARN
}
```

### Finding TF-LAMBDA-003: Missing X-Ray Tracing

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | aws_lambda_function resource |
| **Impact** | No distributed tracing across Lambda → Step Functions → Glue makes debugging production issues difficult. |

**Fix:** Add tracing:

```hcl
tracing_config {
  mode = "Active"
}
```

### Finding TF-LAMBDA-004: Missing LOG_LEVEL Environment Variable

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | environment.variables block (lines 48-67) |
| **Impact** | Python code hardcodes DEBUG level. Environment variable allows per-environment control. |

**Fix:** Add to environment variables:

```hcl
LOG_LEVEL = var.environment == "prod" ? "INFO" : "DEBUG"
```

### Finding TF-LAMBDA-005: Missing KMS Encryption

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | aws_lambda_function resource |
| **Impact** | Environment variables stored unencrypted. Defense-in-depth measure for private cloud compliance. |

**Fix:** Add KMS encryption:

```hcl
kms_key_arn = var.lambda_env_kms_key_arn
```

### Finding TF-LAMBDA-006: No Alarm Actions Configured

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | CloudWatch alarms (lines 102-157) |
| **Impact** | Alarms trigger but no one is notified. Alarms are effectively useless without alarm_actions. |

**Fix:** Add to all alarms:

```hcl
alarm_actions = var.alarm_sns_topic_arns
ok_actions    = var.alarm_sns_topic_arns  # Notify on recovery
```

## 4.2 IAM Module Review

**File:** `modules/iam/main.tf` (485 lines)

### Finding TF-IAM-001: Lambda Step Functions Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 136: `Resource = "*"` for states:StartExecution |
| **Impact** | Lambda can trigger ANY Step Functions state machine in the AWS account, not just the ETL workflow. |

**Fix:** Restrict to specific state machine ARN:

```hcl
Resource = var.step_function_arn  # Instead of "*"
```

### Finding TF-IAM-002: State Management Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Line 232: `Resource = "*"` for glue:GetJob, glue:GetJobRun, glue:GetJobRuns |
| **Impact** | State management Lambda can read status of ANY Glue job in the account. |

**Fix:** Restrict to specific Glue job ARN.

### Finding TF-IAM-003: Step Functions Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | Line 396: `Resource = "*"` for glue:StartJobRun, glue:BatchStopJobRun |
| **Impact** | Step Functions can start/stop ANY Glue job in the account. |

**Fix:** Restrict to specific Glue job ARN.

### Finding TF-IAM-004: EventBridge Glue Wildcard

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Line 480: `Resource = "*"` for glue:StartJobRun |
| **Impact** | EventBridge can trigger ANY Glue job in the account. |

**Fix:** Restrict to specific Glue job ARN.

### Finding TF-IAM-005: Missing Permission Boundaries

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | All IAM roles (lines 25, 150, 242, 355, 443) |
| **Impact** | Permission boundaries provide defense-in-depth for private cloud compliance. |

**Fix:** Add `permissions_boundary = var.permissions_boundary_arn` to all roles.

> **✅ Acceptable Wildcard:** Step Functions CloudWatch Logs wildcard (line 433) is ACCEPTABLE per AWS documentation.

## 4.3 Glue Module Review

**File:** `modules/glue/main.tf` (183 lines)

### Finding TF-GLUE-001: Missing Glue Security Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟠 High |
| **Location** | aws_glue_job resource (lines 26-78) |
| **Impact** | No encryption configuration for CloudWatch logs, job bookmarks, or S3 data. Required for private cloud compliance. |

**Fix:** Add security configuration:

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

resource "aws_glue_job" "batch_processor" {
  # ... existing config ...
  security_configuration = aws_glue_security_configuration.etl_security.name
}
```

### Finding TF-GLUE-002: Missing VPC Configuration

| Attribute | Details |
|-----------|---------|
| **Severity** | 🔴 Critical |
| **Location** | aws_glue_job resource - no VPC connection |
| **Impact** | For private cloud environments, Glue jobs must run within VPC to access private resources and meet network isolation requirements. |

**Fix:** Add VPC connection:

```hcl
resource "aws_glue_connection" "vpc_connection" {
  count = var.enable_vpc ? 1 : 0
  name  = "glue-vpc-${var.environment}"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    security_group_id_list = [var.glue_security_group_id]
    subnet_id              = var.private_subnet_id
  }
}

resource "aws_glue_job" "batch_processor" {
  # ... existing config ...
  connections = var.enable_vpc ? [aws_glue_connection.vpc_connection[0].name] : []
}
```

### Finding TF-GLUE-003: Missing COMPRESSION_TYPE Argument

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | default_arguments block (lines 42-65) |
| **Issue** | Python code expects --COMPRESSION_TYPE but it's not in Terraform. Job uses fallback 'snappy' but should be explicit. |

**Fix:** Add to default_arguments:

```hcl
"--COMPRESSION_TYPE" = var.compression_type  # Default: "snappy"
```

### Finding TF-GLUE-004: Alarms Only in Production

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | Lines 145-183: `count = var.environment == "prod" ? 1 : 0` |
| **Impact** | Dev/staging issues go unnoticed. Failures in non-prod may indicate bugs before production deployment. |

**Fix:** Enable alarms in all environments with different thresholds:

```hcl
count = 1  # Always create
threshold = var.environment == "prod" ? 5 : 20  # More lenient in dev
```

### Finding TF-GLUE-005: Missing Job Run State Alarm

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟡 Medium |
| **Location** | After line 183 |
| **Issue** | Current alarms monitor task-level metrics but not job-level run failures. |

**Fix:** Add job run failure alarm:

```hcl
resource "aws_cloudwatch_metric_alarm" "glue_job_run_failed" {
  alarm_name          = "${var.environment}-GlueJob-RunFailed"
  comparison_operator = "GreaterThanThreshold"
  metric_name         = "glue.driver.aggregate.numFailedStages"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  dimensions = { JobName = aws_glue_job.batch_processor.name }
  alarm_actions = var.alarm_sns_topic_arns
}
```

### Finding TF-GLUE-006: Consider Glue Flex

| Attribute | Details |
|-----------|---------|
| **Severity** | 🟢 Low |
| **Location** | aws_glue_job resource |
| **Opportunity** | Glue Flex uses spare capacity at ~34% discount. Acceptable if 2-3x startup delay is tolerable. |

**Enhancement:** Add execution_class option:

```hcl
execution_class = var.use_flex ? "FLEX" : "STANDARD"
```

---

# 5. Answers to Specific Questions

## 5.1 Security Questions

**Q1: Should Resource="*" in IAM policies be restricted?**

✅ **Answer:** Resource="*" grants access to all resources of that type across the AWS account. For private cloud compliance and security best practices, restrict to specific ARNs using Terraform data sources and resource references.

```hcl
Resource = [aws_sfn_state_machine.etl_workflow.arn]
```

**Q2: Is module-level boto3 client initialization thread-safe?**

✅ **Answer:** Yes. Boto3 clients use thread-safe connection pooling internally. Module-level initialization is a Lambda best practice that improves performance by reusing connections across warm invocations.

**Q3: Should we implement AWS Secrets Manager?**

✅ **Answer:** Current implementation has no secrets exposed (IAM roles handle AWS auth). If adding external integrations (databases, third-party APIs), implement Secrets Manager with automatic rotation.

**Q4: Are there SQL injection equivalents in DynamoDB?**

✅ **Answer:** The code properly uses ExpressionAttributeNames and ExpressionAttributeValues (lines 812-819). All user-provided values are parameterized. No injection vulnerabilities detected.

## 5.2 Architecture Questions

**Q5: Is the distributed locking implementation production-ready?**

❌ **Answer:** No. Critical issues: (1) Lock TTL (300s) may be less than Lambda timeout (up to 900s), (2) No heartbeat mechanism for long operations, (3) Lock released before workflow completes. Recommend using DynamoDB conditional updates instead of distributed locks.

**Q6: Should we implement Saga pattern for Step Functions?**

✅ **Answer:** Yes. Add CompensateFailure state that resets file statuses to 'pending' on Glue job failures. This enables automatic retry and prevents permanent data loss from transient failures.

**Q7: Is the retry logic optimal (lines 420-450)?**

⚠️ **Answer:** Partially optimal. Fixed delays (100ms, 500ms) should use exponential backoff with jitter to prevent thundering herd: `delay = min(base * 2^attempt + random_jitter, max_delay)`

**Q8: Should we use EventBridge instead of direct Step Functions?**

✅ **Answer:** Yes, recommended. EventBridge provides: built-in DLQ for failed invocations, archive and replay for debugging, easier addition of parallel consumers (logging, metrics, analytics).

## 5.3 Performance Questions

**Q9: How to optimize DynamoDB queries in _get_pending_files?**

✅ **Answer:** (1) Add Limit parameter to fetch only MAX_FILES_PER_MANIFEST+1 records, (2) Use parallel queries across date partitions with ThreadPoolExecutor, (3) Consider DynamoDB Streams for event-driven manifest creation instead of polling.

**Q10: Is df.cache() beneficial or harmful?**

✅ **Answer:** Beneficial in current implementation. Cache is used before both count() and write(), preventing double computation. The unpersist() call properly cleans up. Add memory check: `if estimated_size_mb < 512: df.cache()`

**Q11: Should Spark shuffle partitions be dynamic?**

✅ **Answer:** AQE (enabled on line 81) handles dynamic partition adjustment at runtime. The initial 100 setting is acceptable but can be calculated: `max(num_workers * 2, min(records // 100000, 200))`

**Q12: Can we parallelize orphan date flushing?**

✅ **Answer:** Yes. Use ThreadPoolExecutor: `with ThreadPoolExecutor(max_workers=5) as executor: list(executor.map(create_manifests_if_ready, orphaned_dates))`

## 5.4 Reliability Questions

**Q13: How to ensure exactly-once processing?**

✅ **Answer:** True exactly-once is impossible in distributed systems. Implement effectively-once via: (1) Idempotent file tracking with `ConditionExpression='attribute_not_exists(file_key)'`, (2) Idempotent Glue writes using output file naming with manifest ID, (3) SQS content-based deduplication.

**Q14: What if Lambda crashes after manifest but before Step Functions?**

✅ **Answer:** Files will be orphaned in 'manifested' status. Add scheduled CloudWatch rule to scan for MANIFEST records with status='pending' older than 1 hour and trigger recovery Lambda that either restarts the workflow or resets file statuses.

**Q15: Should we implement DLQ for Step Functions?**

✅ **Answer:** Step Functions has built-in retry. For terminal failures, use CloudWatch Events rule on FAILED state to trigger SNS notification. Add a 'CompensateFailure' state in the state machine for automatic cleanup.

**Q16: How to handle partial failures in batch updates?**

✅ **Answer:** Use DynamoDB TransactWriteItems for atomic batch updates (up to 100 items). For larger batches, use BatchWriteItem with UnprocessedItems retry loop and log failed items for manual recovery.

## 5.5 Observability & Cost Questions

**Q17: Should we migrate to structured JSON logging?**

✅ **Answer:** Yes. Use aws-lambda-powertools for structured logging with automatic CloudWatch Insights integration. Enables filtering by request_id, date_prefix, file_count without custom parsing.

**Q18: Is custom S3 metadata reporting better than CloudWatch/X-Ray?**

⚠️ **Answer:** Complementary, not either/or. Keep S3 reports for audit compliance and long-term retention. Add X-Ray for distributed tracing across Lambda/Step Functions/Glue. Use CloudWatch Embedded Metrics Format for real-time dashboards.

**Q19: What additional metrics should we track?**

✅ **Answer:** Add: (1) End-to-end latency (file arrival to Parquet available), (2) Files per manifest distribution histogram, (3) DynamoDB consumed vs provisioned capacity ratio, (4) Glue job memory/CPU utilization, (5) Lock contention rate.

**Q20: On-Demand vs Provisioned DynamoDB?**

✅ **Answer:** For 1K files/day: On-Demand is simpler and likely cheaper. For 100K+ files/day: Provisioned with autoscaling is more cost-effective. Set minimum capacity to handle baseline, maximum to 4x for bursts.

**Q21: Should we use Glue Flex?**

✅ **Answer:** Yes, for cost savings on batches where 15-minute SLA is acceptable. Glue Flex uses spare capacity at ~34% discount. Not recommended if SLA requires consistent sub-5-minute startup.

**Q22: S3 Intelligent-Tiering opportunities?**

✅ **Answer:** Enable for output Parquet bucket if access patterns vary (frequent access first 30 days, then infrequent). For manifest bucket (TTL-deleted), standard S3 is appropriate. Add Glacier transition at 90 days for compliance archives.

---

# 6. Scalability Analysis

## 6.1 Theoretical Throughput Limits

| Component | Theoretical Max | Current Bottleneck |
|-----------|----------------|-------------------|
| Lambda Concurrency | 1,000 (default) | DynamoDB query per invocation |
| SQS Throughput | ~3,000 msgs/sec | Not a bottleneck |
| DynamoDB Writes | 40,000 WCU | Sequential writes in Lambda |
| DynamoDB Reads | 40,000 RCU | GSI hot partition (status='pending') |
| Glue Concurrent Jobs | ~100 (soft limit) | Step Functions invocation rate |

## 6.2 Primary Bottleneck: GSI Hot Partition

The status-index GSI creates a hot partition because all queries filter on status='pending'. Regardless of provisioned capacity, a single partition is limited to ~1,000 reads/second. At 500K files/day with frequent polling, this will throttle.

**Solution:** Add write-sharding by prefixing status values:

```python
# Instead of: status = 'pending'
# Use: status = f'pending#{hash(file_key) % 10}'  # 10 shards

# Query with scatter-gather:
for shard in range(10):
    table.query(IndexName='status-index', 
                KeyConditionExpression='#status = :s',
                ExpressionAttributeValues={':s': f'pending#{shard}'})
```

## 6.3 Cost Projections

| Component | 1K/day | 100K/day | 500K/day | Notes |
|-----------|--------|----------|----------|-------|
| Lambda | $5 | $150 | $600 | 256MB, 10s avg |
| Glue (G.1X) | $20 | $800 | $3,500 | 2 workers |
| DynamoDB | $10 | $200 | $800 | Provisioned |
| S3 | $5 | $100 | $400 | Storage + requests |
| Step Functions | $1 | $30 | $150 | Standard |
| **TOTAL** | **~$41/mo** | **~$1,280/mo** | **~$5,450/mo** | |

> **Note:** 500K files/day exceeds the $5,000/month budget. Cost optimization strategies (Glue Flex ~34% savings, increased batch sizes to reduce Glue invocations) could reduce to approximately $3,500/month.

---

# 7. Prioritized Action Plan

## 7.1 Phase 1: Critical Fixes (< 1 Week)

| # | Action Item | Effort | File | Impact |
|---|-------------|--------|------|--------|
| 1 | Add ConditionExpression to track_file (line 566) | 10 min | Lambda.py | Idempotency |
| 2 | Add LOG_LEVEL env var to Lambda Terraform | 5 min | Lambda.tf | Log control |
| 3 | Remove DEBUG logging, use LOG_LEVEL env var | 30 min | Lambda.py | Security |
| 4 | Add Limit to _get_pending_files query | 30 min | Lambda.py | Memory safety |
| 5 | Add alarm_actions to Lambda CloudWatch alarms | 30 min | Lambda.tf | Alerting |
| 6 | Add Dead Letter Queue to Lambda | 1 hr | Lambda.tf | Error recovery |
| 7 | Reorder start_step_function: SF first, then record | 2 hrs | Lambda.py | Data integrity |
| 8 | Add --COMPRESSION_TYPE to Glue arguments | 5 min | Glue.tf | Correctness |
| 9 | Add Glue security configuration (encryption) | 2 hrs | Glue.tf | Compliance |
| 10 | Fix IAM wildcard: Lambda states:StartExecution (line 136) | 10 min | IAM.tf | Least privilege |
| 11 | Fix IAM wildcard: Step Functions glue:* (line 396) | 10 min | IAM.tf | Least privilege |

## 7.2 Phase 2: High-Priority Improvements (1-4 Weeks)

| # | Action Item | Effort | File | Impact |
|---|-------------|--------|------|--------|
| 1 | Add VPC configuration to Lambda | 2 hrs | Lambda.tf | Private cloud |
| 2 | Add VPC configuration to Glue | 4 hrs | Glue.tf | Private cloud |
| 3 | Add KMS encryption to Lambda env vars | 1 hr | Lambda.tf | Security |
| 4 | Implement structured JSON logging (Powertools) | 1 day | Lambda.py | Observability |
| 5 | Add X-Ray tracing to Lambda and Glue | 2 hrs | Both .tf | Debugging |
| 6 | Replace sequential updates with BatchWriteItem | 4 hrs | Lambda.py | Performance |
| 7 | Implement exponential backoff with jitter | 2 hrs | Lambda.py | Reliability |
| 8 | Add Saga pattern to Step Functions | 1 day | StepFn.tf | Recovery |
| 9 | Add orphaned MANIFEST recovery scheduled task | 4 hrs | Lambda+TF | Data integrity |
| 10 | Enable alarms in all environments | 1 hr | Both .tf | Observability |

## 7.3 Phase 3: Enhancements (1-3 Months)

| # | Action Item | Effort | File | Impact |
|---|-------------|--------|------|--------|
| 1 | Replace direct SF invocation with EventBridge | 3 days | Lambda+TF | Decoupling |
| 2 | Add write-sharding to DynamoDB GSI | 2 days | Lambda+TF | Scale to 500K |
| 3 | Implement circuit breaker pattern | 3 days | Lambda | Resilience |
| 4 | Add AWS X-Ray distributed tracing | 1 day | Lambda+Glue | Debugging |
| 5 | Evaluate DynamoDB Streams for event-driven | 1 week | All | Architecture |
| 6 | Implement Glue Flex for cost optimization | 2 days | Terraform | ~34% savings |
| 7 | Dynamic Spark partition calculation | 2 hrs | Glue | Performance |

---

# 8. Summary of All Findings

| ID | Finding | Severity | Phase |
|----|---------|----------|-------|
| **Lambda Code** | | | |
| LAMBDA-SEC-002 | Sensitive data in logs (event dump) | 🟠 High | Phase 1 |
| LAMBDA-REL-001 | Distributed lock race condition | 🔴 Critical | Phase 2 |
| LAMBDA-REL-002 | Missing idempotency in track_file | 🟠 High | Phase 1 |
| LAMBDA-REL-003 | Orphaned MANIFEST records | 🟠 High | Phase 1 |
| LAMBDA-PERF-001 | Memory exhaustion at scale | 🔴 Critical | Phase 1 |
| LAMBDA-PERF-002 | Suboptimal retry logic | 🟡 Medium | Phase 2 |
| LAMBDA-PERF-003 | Sequential DynamoDB updates | 🟡 Medium | Phase 2 |
| LAMBDA-CQ-001 | TTL calculation duplication | 🟢 Low | Phase 3 |
| LAMBDA-CQ-002 | Excessive DEBUG logging | 🟡 Medium | Phase 1 |
| **Glue Code** | | | |
| GLUE-PERF-001 | Hardcoded shuffle partitions | 🟡 Medium | Phase 3 |
| GLUE-PERF-003 | Partition size estimation | 🟢 Low | Phase 3 |
| GLUE-REL-001 | Generic exception handling | 🟡 Medium | Phase 2 |
| GLUE-CQ-001 | Unused CloudWatch client | 🟢 Low | Phase 3 |
| **Lambda Terraform** | | | |
| TF-LAMBDA-001 | Missing VPC configuration | 🔴 Critical | Phase 2 |
| TF-LAMBDA-002 | Missing Dead Letter Queue | 🟠 High | Phase 1 |
| TF-LAMBDA-003 | Missing X-Ray tracing | 🟡 Medium | Phase 2 |
| TF-LAMBDA-004 | Missing LOG_LEVEL env var | 🟡 Medium | Phase 1 |
| TF-LAMBDA-005 | Missing KMS encryption | 🟠 High | Phase 2 |
| TF-LAMBDA-006 | No alarm actions configured | 🟡 Medium | Phase 1 |
| **IAM Terraform** | | | |
| TF-IAM-001 | Lambda states:StartExecution wildcard (line 136) | 🟠 High | Phase 1 |
| TF-IAM-002 | State Mgmt glue:Get* wildcard (line 232) | 🟡 Medium | Phase 2 |
| TF-IAM-003 | Step Functions glue:* wildcard (line 396) | 🟠 High | Phase 1 |
| TF-IAM-004 | EventBridge glue:StartJobRun wildcard (line 480) | 🟡 Medium | Phase 2 |
| TF-IAM-005 | Missing permission boundaries | 🟡 Medium | Phase 2 |
| **Glue Terraform** | | | |
| TF-GLUE-001 | Missing Glue security configuration | 🟠 High | Phase 1 |
| TF-GLUE-002 | Missing VPC configuration | 🔴 Critical | Phase 2 |
| TF-GLUE-003 | Missing COMPRESSION_TYPE argument | 🟢 Low | Phase 1 |
| TF-GLUE-004 | Alarms only in production | 🟡 Medium | Phase 2 |
| TF-GLUE-005 | Missing job run state alarm | 🟡 Medium | Phase 2 |
| TF-GLUE-006 | Consider Glue Flex | 🟢 Low | Phase 3 |

## 8.1 Finding Distribution

**Total Findings: 30** (Lambda Code: 9, Glue Code: 4, Lambda TF: 6, IAM TF: 5, Glue TF: 6)

| Severity | Count | Percentage | Action |
|----------|-------|------------|--------|
| 🔴 Critical | 4 | 13% | Immediate (Phase 1) |
| 🟠 High | 10 | 33% | This sprint (Phase 1-2) |
| 🟡 Medium | 12 | 40% | Next sprint (Phase 2) |
| 🟢 Low | 4 | 13% | Backlog (Phase 3) |

---

# 9. Conclusion

This ETL pipeline demonstrates solid architectural foundations with well-designed separation of concerns. The code quality is good with comprehensive error handling and thoughtful features like end-of-day orphan flushing.

However, critical issues must be addressed before scaling to production targets:

- The distributed locking implementation has race condition vulnerabilities that can cause duplicate processing
- Memory management will fail at target scale without query limiting
- Missing idempotency guarantees make the system vulnerable to SQS retry semantics
- Terraform configuration lacks security features required for private cloud compliance
- IAM policies contain wildcard permissions that violate least privilege principle

By implementing Phase 1 fixes within one week (~8 hours of work), the pipeline can be stabilized for current workloads. Phase 2 improvements over the following month will prepare the system for scale. Phase 3 enhancements can then optimize costs and add advanced observability.

**Estimated Total Effort:** Phase 1 (~8 hours) + Phase 2 (~6-8 days) + Phase 3 (~3-4 weeks)

**Risk if Not Addressed:** Data loss from race conditions, Lambda OOM at scale, security audit failures, and exceeding $5K/month budget at 500K files/day.

---

*— End of Review Document —*
