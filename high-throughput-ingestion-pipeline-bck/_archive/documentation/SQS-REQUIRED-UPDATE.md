# SQS/DLQ Now Required - Update Summary

## Overview

The Terraform configuration has been updated to make SQS (Simple Queue Service) and DLQ (Dead Letter Queue) **required components** instead of optional. This ensures enhanced reliability for all deployments.

## Changes Made

### 1. Root Module ([main.tf](./main.tf))

**Before:**
```hcl
# SQS Module (Optional)
module "sqs" {
  count  = var.enable_sqs ? 1 : 0
  source = "./modules/sqs"
  ...
}

# IAM Module
sqs_queue_arn = var.enable_sqs ? module.sqs[0].queue_arn : null
```

**After:**
```hcl
# SQS Module
module "sqs" {
  source = "./modules/sqs"
  ...
}

# IAM Module
sqs_queue_arn = module.sqs.queue_arn
```

### 2. Variables ([variables.tf](./variables.tf))

**Removed:**
```hcl
variable "enable_sqs" {
  description = "Enable SQS for file events (alternative to direct S3 trigger)"
  type        = bool
  default     = false
}
```

The `enable_sqs` variable has been completely removed. SQS is now always deployed.

### 3. Outputs ([outputs.tf](./outputs.tf))

**Before:**
```hcl
output "sqs_queue_url" {
  description = "SQS queue URL (if enabled)"
  value       = var.enable_sqs ? module.sqs[0].queue_url : "N/A (SQS not enabled)"
}

output "sqs_dlq_url" {
  description = "SQS DLQ URL (if enabled)"
  value       = var.enable_sqs ? module.sqs[0].dlq_url : "N/A (SQS not enabled)"
}
```

**After:**
```hcl
output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = module.sqs.queue_url
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

### 4. IAM Module ([modules/iam/main.tf](./modules/iam/main.tf))

**Before:**
```hcl
variable "sqs_queue_arn" {
  description = "SQS queue ARN (optional)"
  type        = string
  default     = null
}

# In policy
Resource = var.sqs_queue_arn != null ? [var.sqs_queue_arn] : []
```

**After:**
```hcl
variable "sqs_queue_arn" {
  description = "SQS queue ARN"
  type        = string
}

# In policy
Resource = [var.sqs_queue_arn]
```

### 5. Example Configuration Files

**[terraform.tfvars.dev.example](./terraform.tfvars.dev.example):**
```hcl
# Before
enable_sqs = false

# After (enable_sqs removed)
# SQS Configuration
sqs_message_retention_seconds = 345600
sqs_visibility_timeout        = 360
sqs_max_receive_count         = 3
sqs_batch_size                = 10
```

**[terraform.tfvars.prod.example](./terraform.tfvars.prod.example):**
```hcl
# Before
enable_sqs = true

