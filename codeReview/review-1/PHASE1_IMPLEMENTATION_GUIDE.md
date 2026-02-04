# Phase 1 Implementation Guide - Code Fixes
## Critical Fixes (8 Hours Total)

**Target Completion**: This Week  
**Risk Level**: 🔴 Critical  
**Team Required**: 1 Senior Developer

---

## Fix #1: Add Idempotency to track_file ⭐ HIGHEST PRIORITY
**Time**: 10 minutes  
**Impact**: Prevents duplicate file tracking on SQS retries  
**Risk Prevented**: Data loss, duplicate processing

### Current Code (Line 566)
```python
# File: environments/dev/lambda/lambda_manifest_builder.py
# Line: 566

table.put_item(Item=item)  # ❌ NO IDEMPOTENCY CHECK
```

### Fixed Code
```python
try:
    table.put_item(
        Item=item,
        ConditionExpression='attribute_not_exists(file_key)'  # ✅ ADD THIS
    )
    logger.debug(f"✓ Item written to DynamoDB (TTL: {TTL_DAYS} days)")
    
except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
    # File already tracked - this is expected on SQS retry
    logger.info(f"File {file_name} already tracked (idempotent retry)")
    # Don't raise - this is normal behavior
    
except Exception as e:
    logger.error(f"✗ Error tracking file: {str(e)}")
    logger.error(f"Traceback: {traceback.format_exc()}")
    raise
```

### Testing
```bash
# Test idempotency by uploading same file twice
aws s3 cp test.ndjson s3://input-bucket/2026-02-01/test.ndjson
aws s3 cp test.ndjson s3://input-bucket/2026-02-01/test.ndjson  # Should not create duplicate

# Check DynamoDB - should have only 1 record
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking-dev \
  --key-condition-expression "date_prefix = :dp AND file_key = :fk" \
  --expression-attribute-values '{":dp":{"S":"2026-02-01"},":fk":{"S":"test.ndjson"}}'
```

---

## Fix #2: Add Query Limit Parameter
**Time**: 30 minutes  
**Impact**: Prevents Lambda OOM at scale  
**Risk Prevented**: Production outage

### Current Code (Lines 812-820)
```python
# File: environments/dev/lambda/lambda_manifest_builder.py
# Lines: 812-820

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

### Fixed Code
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

# Also update the loop to stop after getting enough files
if len(files) >= MAX_FILES_PER_MANIFEST:
    logger.info(f"Retrieved {len(files)} files (reached limit)")
    break  # Stop pagination early
```

### Testing
```bash
# Monitor Lambda memory usage before/after
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

## Fix #3: Remove DEBUG Logging
**Time**: 15 minutes  
**Impact**: Stop exposing sensitive data in logs  
**Risk Prevented**: Data exposure, compliance violation

### Current Code (Line 33 + 275)
```python
# File: environments/dev/lambda/lambda_manifest_builder.py

# Line 33
logger.setLevel(logging.DEBUG)  # ❌ HARDCODED DEBUG

# Line 275
logger.debug(f"📥 Event received: {json.dumps(event, indent=2, default=str)}")  # ❌ FULL EVENT DUMP
```

### Fixed Code
```python
# Line 33
import os
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')  # ✅ Environment variable
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# Line 275
# Remove or sanitize the event dump
logger.info(f"📥 Processing {len(event.get('Records', []))} SQS records")
# Only log event in DEBUG mode, and redact sensitive fields
if logger.level == logging.DEBUG:
    sanitized_event = {
        'record_count': len(event.get('Records', [])),
        # Don't log full S3 paths or bucket names
    }
    logger.debug(f"Event summary: {json.dumps(sanitized_event)}")
```

### Terraform Changes
```hcl
# File: terraform/modules/lambda/main.tf
# Add to environment.variables block (around line 64)

environment {
  variables = {
    # ... existing variables ...
    LOG_LEVEL = var.environment == "prod" ? "INFO" : "DEBUG"  # ✅ ADD THIS
  }
}
```

### variables.tf Addition
```hcl
# File: terraform/modules/lambda/variables.tf
# Add new variable

variable "log_level" {
  description = "Logging level for Lambda function"
  type        = string
  default     = "INFO"
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be DEBUG, INFO, WARNING, or ERROR."
  }
}
```

---

## Fix #4: Fix Orphaned MANIFEST Records
**Time**: 2 hours  
**Impact**: Prevents files being marked 'manifested' but never processed  
**Risk Prevented**: Data loss

### Current Code (Lines 997-1041)
```python
# File: environments/dev/lambda/lambda_manifest_builder.py

