# SQS/DLQ Implementation Verification

## ✅ CONFIRMED: SQS and DLQ are Required Components

This document verifies that SQS (Simple Queue Service) and DLQ (Dead Letter Queue) are fully implemented as **required** (not optional) components in the Terraform infrastructure.

---

## Implementation Summary

### 1. ✅ SQS Module is Always Deployed

**File:** [main.tf](./main.tf) (Lines 330-356)

```hcl
###############################################################################
# SQS Module
###############################################################################

module "sqs" {
  source = "./modules/sqs"  # ← NO count parameter, always deployed

  environment = var.environment

  # Queue configuration
  message_retention_seconds = var.sqs_message_retention_seconds
  visibility_timeout        = var.sqs_visibility_timeout
  max_receive_count         = var.sqs_max_receive_count
  batch_size                = var.sqs_batch_size

  # Lambda function for event source mapping
  lambda_function_arn = module.lambda.manifest_builder_function_arn

  # Enable encryption in production
  enable_encryption = var.environment == "prod"

  # Create alarms in production
  create_alarms = var.environment == "prod"

  tags = local.common_tags
}
```

**Status:** ✅ Module is unconditionally deployed (no `count` parameter)

---

### 2. ✅ Dead Letter Queue (DLQ) is Created

**File:** [modules/sqs/main.tf](./modules/sqs/main.tf) (Lines 23-37)

```hcl
###############################################################################
# Dead Letter Queue
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "ndjson-parquet-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(
    var.tags,
    {
      Name        = "Pipeline DLQ"
      Description = "Dead letter queue for failed file events"
    }
  )
}
```

**Status:** ✅ DLQ is always created with 14-day message retention

---

### 3. ✅ Main Queue with DLQ Configuration

**File:** [modules/sqs/main.tf](./modules/sqs/main.tf) (Lines 39-64)

```hcl
###############################################################################
# Main Queue
###############################################################################

resource "aws_sqs_queue" "main" {
  name                       = "ndjson-parquet-file-events-${var.environment}"
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20 # Enable long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn  # ← DLQ configured
    maxReceiveCount     = var.max_receive_count   # ← Default: 3 retries
  })

  # Enable encryption in production
  sqs_managed_sse_enabled = var.enable_encryption

  tags = merge(
    var.tags,
    {
      Name        = "Pipeline File Events Queue"
      Description = "Queue for NDJSON file processing events"
    }
  )
}
```

**Status:** ✅ Main queue automatically sends failed messages to DLQ after 3 retry attempts

---

### 4. ✅ S3 to SQS Integration

**File:** [modules/sqs/main.tf](./modules/sqs/main.tf) (Lines 66-94)

```hcl
###############################################################################
# Queue Policy (Allow S3 to Send Messages)
###############################################################################

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::ndjson-input-sqs-${account_id}-${environment}"
          }
        }
      }
    ]
  })
}
```

**Status:** ✅ S3 input bucket automatically sends notifications to SQS queue

---

### 5. ✅ SQS to Lambda Integration

**File:** [modules/sqs/main.tf](./modules/sqs/main.tf) (Lines 97-114)

```hcl
###############################################################################
# Lambda Event Source Mapping
###############################################################################

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = var.lambda_function_arn
  batch_size       = var.batch_size
  enabled          = true

  # Configure scaling
  scaling_config {
    maximum_concurrency = 50
  }

  # Configure failure handling
  function_response_types = ["ReportBatchItemFailures"]
}
```

**Status:** ✅ Lambda automatically polls SQS and processes messages in batches

---

### 6. ✅ IAM Permissions for SQS

**File:** [modules/iam/main.tf](./modules/iam/main.tf) (Lines 119-128)

```hcl
# SQS permissions
{
  Effect = "Allow"
  Action = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes"
  ]
  Resource = [var.sqs_queue_arn]  # ← Required, not optional
}
```

**File:** [modules/iam/variables.tf](./modules/iam/variables.tf) (Lines 45-48)

```hcl
variable "sqs_queue_arn" {
  description = "SQS queue ARN"
  type        = string
  # ← NO default = null, making it REQUIRED
}
```

**Status:** ✅ Lambda has required permissions to interact with SQS

---

### 7. ✅ CloudWatch Alarms for Monitoring

**File:** [modules/sqs/main.tf](./modules/sqs/main.tf) (Lines 116-178)

Three alarms are created (in production):

1. **Queue Depth Alarm** (Lines 120-138)
   - Triggers when queue has >1000 messages
   - Severity: WARNING

2. **Message Age Alarm** (Lines 140-158)
   - Triggers when messages are >1 hour old
   - Severity: WARNING