# After (enable_sqs removed)
# SQS Configuration
sqs_message_retention_seconds = 345600
sqs_visibility_timeout        = 600
sqs_max_receive_count         = 3
sqs_batch_size                = 10
```

### 6. Module Documentation

**[modules/sqs/main.tf](./modules/sqs/main.tf):**
- Updated header from "SQS Module (Optional)" to "SQS Module"
- Removed note about being optional

**[README.md](./README.md):**
- Updated architecture description to list "SQS/DLQ" as standard component
- Removed "When to use S3 Direct" section
- Updated SQS section to focus on configuration rather than enabling

## Why This Change?

### Benefits of Required SQS

1. **Enhanced Reliability**: Dead Letter Queue ensures no messages are lost
2. **Better Error Handling**: Failed messages are automatically retried 3 times
3. **Throttle Protection**: Protects Lambda from being overwhelmed
4. **Visibility**: Easy monitoring of queue depth and message age
5. **Consistency**: Same architecture across all environments

### Cost Impact

**Additional Cost per Month:**
- **Development**: ~$0.50 (low volume)
- **Production**: ~$4.00 (338K files/day)

The cost is minimal compared to the reliability benefits.

## Migration Guide

### For New Deployments

No action needed - SQS will be created automatically.

### For Existing Deployments

#### If You Previously Had `enable_sqs = false`:

1. **Update your terraform.tfvars:**
   ```hcl
   # Remove this line
   # enable_sqs = false

   # Add SQS configuration (if not present)
   sqs_message_retention_seconds = 345600
   sqs_visibility_timeout        = 360
   sqs_max_receive_count         = 3
   sqs_batch_size                = 10
   ```

2. **Run Terraform plan:**
   ```bash
   terraform plan
   ```

   You will see new resources to be created:
   - `module.sqs.aws_sqs_queue.main`
   - `module.sqs.aws_sqs_queue.dlq`
   - `module.sqs.aws_lambda_event_source_mapping.sqs_to_lambda`
   - CloudWatch alarms for SQS

3. **Apply changes:**
   ```bash
   terraform apply
   ```

4. **Verify deployment:**
   ```bash
   # Check SQS queues
   aws sqs list-queues

   # Get queue URLs
   terraform output sqs_queue_url
   terraform output sqs_dlq_url
   ```

#### If You Previously Had `enable_sqs = true`:

1. **Update your terraform.tfvars:**
   ```hcl
   # Remove this line
   # enable_sqs = true

   # Keep SQS configuration (already present)
   sqs_message_retention_seconds = 345600
   sqs_visibility_timeout        = 600
   sqs_max_receive_count         = 3
   sqs_batch_size                = 10
   ```

2. **Update Terraform state:**
   ```bash
   # Remove the count index from state
   terraform state mv 'module.sqs[0].aws_sqs_queue.main' 'module.sqs.aws_sqs_queue.main'
   terraform state mv 'module.sqs[0].aws_sqs_queue.dlq' 'module.sqs.aws_sqs_queue.dlq'
   terraform state mv 'module.sqs[0].aws_lambda_event_source_mapping.sqs_to_lambda' 'module.sqs.aws_lambda_event_source_mapping.sqs_to_lambda'
   terraform state mv 'module.sqs[0].aws_sqs_queue_policy.main' 'module.sqs.aws_sqs_queue_policy.main'

   # Move alarms (if you had create_alarms = true)
   terraform state mv 'module.sqs[0].aws_cloudwatch_metric_alarm.queue_depth[0]' 'module.sqs.aws_cloudwatch_metric_alarm.queue_depth[0]'
   terraform state mv 'module.sqs[0].aws_cloudwatch_metric_alarm.message_age[0]' 'module.sqs.aws_cloudwatch_metric_alarm.message_age[0]'
   terraform state mv 'module.sqs[0].aws_cloudwatch_metric_alarm.dlq_messages[0]' 'module.sqs.aws_cloudwatch_metric_alarm.dlq_messages[0]'
   ```

3. **Verify no changes needed:**
   ```bash
   terraform plan
   # Should show no changes or only minor updates
   ```

## Updated Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌────────────┐
│  S3 Input   │────▶│     SQS      │────▶│   Lambda     │────▶│ S3 Manifest│
│   Bucket    │     │ Main Queue   │     │  (Manifest   │     │   Bucket   │
│             │     │   + DLQ      │     │   Builder)   │     │            │
└─────────────┘     └──────────────┘     └──────────────┘     └────────────┘
                                                 │                     │
                                                 ▼                     ▼
                                         ┌──────────────┐     ┌──────────────┐
                                         │  DynamoDB    │     │  Glue Job    │
                                         │  File Track  │     │  (Batch      │
                                         └──────────────┘     │  Processing) │
                                                              └──────────────┘
                                                                     │
                                                                     ▼
                                                              ┌────────────┐
                                                              │ S3 Output  │
                                                              │  Bucket    │
                                                              └────────────┘
```

## Files Modified

1. ✅ [terraform/main.tf](./main.tf)
2. ✅ [terraform/variables.tf](./variables.tf)
3. ✅ [terraform/outputs.tf](./outputs.tf)
4. ✅ [terraform/terraform.tfvars.dev.example](./terraform.tfvars.dev.example)
5. ✅ [terraform/terraform.tfvars.prod.example](./terraform.tfvars.prod.example)
6. ✅ [terraform/modules/iam/main.tf](./modules/iam/main.tf)
7. ✅ [terraform/modules/iam/variables.tf](./modules/iam/variables.tf)
8. ✅ [terraform/modules/sqs/main.tf](./modules/sqs/main.tf)
9. ✅ [terraform/README.md](./README.md)

## Testing

After applying the changes, test the pipeline:

1. **Upload a test file:**
   ```bash
   aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/
   ```

2. **Check SQS queue:**
   ```bash
   aws sqs get-queue-attributes \
     --queue-url $(terraform output -raw sqs_queue_url) \
     --attribute-names ApproximateNumberOfMessages
   ```

3. **Monitor Lambda execution:**
   ```bash
   aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-${ENVIRONMENT} --follow
   ```

4. **Check for DLQ messages (should be empty):**
   ```bash
   aws sqs get-queue-attributes \
     --queue-url $(terraform output -raw sqs_dlq_url) \
     --attribute-names ApproximateNumberOfMessages
   ```

## Rollback Plan

If you need to rollback to optional SQS (not recommended):

```bash
# Restore from git
git checkout HEAD~1 terraform/

# Or manually restore the enable_sqs variable and conditional logic
```

## Questions?

For issues or questions about this update, please refer to:
- [README.md](./README.md) - Complete documentation
- [Troubleshooting section](./README.md#troubleshooting) - Common issues
- CloudWatch logs for debugging

## Summary

✅ SQS and DLQ are now **required** for all deployments
✅ Enhanced reliability and error handling for all environments
✅ Minimal cost increase (~$4/month for production)
✅ Simpler configuration (removed enable_sqs flag)
✅ Consistent architecture across dev and prod

**Action Required**: Update your `terraform.tfvars` file to remove the `enable_sqs` variable before your next `terraform apply`.