def start_step_function(...):
    try:
        # ❌ WRONG ORDER: Record created FIRST
        table.put_item(Item=manifest_record)  # Line 1017
        logger.info(f"✓ MANIFEST record created")
        
        # ❌ If this fails, record exists but workflow never started
        response = sfn_client.start_execution(...)  # Line 1023
        
        execution_arn = response['executionArn']
        return execution_arn
```

### Fixed Code
```python
def start_step_function(manifest_path: str, date_prefix: str, file_count: int) -> Optional[str]:
    logger.info("---------- start_step_function -------------")
    """Start Step Functions workflow to process manifest."""
    if not STEP_FUNCTION_ARN:
        logger.warning("⚠️  STEP_FUNCTION_ARN not set, skipping Step Function trigger")
        return None

    try:
        manifest_filename = manifest_path.split('/')[-1]
        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
        
        # Prepare manifest record but DON'T write yet
        manifest_record = {
            'date_prefix': date_prefix,
            'file_key': f'MANIFEST#{manifest_filename}',
            'status': 'pending',
            'file_count': file_count,
            'manifest_path': manifest_path,
            'created_at': datetime.now(timezone.utc).isoformat(),
            'ttl': ttl_timestamp
        }

        # ✅ STEP 1: Start Step Functions FIRST
        logger.info(f"🚀 Starting Step Function execution for manifest: {manifest_path}")
        
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
        logger.info(f"✓ Started Step Function execution: {execution_arn}")
        
        # ✅ STEP 2: Write record ONLY after SF succeeds
        manifest_record['execution_arn'] = execution_arn
        table.put_item(Item=manifest_record)
        logger.info(f"✓ MANIFEST record created: {date_prefix}/MANIFEST#{manifest_filename}")
        
        return execution_arn

    except Exception as e:
        logger.error(f"✗ Failed to start Step Function: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        
        # ✅ STEP 3: Rollback file statuses if SF failed
        # Files were already marked 'manifested' in _update_file_status
        # We need to reset them to 'pending'
        # Note: This requires passing batch_files to this function
        # For now, log error - manual recovery needed
        logger.error(f"⚠️ CRITICAL: Files marked 'manifested' but SF failed to start")
        logger.error(f"⚠️ Manual recovery required for manifest: {manifest_path}")
        
        return None
```

### Better Fix with Rollback Support
```python
# Modify create_manifests_if_ready to support rollback
# Lines 646-660

try:
    logger.debug(f"📝 Creating manifest {batch_idx}/{len(batches)}")
    manifest_path = _create_manifest(date_prefix, batch_idx, batch_files)

    if manifest_path:
        manifests_created += 1
        logger.info(f"✓ Manifest created: {manifest_path}")

        # Update file status FIRST
        _update_file_status(batch_files, 'manifested', manifest_path)
        logger.debug(f"✓ Updated {len(batch_files)} file statuses")

        # Trigger Step Functions with rollback support
        execution_arn = start_step_function(
            manifest_path, date_prefix, len(batch_files)
        )
        
        # ✅ If SF failed, rollback the status
        if not execution_arn:
            logger.warning(f"⚠️ Step Function start failed, rolling back file statuses")
            _update_file_status(batch_files, 'pending', None)
            # Don't count this manifest as created
            manifests_created -= 1

except Exception as e:
    logger.error(f"✗ Error creating manifest {batch_idx}: {str(e)}")
    logger.error(f"Traceback: {traceback.format_exc()}")
```

---

## Fix #5: Add Dead Letter Queue
**Time**: 1 hour  
**Impact**: Capture failed Lambda invocations for recovery  
**Risk Prevented**: Silent failures

### Terraform Changes
```hcl
# File: terraform/modules/lambda/main.tf

# Step 1: Create DLQ (add after line 87)
resource "aws_sqs_queue" "lambda_dlq" {
  name = "ndjson-parquet-lambda-dlq-${var.environment}"
  message_retention_seconds = 1209600  # 14 days

  tags = merge(
    var.tags,
    {
      Name        = "Lambda DLQ"
      Description = "Dead letter queue for failed Lambda invocations"
    }
  )
}

# Step 2: Add CloudWatch alarm for DLQ
resource "aws_cloudwatch_metric_alarm" "lambda_dlq_messages" {
  alarm_name          = "${var.environment}-Lambda-DLQ-Messages-CRITICAL"
  alarm_description   = "Alert when messages arrive in Lambda DLQ"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_sns_topic_arn]  # ✅ Configure this

  dimensions = {
    QueueName = aws_sqs_queue.lambda_dlq.name
  }

  tags = var.tags
}