3. **DLQ Messages Alarm** (Lines 160-178)
   - Triggers when ANY message arrives in DLQ
   - Severity: CRITICAL

**Status:** ✅ Comprehensive monitoring for queue health and DLQ activity

---

### 8. ✅ Configuration Variables

**File:** [variables.tf](./variables.tf) (Lines 182-210)

```hcl
###############################################################################
# SQS Configuration
###############################################################################

variable "sqs_message_retention_seconds" {
  description = "SQS message retention period in seconds"
  type        = number
  default     = 345600 # 4 days
}

variable "sqs_visibility_timeout" {
  description = "SQS visibility timeout in seconds"
  type        = number
  default     = 360 # 6 minutes
}

variable "sqs_max_receive_count" {
  description = "Maximum receives before sending to DLQ"
  type        = number
  default     = 3
}

variable "sqs_batch_size" {
  description = "Lambda event source mapping batch size"
  type        = number
  default     = 10
}
```

**Notable:** The `enable_sqs` variable has been **removed** - SQS is no longer optional.

**Status:** ✅ All SQS configuration parameters are present and have sensible defaults

---

### 9. ✅ Outputs for Monitoring

**File:** [outputs.tf](./outputs.tf) (Lines 107-129)

```hcl
###############################################################################
# SQS Outputs
###############################################################################

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = module.sqs.queue_url  # ← Direct reference, not conditional
}

output "sqs_queue_name" {
  description = "SQS queue name"
  value       = module.sqs.queue_name
}

output "sqs_dlq_url" {
  description = "SQS DLQ URL"
  value       = module.sqs.dlq_url
}

output "sqs_dlq_name" {
  description = "SQS DLQ name"
  value       = module.sqs.dlq_name
}
```

**Status:** ✅ All SQS outputs are unconditional (no ternary operators)

---

## Architecture Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         NDJSON to Parquet Pipeline                      │
│                        with Required SQS/DLQ                             │
└─────────────────────────────────────────────────────────────────────────┘

Step 1: File Upload
┌─────────────┐
│  S3 Input   │  User uploads NDJSON file
│   Bucket    │
└──────┬──────┘
       │
       │ S3 Event Notification
       ▼

Step 2: Queue Message
┌─────────────┐
│     SQS     │  Message queued with 4-day retention
│ Main Queue  │  Visibility timeout: 6 minutes
└──────┬──────┘
       │
       │ Lambda polls queue (batch size: 10)
       ▼

Step 3: Process Message
┌─────────────┐
│   Lambda    │  Manifest Builder processes file
│  Function   │  ← Attempt 1
└──────┬──────┘
       │
       ├─ Success → Delete message from queue
       │
       └─ Failure → Message returns to queue
                    ↓
                    Attempt 2 (after visibility timeout)
                    ↓
                    Attempt 3 (after visibility timeout)
                    ↓
                    ❌ Still failing?

Step 4: Dead Letter Queue
┌─────────────┐
│  SQS DLQ    │  Failed message (after 3 attempts)
│             │  Retention: 14 days
└──────┬──────┘
       │
       │ CloudWatch Alarm: CRITICAL
       ▼
┌─────────────┐
│ SNS Alert   │  Email notification sent
└─────────────┘

Step 5: Successful Processing
┌─────────────┐
│ S3 Manifest │  Manifest file created
│   Bucket    │
└──────┬──────┘
       │
       │ EventBridge trigger
       ▼
┌─────────────┐
│  Glue Job   │  Batch processing
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ S3 Output   │  Parquet files
│   Bucket    │
└─────────────┘
```

---

## Retry Logic

### Message Processing Flow:

```
Message arrives in SQS Main Queue
         ↓
Lambda Attempt 1
         ↓
    [Success?]
    ↙       ↘
  YES        NO
   ↓          ↓
Delete    Return to queue
message   (invisible for 6 min)
   ↓          ↓
 Done    Lambda Attempt 2
              ↓
         [Success?]
         ↙       ↘
       YES        NO
        ↓          ↓
     Delete    Return to queue
     message   (invisible for 6 min)
        ↓          ↓
      Done    Lambda Attempt 3
                   ↓
              [Success?]
              ↙       ↘
            YES        NO
             ↓          ↓
          Delete    Move to DLQ
          message   + Trigger CRITICAL alarm
             ↓          ↓
           Done    Manual investigation needed
