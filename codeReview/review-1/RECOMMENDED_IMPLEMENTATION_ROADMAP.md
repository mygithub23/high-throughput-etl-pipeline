# Recommended Implementation Roadmap
## ETL Pipeline - Code Review Action Plan

**Based on**: Claude Opus Comprehensive Review (February 1, 2026)  
**Prepared by**: Development Team  
**Total Investment**: 8 hours → 6-8 days → 3-4 weeks (3 phases)

---

## 📋 Table of Contents

1. [Executive Summary](#executive-summary)
2. [Implementation Timeline](#implementation-timeline)
3. [Phase 1: Critical Fixes (This Week)](#phase-1-critical-fixes-this-week)
4. [Phase 2: Scale Preparation (Next Sprint)](#phase-2-scale-preparation-next-sprint)
5. [Phase 3: Optimization (Next Quarter)](#phase-3-optimization-next-quarter)
6. [Decision Points](#decision-points)
7. [Success Metrics](#success-metrics)
8. [Risk Mitigation](#risk-mitigation)
9. [Resource Allocation](#resource-allocation)

---

## Executive Summary

### Current State Assessment
- **Overall Rating**: ★★★☆☆ (3.2/5) - "Solid foundation, needs hardening"
- **Production Ready**: ✅ Yes for current 1K files/day
- **Scale Ready**: ❌ No for target 100K-500K files/day
- **Security Compliant**: ⚠️ Needs VPC + encryption for private cloud

### Critical Findings
- **🔴 Critical Issues**: 4 (Must fix this week)
- **🟠 High Priority**: 10 (This sprint)
- **🟡 Medium Priority**: 12 (Next sprint)
- **🟢 Low Priority**: 4 (Backlog)

### Investment Overview

| Phase | Timeline | Effort | Cost Impact | Risk Reduction |
|-------|----------|--------|-------------|----------------|
| **Phase 1** | This Week | 8 hours | Prevents data loss | ⭐⭐⭐⭐⭐ |
| **Phase 2** | 2-4 weeks | 6-8 days | Enables 100K/day scale | ⭐⭐⭐⭐ |
| **Phase 3** | 6-8 weeks | 3-4 weeks | Saves $1,950/month (36%) | ⭐⭐⭐⭐⭐ |

### Bottom Line
> **Recommendation**: Proceed with all 3 phases. Phase 1 is mandatory (prevents data loss). Phase 2 enables scale. Phase 3 achieves cost targets.

---

## Implementation Timeline

```
Week 1          Week 2-5              Quarter 1-2
┌────────┐     ┌──────────────┐      ┌─────────────────────┐
│PHASE 1 │     │   PHASE 2    │      │      PHASE 3        │
│8 hours │────▶│  6-8 days    │─────▶│     3-4 weeks       │
└────────┘     └──────────────┘      └─────────────────────┘
   │                 │                        │
   ▼                 ▼                        ▼
Critical Fixes   Scale Prep           Optimization
                                              
✅ Idempotency   ✅ VPC Config        ✅ GSI Sharding
✅ Memory Limit  ✅ Structured Logs   ✅ Glue Flex
✅ No DEBUG      ✅ X-Ray Tracing     ✅ EventBridge
✅ DLQ Setup     ✅ Saga Pattern      ✅ Circuit Breaker
✅ IAM Fixes     ✅ BatchWrite        ✅ DDB Streams
```

### Parallel Execution Strategy

**Phase 1** can be split into 2 parallel tracks:
- **Track A** (4 hours): Idempotency, Memory, Logging, IAM
- **Track B** (4 hours): DLQ, Glue encryption, MANIFEST ordering, Alarms

**With 2 developers**: Complete in **4 hours** instead of 8

---

## Phase 1: Critical Fixes (This Week)

### Overview
- **Goal**: Stabilize for current workload, prevent data loss
- **Duration**: 8 hours (1 developer-day) OR 4 hours (2 developers)
- **Risk Level**: 🔴 Critical - Must complete before production deployment
- **Success Criteria**: All 9 fixes deployed, zero critical issues in production

### Implementation Checklist

#### ✅ Fix #1: Add Idempotency to track_file (10 minutes)
**Priority**: 🔴 P0 - HIGHEST  
**Impact**: Prevents duplicate file tracking on SQS retries  
**File**: `environments/dev/lambda/lambda_manifest_builder.py`

**Current Code** (Line 566):
```python
table.put_item(Item=item)  # ❌ NO IDEMPOTENCY CHECK
```

**Fixed Code**:
```python
try:
    table.put_item(
        Item=item,
        ConditionExpression='attribute_not_exists(file_key)'  # ✅ ADD THIS
    )
    logger.debug(f"✓ Item written to DynamoDB (TTL: {TTL_DAYS} days)")
    
except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
    logger.info(f"File {file_name} already tracked (idempotent retry)")
    # Don't raise - this is normal SQS retry behavior
    
except Exception as e:
    logger.error(f"✗ Error tracking file: {str(e)}")
    raise
```

**Testing**:
```bash
# Upload same file twice - should create only 1 DynamoDB record
aws s3 cp test.ndjson s3://input-bucket/2026-02-01/test.ndjson
aws s3 cp test.ndjson s3://input-bucket/2026-02-01/test.ndjson

# Verify only 1 record exists
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking-dev \
  --key-condition-expression "date_prefix = :dp AND file_key = :fk" \
  --expression-attribute-values '{":dp":{"S":"2026-02-01"},":fk":{"S":"test.ndjson"}}'
```

---

#### ✅ Fix #2: Add Query Limit Parameter (30 minutes)
**Priority**: 🔴 P0  
**Impact**: Prevents Lambda OOM at scale  
**File**: `environments/dev/lambda/lambda_manifest_builder.py`

**Current Code** (Lines 812-820):
```python
query_params = {
    'KeyConditionExpression': 'date_prefix = :prefix',
    'FilterExpression': '#status = :status',
    'ExpressionAttributeNames': {'#status': 'status'},
    'ExpressionAttributeValues': {
        ':prefix': date_prefix,
        ':status': 'pending'
    }
    # ❌ NO LIMIT - loads ALL files into memory
}
```

**Fixed Code**:
```python
query_params = {
    'KeyConditionExpression': 'date_prefix = :prefix',
    'FilterExpression': '#status = :status',
    'ExpressionAttributeNames': {'#status': 'status'},
    'ExpressionAttributeValues': {
        ':prefix': date_prefix,
        ':status': 'pending'
    },
    'Limit': MAX_FILES_PER_MANIFEST + 1  # ✅ Only fetch what we need
}

# Add early exit when enough files retrieved
if len(files) >= MAX_FILES_PER_MANIFEST:
    logger.info(f"Retrieved {len(files)} files (reached limit)")
    break  # Stop pagination
```

**Testing**:
```bash
# Monitor Lambda memory before/after
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name MemoryUtilization \
  --dimensions Name=FunctionName,Value=ndjson-parquet-manifest-builder-dev \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Maximum
```

---

#### ✅ Fix #3: Remove DEBUG Logging (15 minutes)
**Priority**: 🔴 P0  
**Impact**: Stop exposing sensitive data in logs  
**Files**: `lambda_manifest_builder.py`, `terraform/modules/lambda/main.tf`

**Python Changes** (Lines 33, 275):
```python
# Line 33 - Make logging configurable
import os
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# Line 275 - Remove full event dump
logger.info(f"📥 Processing {len(event.get('Records', []))} SQS records")
# Remove: logger.debug(f"Event received: {json.dumps(event)}")
```

**Terraform Changes** (terraform/modules/lambda/main.tf):
```hcl
environment {
  variables = {
    # ... existing variables ...
    LOG_LEVEL = var.environment == "prod" ? "INFO" : "DEBUG"  # ✅ ADD THIS
  }
}
```

**Testing**:
```bash
# Verify no DEBUG logs in production
aws logs filter-log-events \
  --log-group-name /aws/lambda/ndjson-parquet-manifest-builder-prod \
  --filter-pattern "DEBUG" \
  --max-items 1
# Should return: No events found
```

---

#### ✅ Fix #4: Fix Orphaned MANIFEST Records (2 hours)
**Priority**: 🔴 P0  
**Impact**: Prevents files marked 'manifested' but never processed  
**File**: `environments/dev/lambda/lambda_manifest_builder.py`

**Strategy**: Start Step Functions FIRST, then create MANIFEST record only on success

**Fixed Code** (Lines 997-1041):
```python
def start_step_function(manifest_path: str, date_prefix: str, file_count: int, 
                        batch_files: List[Dict]) -> Optional[str]:
    """Start Step Functions workflow with rollback support."""
    if not STEP_FUNCTION_ARN:
        return None

    try:
        manifest_filename = manifest_path.split('/')[-1]
        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
        
        # ✅ STEP 1: Start Step Functions FIRST
        sf_response = sfn_client.start_execution(
            stateMachineArn=STEP_FUNCTION_ARN,
            input=json.dumps({
                'manifest_path': manifest_path,
                'date_prefix': date_prefix,
                'file_count': file_count,
                'file_key': f'MANIFEST#{manifest_filename}',
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
        )
        
        execution_arn = sf_response['executionArn']
        logger.info(f"✓ Started Step Function: {execution_arn}")
        
        # ✅ STEP 2: Create record ONLY after SF succeeds
        manifest_record = {
            'date_prefix': date_prefix,
            'file_key': f'MANIFEST#{manifest_filename}',
            'status': 'pending',
            'file_count': file_count,
            'manifest_path': manifest_path,
            'execution_arn': execution_arn,
            'created_at': datetime.now(timezone.utc).isoformat(),
            'ttl': ttl_timestamp
        }
        table.put_item(Item=manifest_record)
        logger.info(f"✓ MANIFEST record created")
        
        return execution_arn

    except Exception as e:
        logger.error(f"✗ Step Function failed: {str(e)}")
        
        # ✅ STEP 3: Rollback file statuses
        logger.warning(f"Rolling back {len(batch_files)} file statuses to 'pending'")
        _update_file_status(batch_files, 'pending', None)
        
        return None
```

**Caller Update** (create_manifests_if_ready):
```python
# Pass batch_files to start_step_function for rollback
execution_arn = start_step_function(
    manifest_path, date_prefix, len(batch_files), batch_files  # ✅ Add batch_files
)

if not execution_arn:
    logger.error(f"⚠️ Failed to start workflow, files rolled back")
    manifests_created -= 1  # Don't count as created
```

---

#### ✅ Fix #5: Add Dead Letter Queue (1 hour)
**Priority**: 🟠 P1  
**Impact**: Capture failed Lambda invocations  
**File**: `terraform/modules/lambda/main.tf`

**Implementation**:
```hcl
# Step 1: Create DLQ
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "ndjson-parquet-lambda-dlq-${var.environment}"
  message_retention_seconds = 1209600  # 14 days

  tags = merge(var.tags, {
    Name = "Lambda DLQ"
  })
}

# Step 2: Attach to Lambda
resource "aws_lambda_function" "manifest_builder" {
  # ... existing config ...
  
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
}

# Step 3: Add alarm
resource "aws_cloudwatch_metric_alarm" "lambda_dlq_messages" {
  alarm_name          = "${var.environment}-Lambda-DLQ-CRITICAL"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [var.alarm_sns_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.lambda_dlq.name
  }
}

# Step 4: IAM permission
resource "aws_iam_role_policy" "lambda_dlq" {
  name = "lambda-dlq-access"
  role = var.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.lambda_dlq.arn
    }]
  })
}
```

---

#### ✅ Fix #6: Fix IAM Wildcards (30 minutes)
**Priority**: 🟠 P1  
**Impact**: Least privilege compliance  
**File**: `terraform/modules/iam/main.tf`

**Fix Line 136** (Lambda Step Functions):
```hcl
# Before
Resource = "*"  # ❌

# After
Resource = var.step_function_arn  # ✅
```

**Fix Line 396** (Step Functions Glue):
```hcl
# Before
Resource = "*"  # ❌

# After
Resource = var.glue_job_arn  # ✅
```

**Add Variables** (terraform/modules/iam/variables.tf):
```hcl
variable "step_function_arn" {
  description = "Step Functions state machine ARN"
  type        = string
}

variable "glue_job_arn" {
  description = "Glue job ARN"
  type        = string
}
```

**Update Root Module** (terraform/main.tf):
```hcl
module "iam" {
  source = "./modules/iam"
  
  # Pass specific ARNs
  step_function_arn = module.step_functions.state_machine_arn
  glue_job_arn      = module.glue.job_arn
  
  # ... other variables ...
}
```

---

#### ✅ Fix #7: Add Glue Security Configuration (2 hours)
**Priority**: 🟠 P1  
**Impact**: Encryption compliance  
**File**: `terraform/modules/glue/main.tf`

**Implementation**:
```hcl
# Create security configuration
resource "aws_glue_security_configuration" "etl_security" {
  name = "ndjson-parquet-security-${var.environment}"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}

# Attach to Glue job
resource "aws_glue_job" "batch_processor" {
  # ... existing config ...
  security_configuration = aws_glue_security_configuration.etl_security.name
}
```

**Add KMS Permissions** (terraform/modules/iam/main.tf):
```hcl
# In Glue role policy
{
  Effect = "Allow"
  Action = [
    "kms:Decrypt",
    "kms:Encrypt",
    "kms:GenerateDataKey"
  ]
  Resource = var.kms_key_arn
}
```

---

#### ✅ Fix #8: Add COMPRESSION_TYPE Argument (5 minutes)
**Priority**: 🟢 P3  
**Impact**: Explicit configuration  
**File**: `terraform/modules/glue/main.tf`

**Implementation**:
```hcl
default_arguments = {
  # ... existing arguments ...
  "--COMPRESSION_TYPE" = var.compression_type  # ✅ ADD THIS
}
```

**Add Variable** (terraform/modules/glue/variables.tf):
```hcl
variable "compression_type" {
  description = "Parquet compression codec"
  type        = string
  default     = "snappy"
}
```

---

#### ✅ Fix #9: Add Alarm Actions (30 minutes)
**Priority**: 🟡 P2  
**Impact**: Enable actual alerting  
**File**: `terraform/modules/lambda/main.tf`

**Apply to ALL Alarms** (Lines 102-157):
```hcl
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  # ... existing config ...
  
  # ✅ ADD THESE
  alarm_actions = [var.alarm_sns_topic_arn]
  ok_actions    = [var.alarm_sns_topic_arn]
}

# Repeat for lambda_throttles and lambda_duration alarms
```

**Add Variable**:
```hcl
variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for alarms"
  type        = string
}
```

**Update Root Module**:
```hcl
module "lambda" {
  source = "./modules/lambda"
  
  alarm_sns_topic_arn = module.monitoring.sns_topic_arn
  # ... other variables ...
}
```

---

### Phase 1 Deployment Steps

#### Pre-Deployment Checklist
- [ ] Create feature branch: `git checkout -b phase1-critical-fixes`
- [ ] Review all code changes
- [ ] Run Python linting: `pylint lambda_manifest_builder.py`
- [ ] Run Terraform validation: `terraform validate`
- [ ] Run Terraform plan: `terraform plan -out=phase1.tfplan`
- [ ] Backup current Lambda: `aws lambda get-function ...`

#### Deployment
```bash
# 1. Update Lambda code
cd environments/dev/lambda
zip lambda_manifest_builder.zip lambda_manifest_builder.py
aws s3 cp lambda_manifest_builder.zip s3://scripts-bucket/lambda/dev/

# 2. Apply Terraform
cd ../../../terraform
terraform apply phase1.tfplan

# 3. Verify deployment
aws lambda get-function --function-name ndjson-parquet-manifest-builder-dev
```

#### Post-Deployment Testing
```bash
# Test 1: Idempotency
aws s3 cp test.ndjson s3://input-bucket/test/test.ndjson
aws s3 cp test.ndjson s3://input-bucket/test/test.ndjson  # Duplicate

# Test 2: Check logs (should be INFO, not DEBUG)
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow

# Test 3: Verify DLQ empty
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name ndjson-parquet-lambda-dlq-dev --output text) \
  --attribute-names ApproximateNumberOfMessages
```

---

## Phase 2: Scale Preparation (Next Sprint)

### Overview
- **Goal**: Enable 100K files/day, private cloud compliance
- **Duration**: 6-8 developer-days (2-4 weeks calendar)
- **Prerequisites**: Phase 1 complete, VPC requirement confirmed
- **Success Criteria**: Handle 100K files/day in load test, zero throttling

### Implementation Items

#### 1. VPC Configuration for Lambda (4 hours)
**Priority**: 🔴 Critical (if required by InfoSec)

```hcl
resource "aws_lambda_function" "manifest_builder" {
  # ... existing config ...
  
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }
}
```

**Note**: Requires VPC endpoints for S3, DynamoDB, SQS, Step Functions

#### 2. VPC Configuration for Glue (6 hours)
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

#### 3. KMS Encryption for Lambda Env Vars (1.5 hours)
```hcl
resource "aws_lambda_function" "manifest_builder" {
  # ... existing config ...
  kms_key_arn = var.lambda_env_kms_key_arn
}
```

#### 4. Structured JSON Logging (8 hours)
**Install aws-lambda-powertools**:
```python
from aws_lambda_powertools import Logger

logger = Logger(service="manifest-builder")

# Usage
logger.info("Processing file", extra={
    "file_key": file_name,
    "date_prefix": date_prefix,
    "file_size_mb": size_mb
})
```

#### 5. X-Ray Tracing (3 hours)
**Lambda**:
```hcl
tracing_config {
  mode = "Active"
}
```

**Python**:
```python
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

patch_all()
```

#### 6. BatchWriteItem Optimization (4 hours)
**Replace sequential updates** (lines 949-986):
```python
def _update_file_status_batch(files: List[Dict], status: str, manifest_path: str):
    """Update file statuses in batches for 10x performance."""
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
    
    # Batch requests (max 25 per batch)
    for i in range(0, len(files), 25):
        batch = files[i:i + 25]
        
        with table.batch_writer() as writer:
            for file_info in batch:
                writer.put_item(Item={
                    'date_prefix': file_info['date_prefix'],
                    'file_key': file_info['filename'],
                    'status': status,
                    'manifest_path': manifest_path,
                    'updated_at': datetime.now(timezone.utc).isoformat(),
                    'ttl': ttl_timestamp
                })
```

#### 7. Exponential Backoff with Jitter (2 hours)
**Fix lines 420-450**:
```python
import random

for attempt in range(max_consecutive_failures):
    manifests_created = create_manifests_if_ready(date_prefix)
    
    if manifests_created > 0:
        break
    
    # Exponential backoff with jitter
    base_delay = 0.1
    max_delay = 5.0
    delay = min(base_delay * (2 ** attempt) + random.uniform(0, 0.1), max_delay)
    time.sleep(delay)
```

#### 8. Saga Pattern for Step Functions (8 hours)
**Add CompensateFailure state**:
```hcl
# In Step Functions state machine
States = {
  # ... existing states ...
  
  UpdateStatusFailed = {
    # ... existing config ...
    Next = "CompensateFailure"  # Instead of SendFailureAlert
  }
  
  CompensateFailure = {
    Type     = "Task"
    Resource = "arn:aws:states:::dynamodb:updateItem"
    Parameters = {
      TableName = var.file_tracking_table_name
      # Query for files with this manifest_path
      # Reset their status to 'pending'
    }
    Next = "SendFailureAlert"
  }
}
```

#### 9. Orphaned MANIFEST Recovery Job (4 hours)
**Create scheduled Lambda**:
```python
def recovery_lambda_handler(event, context):
    """Find and fix orphaned MANIFEST records."""
    # Query for MANIFEST# records with status='pending' older than 1 hour
    # For each: check if SF execution exists
    # If not: reset file statuses to 'pending' and delete MANIFEST record
```

**Terraform**:
```hcl
resource "aws_cloudwatch_event_rule" "orphan_recovery" {
  name                = "orphan-manifest-recovery-${var.environment}"
  schedule_expression = "rate(1 hour)"
}
```

#### 10. Enable Alarms in All Environments (1.5 hours)
```hcl
# Change from:
count = var.environment == "prod" ? 1 : 0

# To:
count     = 1
threshold = var.environment == "prod" ? 5 : 20  # More lenient in dev
```

---

## Phase 3: Optimization (Next Quarter)

### Overview
- **Goal**: Enable 500K files/day, reduce costs 36%
- **Duration**: 3-4 developer-weeks (6-8 weeks calendar)
- **Prerequisites**: Phase 2 complete, load testing environment ready
- **Success Criteria**: 500K files/day with zero throttling, cost < $3,500/month

### Key Implementations

#### 1. DynamoDB GSI Write-Sharding (16 hours)
**PRIMARY BOTTLENECK FIX**

**Current Issue**: Single partition on `status='pending'` limited to 1,000 reads/sec

**Solution**: Shard the status value
```python
# Write side - add shard suffix
shard_id = hash(file_key) % 10  # 10 shards
status_with_shard = f"pending#{shard_id}"

table.put_item(Item={
    'date_prefix': date_prefix,
    'file_key': file_name,
    'status': status_with_shard,  # ✅ Sharded
    # ... other fields ...
})

# Read side - scatter-gather across shards
def _get_pending_files_sharded(date_prefix: str) -> List[Dict]:
    all_files = []
    
    # Query all 10 shards in parallel
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = []
        for shard in range(10):
            status_key = f'pending#{shard}'
            future = executor.submit(_query_shard, date_prefix, status_key)
            futures.append(future)
        
        for future in futures:
            all_files.extend(future.result())
    
    return all_files
```

**Impact**: Increases read capacity from 1,000/sec to 10,000/sec (10x)

#### 2. EventBridge Decoupling (24 hours)
**Replace direct SF invocation**:
```python
# Instead of:
sfn_client.start_execution(...)

# Use EventBridge:
events_client.put_events(
    Entries=[{
        'Source': 'etl.pipeline',
        'DetailType': 'ManifestReady',
        'Detail': json.dumps({
            'manifest_path': manifest_path,
            'date_prefix': date_prefix
        })
    }]
)
```

**Benefits**: DLQ, archive/replay, multiple consumers

#### 3. Circuit Breaker Pattern (24 hours)
```python
class CircuitBreaker:
    def __init__(self, failure_threshold=5, timeout=60):
        self.failure_count = 0
        self.failure_threshold = failure_threshold
        self.timeout = timeout
        self.last_failure_time = None
        self.state = 'CLOSED'  # CLOSED, OPEN, HALF_OPEN
    
    def call(self, func, *args, **kwargs):
        if self.state == 'OPEN':
            if time.time() - self.last_failure_time > self.timeout:
                self.state = 'HALF_OPEN'
            else:
                raise Exception("Circuit breaker is OPEN")
        
        try:
            result = func(*args, **kwargs)
            self.failure_count = 0
            self.state = 'CLOSED'
            return result
        except Exception as e:
            self.failure_count += 1
            self.last_failure_time = time.time()
            if self.failure_count >= self.failure_threshold:
                self.state = 'OPEN'
            raise
```

#### 4. Glue Flex for Cost Savings (16 hours)
```hcl
resource "aws_glue_job" "batch_processor" {
  # ... existing config ...
  execution_class = var.use_glue_flex ? "FLEX" : "STANDARD"
}
```

**Cost Impact**: ~34% savings ($3,500 → $2,310/month)  
**Trade-off**: 2-3x slower startup time

#### 5. DynamoDB Streams Evaluation (40 hours)
**Event-driven architecture**:
- Replace polling with DynamoDB Streams
- Trigger manifest creation when enough files accumulated
- Reduces Lambda invocations by 90%

**Architecture**:
```
S3 → SQS → Lambda (track file) → DynamoDB
                                      ↓
                                  DynamoDB Stream
                                      ↓
                                  Lambda (manifest creator)
                                      ↓
                                  Step Functions
```

---

## Decision Points

### Decision #1: VPC Requirement
**Question**: Must Lambda/Glue run in VPC for private cloud?

**Impact on Timeline**:
- **If YES**: VPC becomes Phase 1 (add 6 hours to critical path)
- **If NO**: VPC stays in Phase 2

**Who Decides**: InfoSec  
**Deadline**: This week (before Phase 1 deployment)

### Decision #2: Scale Timeline
**Question**: When do we need 100K-500K files/day?

| Answer | Required Phases | Timeline |
|--------|----------------|----------|
| < 1 month | Phase 1 only | 1 week |
| 1-3 months | Phase 1 + 2 | 4 weeks |
| 3-6 months | All 3 phases | 10 weeks |

**Who Decides**: Product  
**Deadline**: End of Phase 1 (for sprint planning)

### Decision #3: Budget Flexibility
**Question**: Can we exceed $5K/month temporarily?

**Impact**:
- **If YES**: Scale first, optimize later
- **If NO**: MUST complete Phase 3 before scaling to 500K/day

**Who Decides**: Finance  
**Deadline**: Before Phase 3 kickoff

---

## Success Metrics

### Phase 1 Success Criteria
- [ ] Zero idempotency failures in CloudWatch logs
- [ ] Lambda memory usage < 50% of allocated
- [ ] No DEBUG logs in production
- [ ] DLQ remains empty for 1 week
- [ ] All CloudWatch alarms have SNS actions
- [ ] Glue encryption verified in console
- [ ] Zero orphaned MANIFEST records

### Phase 2 Success Criteria
- [ ] Lambda/Glue running in VPC (if required)
- [ ] X-Ray traces show end-to-end workflow
- [ ] Structured logs queryable in CloudWatch Insights
- [ ] Saga pattern tested with intentional failures
- [ ] Orphan recovery job finds and fixes test orphans
- [ ] File update latency < 100ms (BatchWrite)
- [ ] 100K files/day load test passes

### Phase 3 Success Criteria
- [ ] DynamoDB GSI throttling = 0 at 500K/day
- [ ] Monthly cost < $3,500 at 500K/day
- [ ] EventBridge DLQ tested
- [ ] Circuit breaker triggers during simulated outage
- [ ] Glue Flex jobs complete within 15-min SLA
- [ ] DynamoDB Streams architecture evaluated

---

## Risk Mitigation

### Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| VPC causes Lambda cold starts | Medium | High | Pre-warm with scheduled pings |
| GSI sharding breaks existing queries | Low | Critical | Comprehensive testing in dev |
| Glue Flex exceeds SLA | Medium | Medium | Fallback to STANDARD for critical batches |
| DynamoDB Streams backlog | Low | High | Monitor stream iterator age |

### Schedule Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Phase 1 takes > 8 hours | Low | Low | Use 2 developers in parallel |
| VPC approval delayed | Medium | High | Start Phase 1 without VPC, add later |
| Load testing environment unavailable | Medium | Medium | Use production with small test dataset |

### Budget Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Phase 3 delayed, costs exceed budget | Medium | High | Implement Glue Flex early |
| DynamoDB costs higher than estimated | Low | Medium | Monitor daily, adjust autoscaling |

---

## Resource Allocation

### Phase 1 (Week 1)
- **Team**: 1 senior developer
- **Duration**: 8 hours (OR 4 hours with 2 developers)
- **Parallel Tracks**:
  - Track A: Idempotency, Memory, Logging (4 hrs)
  - Track B: DLQ, Encryption, Alarms (4 hrs)

### Phase 2 (Weeks 2-5)
- **Team**: 1 senior + 1 mid-level developer
- **Duration**: 2 weeks (OR 4 weeks with 1 developer)
- **Parallel Tracks**:
  - Track A: VPC + Security (senior)
  - Track B: Observability (mid-level)
  - Track C: Performance (both)

### Phase 3 (Weeks 6-14)
- **Team**: 2 developers + 1 architect (part-time)
- **Duration**: 4-6 weeks calendar time
- **Critical Path**: GSI sharding design + implementation

---

## Deployment Strategy

### Environment Progression
```
Dev → Staging → Production
 ↓       ↓          ↓
Test   Soak    Full Release
      (48hrs)
```

### Rollback Plan

**Phase 1 Rollback**:
```bash
# Restore previous Lambda code
aws lambda update-function-code \
  --function-name ndjson-parquet-manifest-builder-dev \
  --s3-key lambda/dev/lambda_manifest_builder_backup.zip

# Rollback Terraform
terraform apply -var-file=previous.tfvars
```

**Phase 2/3 Rollback**:
- Feature flags for new functionality
- Blue/green deployment for major changes
- Database migration scripts (forward + backward)

---

## Conclusion

### Summary
This 3-phase implementation plan addresses all 30 findings from the Opus review in a structured, low-risk manner:

- **Phase 1** (8 hours): Prevents data loss, fixes critical security issues
- **Phase 2** (6-8 days): Enables 100K/day scale, achieves private cloud compliance
- **Phase 3** (3-4 weeks): Removes 500K/day bottleneck, saves 36% on costs

### Total Investment
- **Time**: ~50-60 developer-days over 10-14 weeks
- **Cost**: Prevented losses + $1,950/month ongoing savings
- **ROI**: Immediate (data loss prevention) + long-term (cost optimization)

### Recommendation
✅ **Approve all 3 phases**

**Rationale**:
1. Phase 1 is mandatory for production stability
2. Phase 2 is required for scale targets
3. Phase 3 achieves cost efficiency and removes bottlenecks

---

## Appendix: Quick Reference

### Critical Contacts
- **InfoSec**: [Contact] - VPC requirement decision
- **Product**: [Contact] - Scale timeline decision
- **Finance**: [Contact] - Budget approval

### Key Documents
- Full Opus Review: `ETL_Pipeline_Review.md`
- Executive Summary: `EXECUTIVE_SUMMARY_PRESENTATION.md`
- Prioritization Matrix: `PRIORITIZATION_MATRIX.md`
- Phase 1 Details: `PHASE1_IMPLEMENTATION_GUIDE.md`

### Useful Commands
```bash
# Deploy Lambda
cd environments/dev/lambda && zip -r lambda.zip . && \
aws s3 cp lambda.zip s3://scripts-bucket/lambda/dev/

# Check CloudWatch logs
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow

# Monitor DynamoDB
aws cloudwatch get-metric-statistics --namespace AWS/DynamoDB \
  --metric-name ConsumedReadCapacityUnits --dimensions Name=TableName,Value=...

# Test idempotency
aws s3 cp test.ndjson s3://input-bucket/2026-02-01/test.ndjson
```

---

**Document Version**: 1.0  
**Last Updated**: February 1, 2026  
**Next Review**: After Phase 1 completion

---

*End of Recommended Implementation Roadmap*