# Step 3: Add DLQ to Lambda function (modify resource block)
resource "aws_lambda_function" "manifest_builder" {
  # ... existing config ...
  
  # ✅ ADD THIS BLOCK
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
  
  # ... rest of config ...
}

# Step 4: Add IAM permission for DLQ
resource "aws_iam_role_policy" "lambda_dlq" {
  name = "lambda-dlq-access"
  role = var.lambda_role_id  # Pass from IAM module

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage"
      ]
      Resource = aws_sqs_queue.lambda_dlq.arn
    }]
  })
}
```

### outputs.tf Addition
```hcl
# File: terraform/modules/lambda/outputs.tf

output "lambda_dlq_arn" {
  description = "Lambda Dead Letter Queue ARN"
  value       = aws_sqs_queue.lambda_dlq.arn
}

output "lambda_dlq_url" {
  description = "Lambda Dead Letter Queue URL"
  value       = aws_sqs_queue.lambda_dlq.url
}
```

---

## Fix #6: Fix IAM Wildcards
**Time**: 30 minutes  
**Impact**: Least privilege compliance  
**Risk Prevented**: Unauthorized resource access

### Current Code
```hcl
# File: terraform/modules/iam/main.tf

# Line 136 - Lambda Step Functions permission
Resource = "*"  # ❌ Can trigger ANY state machine

# Line 396 - Step Functions Glue permission
Resource = "*"  # ❌ Can start/stop ANY Glue job
```

### Fixed Code
```hcl
# Fix Line 136
# Step Functions permissions (to trigger workflow after manifest creation)
{
  Effect = "Allow"
  Action = [
    "states:StartExecution"
  ]
  Resource = var.step_function_arn  # ✅ Specific ARN
}

# Fix Line 396
# Glue permissions - Start and monitor jobs
{
  Effect = "Allow"
  Action = [
    "glue:StartJobRun",
    "glue:GetJobRun",
    "glue:GetJobRuns",
    "glue:BatchStopJobRun"
  ]
  Resource = var.glue_job_arn  # ✅ Specific ARN
}
```

### variables.tf Additions
```hcl
# File: terraform/modules/iam/variables.tf

variable "step_function_arn" {
  description = "Step Functions state machine ARN for Lambda to invoke"
  type        = string
}

variable "glue_job_arn" {
  description = "Glue job ARN for Step Functions to invoke"
  type        = string
}
```

### main.tf Changes (Root Module)
```hcl
# File: terraform/main.tf

module "iam" {
  source = "./modules/iam"

  # ... existing variables ...

  # ✅ Pass specific ARNs
  step_function_arn = module.step_functions.state_machine_arn
  glue_job_arn      = module.glue.job_arn

  tags = local.common_tags
}
```

---

## Fix #7: Add Glue Security Configuration
**Time**: 2 hours  
**Impact**: Encryption for CloudWatch logs and job bookmarks  
**Risk Prevented**: Compliance violation

### Terraform Implementation
```hcl
# File: terraform/modules/glue/main.tf