```

---

## Configuration Examples

### Development Environment

**File:** [terraform.tfvars.dev.example](./terraform.tfvars.dev.example)

```hcl
# SQS Configuration
sqs_message_retention_seconds = 345600  # 4 days
sqs_visibility_timeout        = 360     # 6 minutes
sqs_max_receive_count         = 3       # 3 retries before DLQ
sqs_batch_size                = 10      # Process 10 messages at a time
```

### Production Environment

**File:** [terraform.tfvars.prod.example](./terraform.tfvars.prod.example)

```hcl
# SQS Configuration
sqs_message_retention_seconds = 345600  # 4 days
sqs_visibility_timeout        = 600     # 10 minutes (longer for prod)
sqs_max_receive_count         = 3       # 3 retries before DLQ
sqs_batch_size                = 10      # Process 10 messages at a time
```

---

## Benefits of This Implementation

### ✅ Reliability
- **3 automatic retries** before giving up
- **14-day DLQ retention** for failed message investigation
- **No message loss** - everything is persisted

### ✅ Scalability
- **Long polling** reduces API calls and costs
- **Batch processing** (10 messages at a time) improves throughput
- **Concurrent execution** (up to 50) handles high volume

### ✅ Observability
- **3 CloudWatch alarms** for queue monitoring
- **Queue depth tracking** prevents backlog
- **Message age monitoring** detects processing delays
- **DLQ alerts** for immediate failure notification

### ✅ Cost Efficiency
- **4-day retention** balances durability with storage costs
- **Long polling** reduces empty receive charges
- **Batch processing** reduces Lambda invocations

---

## Deployment Verification

After deploying with Terraform, verify SQS/DLQ are working:

### 1. Check Resources Created

```bash
# Verify SQS queues
terraform output sqs_queue_url
terraform output sqs_dlq_url

# List queues in AWS
aws sqs list-queues | grep ndjson-parquet
```

**Expected Output:**
```
ndjson-parquet-file-events-dev
ndjson-parquet-dlq-dev
```

### 2. Verify Lambda Event Source Mapping

```bash
# Check Lambda is connected to SQS
aws lambda list-event-source-mappings \
  --function-name ndjson-parquet-manifest-builder-dev
```

**Expected Output:**
```json
{
  "EventSourceArn": "arn:aws:sqs:us-east-1:123456789012:ndjson-parquet-file-events-dev",
  "State": "Enabled",
  "BatchSize": 10
}
```

### 3. Test Message Flow

```bash
# Upload a test file to S3
echo '{"test": "data"}' > test.ndjson
aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/

# Check SQS queue for message
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages

# Monitor Lambda logs
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow
```

### 4. Verify DLQ is Empty

```bash
# DLQ should have 0 messages (if everything is working)
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --attribute-names ApproximateNumberOfMessages
```

**Expected Output:**
```json
{
  "ApproximateNumberOfMessages": "0"
}
```

---

## Troubleshooting

### Issue: Messages stuck in main queue

**Check:**
```bash
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names All
```

**Common causes:**
- Lambda function has errors (check CloudWatch Logs)
- Lambda execution role missing SQS permissions
- Lambda concurrency limit reached

### Issue: Messages in DLQ

**Check DLQ:**
```bash
aws sqs receive-message \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --max-number-of-messages 1
```

**Action:**
- Investigate why message failed (check Lambda logs)
- Fix the issue
- Replay message from DLQ to main queue if needed

### Issue: No messages in queue after S3 upload

**Check S3 event notification:**
```bash
aws s3api get-bucket-notification-configuration \
  --bucket $(terraform output -raw input_bucket_name)
```

**Verify:**
- S3 bucket has SQS notification configured
- SQS queue policy allows S3 to send messages

---

## Summary

✅ **SQS Main Queue**: Always created, 4-day retention
✅ **DLQ**: Always created, 14-day retention
✅ **Redrive Policy**: Automatic after 3 failed attempts
✅ **Lambda Integration**: Event source mapping always enabled
✅ **IAM Permissions**: Required permissions always granted
✅ **Monitoring**: 3 CloudWatch alarms in production
✅ **S3 Integration**: Automatic notifications to SQS
✅ **No Optional Flag**: `enable_sqs` variable removed

**Result:** SQS and DLQ are **fully implemented and required** in all deployments.

---

## Additional Resources

- [AWS SQS Documentation](https://docs.aws.amazon.com/sqs/)
- [Lambda Event Source Mappings](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html)
- [SQS Dead Letter Queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)
- [Terraform AWS SQS Module](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue)

For more details, see:
- [SQS-REQUIRED-UPDATE.md](./SQS-REQUIRED-UPDATE.md) - Migration guide
- [README.md](./README.md) - Complete Terraform documentation