# Step 1: Create Glue Security Configuration (add before aws_glue_job)
resource "aws_glue_security_configuration" "etl_security" {
  name = "ndjson-parquet-security-${var.environment}"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn               = var.kms_key_arn
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

# Step 2: Attach to Glue Job
resource "aws_glue_job" "batch_processor" {
  name     = "ndjson-parquet-batch-job-${var.environment}"
  role_arn = var.glue_role_arn

  # ✅ ADD THIS LINE
  security_configuration = aws_glue_security_configuration.etl_security.name

  # ... rest of existing config ...
}
```

### variables.tf Addition
```hcl
# File: terraform/modules/glue/variables.tf

variable "kms_key_arn" {
  description = "KMS key ARN for Glue encryption"
  type        = string
  default     = ""  # Use default AWS managed key if not provided
}
```

### IAM Policy Addition
```hcl
# File: terraform/modules/iam/main.tf
# Add to Glue role policy

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

## Fix #8: Add COMPRESSION_TYPE Argument
**Time**: 5 minutes  
**Impact**: Explicit configuration instead of fallback  
**Risk Prevented**: Unexpected default behavior

### Terraform Fix
```hcl
# File: terraform/modules/glue/main.tf
# Lines 42-65: default_arguments block

default_arguments = {
  # ... existing arguments ...
  
  # ✅ ADD THIS LINE
  "--COMPRESSION_TYPE" = var.compression_type
}
```

### variables.tf Addition
```hcl
# File: terraform/modules/glue/variables.tf

variable "compression_type" {
  description = "Parquet compression codec"
  type        = string
  default     = "snappy"
  validation {
    condition     = contains(["snappy", "gzip", "lzo", "brotli", "lz4", "zstd"], var.compression_type)
    error_message = "compression_type must be a valid Parquet codec."
  }
}
```

---

## Fix #9: Add Alarm Actions to CloudWatch Alarms
**Time**: 30 minutes  
**Impact**: Enable actual alerting (alarms currently silent)  
**Risk Prevented**: Unnoticed failures

### Current State
```hcl
# File: terraform/modules/lambda/main.tf
# Lines 102-157: CloudWatch alarms

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  # ... config ...
  # ❌ NO alarm_actions - alarm is silent
}
```

### Fixed Code
```hcl
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.environment}-ManifestBuilder-Errors-WARNING"
  alarm_description   = "Alert when manifest builder has errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  # ✅ ADD THESE LINES
  alarm_actions = [var.alarm_sns_topic_arn]
  ok_actions    = [var.alarm_sns_topic_arn]  # Notify on recovery too

  dimensions = {
    FunctionName = aws_lambda_function.manifest_builder.function_name
  }

  tags = var.tags
}

# Apply to ALL alarms (lines 121-157)
```

### variables.tf Addition
```hcl
# File: terraform/modules/lambda/variables.tf

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
}
```

### Root Module Changes
```hcl
# File: terraform/main.tf

module "lambda" {
  source = "./modules/lambda"

  # ... existing variables ...

  # ✅ Pass SNS topic ARN from monitoring module
  alarm_sns_topic_arn = module.monitoring.sns_topic_arn

  depends_on = [module.iam, module.monitoring]
}
```

---

## Deployment Checklist

### Pre-Deployment
- [ ] Create feature branch: `git checkout -b phase1-critical-fixes`
- [ ] Run local Python linting: `pylint environments/dev/lambda/lambda_manifest_builder.py`
- [ ] Run Terraform validation: `terraform validate`
- [ ] Run Terraform plan: `terraform plan -out=phase1.tfplan`
- [ ] Review plan output for unexpected changes
- [ ] Backup current Lambda code: `aws lambda get-function --function-name ...`

### Deployment Steps
1. **Apply Lambda Code Changes**
   ```bash
   cd environments/dev/lambda
   zip lambda_manifest_builder.zip lambda_manifest_builder.py
   aws s3 cp lambda_manifest_builder.zip s3://scripts-bucket/lambda/dev/
   ```

2. **Apply Terraform Changes**
   ```bash
   cd terraform
   terraform apply phase1.tfplan
   ```

3. **Verify Deployment**
   ```bash
   # Check Lambda function updated
   aws lambda get-function --function-name ndjson-parquet-manifest-builder-dev \
     --query 'Configuration.LastModified'
   
   # Check environment variables
   aws lambda get-function-configuration \
     --function-name ndjson-parquet-manifest-builder-dev \
     --query 'Environment.Variables.LOG_LEVEL'
   ```

### Post-Deployment Testing
- [ ] Upload test file to S3
- [ ] Verify idempotency: upload same file again
- [ ] Check CloudWatch logs for INFO level (not DEBUG)
- [ ] Verify DLQ is empty
- [ ] Check alarm actions configured
- [ ] Test orphan file recovery

### Rollback Plan
```bash
# If issues occur, rollback Lambda code
aws lambda update-function-code \
  --function-name ndjson-parquet-manifest-builder-dev \
  --s3-bucket scripts-bucket \
  --s3-key lambda/dev/lambda_manifest_builder_backup.zip

# Rollback Terraform
terraform apply -var-file=previous_state.tfvars
```

---

## Success Metrics

After Phase 1 deployment, monitor these metrics:

| Metric | Target | How to Check |
|--------|--------|--------------|
| Idempotency errors | 0 | CloudWatch Logs: search "already tracked" |
| Lambda memory usage | < 50% | CloudWatch Metrics: MemoryUtilization |
| DEBUG logs in prod | 0 | CloudWatch Logs Insights: `fields @message \\| filter @message like /DEBUG/` |
| DLQ messages | 0 | SQS Console: ApproximateNumberOfMessages |
| Alarm notifications | Received | Check email/Slack for test alarm |
| Orphaned files | 0 | DynamoDB: query for status='manifested' with old timestamp |

---

*Proceed to Phase 2 after all Phase 1 metrics are green for 1 week.*
