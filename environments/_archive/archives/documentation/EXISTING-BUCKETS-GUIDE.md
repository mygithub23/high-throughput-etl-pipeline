# Using Existing S3 Buckets Guide

## Overview

The Terraform configuration now supports using **existing S3 buckets** for both the input and output buckets, while still creating the required infrastructure buckets (manifest, quarantine, and scripts).

This is useful when:
- You already have S3 buckets for input/output in your project
- You want to maintain existing bucket configurations
- You need to integrate with existing data workflows

## Configuration Options

### Option 1: Use Existing Input and Output Buckets (Recommended for Your Project)

Since your project already has existing input and output buckets, configure Terraform to use them:

**File:** `terraform.tfvars`

```hcl
environment = "dev"
aws_region  = "us-east-1"

# S3 Configuration - Use existing buckets
create_input_bucket          = false
existing_input_bucket_name   = "my-existing-input-bucket"
create_output_bucket         = false
existing_output_bucket_name  = "my-existing-output-bucket"

# Rest of configuration...
```

### Option 2: Create All New Buckets

If you want Terraform to create all buckets (default behavior):

```hcl
environment = "dev"
aws_region  = "us-east-1"

# S3 Configuration - Create new buckets
create_input_bucket  = true
create_output_bucket = true

# Lifecycle policies will be applied to new buckets
input_lifecycle_days = 7
```

### Option 3: Mix of Existing and New Buckets

You can use an existing bucket for one and create a new one for the other:

```hcl
# Use existing input bucket, create new output bucket
create_input_bucket          = false
existing_input_bucket_name   = "my-existing-input-bucket"
create_output_bucket         = true  # Will create new output bucket
```

## What Gets Created vs What's Reused

### Always Created by Terraform:
1. ✅ **Manifest Bucket** - Stores batch manifest files
2. ✅ **Quarantine Bucket** - Stores problematic files
3. ✅ **Scripts Bucket** - Stores Lambda and Glue code

### Optional (Can Use Existing):
- 🔄 **Input Bucket** - Receives NDJSON files
- 🔄 **Output Bucket** - Stores converted Parquet files

## Detailed Configuration

### Variables Reference

#### Root Module Variables ([variables.tf](./variables.tf))

```hcl
variable "create_input_bucket" {
  description = "Whether to create input bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_input_bucket_name" {
  description = "Name of existing input bucket (only used if create_input_bucket = false)"
  type        = string
  default     = ""
}

variable "create_output_bucket" {
  description = "Whether to create output bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_output_bucket_name" {
  description = "Name of existing output bucket (only used if create_output_bucket = false)"
  type        = string
  default     = ""
}
```

## Step-by-Step Setup

### Step 1: Identify Your Existing Buckets

List your existing S3 buckets:

```bash
aws s3 ls
```

Example output:
```
2025-01-01 10:00:00 my-ndjson-input-bucket
2025-01-01 10:00:00 my-parquet-output-bucket
```

### Step 2: Update terraform.tfvars

Copy the example file and customize:

```bash
cp terraform.tfvars.dev.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
environment = "dev"
aws_region  = "us-east-1"

# Use your existing buckets
create_input_bucket          = false
existing_input_bucket_name   = "my-ndjson-input-bucket"
create_output_bucket         = false
existing_output_bucket_name  = "my-parquet-output-bucket"

# DynamoDB Configuration
dynamodb_read_capacity  = 5
dynamodb_write_capacity = 5

# Lambda Configuration
lambda_manifest_memory      = 512
lambda_manifest_timeout     = 180
lambda_manifest_concurrency = 10

# Glue Configuration
glue_worker_type        = "G.1X"
glue_number_of_workers  = 10
glue_max_concurrent_runs = 5

# Monitoring
alert_email = "your-email@example.com"

# SQS Configuration
sqs_message_retention_seconds = 345600
sqs_visibility_timeout        = 360
sqs_max_receive_count         = 3
sqs_batch_size                = 10
```

### Step 3: Verify Configuration

Check what Terraform will do:

```bash
terraform init
terraform plan
```

Look for these lines in the output:
```
# module.s3.data.aws_s3_bucket.existing_input[0] will be read during apply
# module.s3.data.aws_s3_bucket.existing_output[0] will be read during apply

# module.s3.aws_s3_bucket.manifest will be created
# module.s3.aws_s3_bucket.quarantine will be created
# module.s3.aws_s3_bucket.scripts will be created
```

**Important:** You should NOT see:
- `aws_s3_bucket.input will be created` (if using existing input bucket)
- `aws_s3_bucket.output will be created` (if using existing output bucket)

### Step 4: Deploy Infrastructure

```bash
terraform apply
```

## Architecture with Existing Buckets

```
┌─────────────────────┐
│  Existing S3 Input  │  ← Your existing bucket (not created by Terraform)
│      Bucket         │
└──────────┬──────────┘
           │
           │ S3 Event → SQS → Lambda
           ▼
┌─────────────────────┐
│    SQS + DLQ        │  ← Created by Terraform
│  (Main + Dead       │
│   Letter Queue)     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Lambda Function   │  ← Created by Terraform
│ (Manifest Builder)  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  S3 Manifest Bucket │  ← Created by Terraform
└──────────┬──────────┘
           │
           │ EventBridge trigger
           ▼
┌─────────────────────┐
│     Glue Job        │  ← Created by Terraform
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Existing S3 Output  │  ← Your existing bucket (not created by Terraform)
│      Bucket         │
└─────────────────────┘

Also Created by Terraform:
┌─────────────────────┐
│  S3 Quarantine      │  ← For failed files
│      Bucket         │
└─────────────────────┘

┌─────────────────────┐
│   S3 Scripts        │  ← For Lambda/Glue code
│      Bucket         │
└─────────────────────┘

┌─────────────────────┐
│  DynamoDB Tables    │  ← File tracking + metrics
└─────────────────────┘

┌─────────────────────┐
│  CloudWatch+SNS     │  ← Monitoring + alerts
└─────────────────────┘
```

## Important Considerations

### Permissions

When using existing buckets, ensure they have the necessary permissions:

1. **Input Bucket Requirements:**
   - Lambda must have `s3:GetObject` permission
   - S3 must be able to send events to SQS
   - SQS must be able to receive messages from S3

2. **Output Bucket Requirements:**
   - Glue job must have `s3:PutObject` permission
   - Glue job must have `s3:DeleteObject` permission (for overwrites)

### Bucket Policies

The existing buckets should allow:

**Input Bucket Policy Example:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "s3.amazonaws.com"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::my-existing-input-bucket",
        "arn:aws:s3:::my-existing-input-bucket/*"
      ]
    }
  ]
}
```

**Note:** Terraform will configure the IAM roles automatically to access these buckets.

### Event Notifications

**Important:** S3 buckets can only have one event notification configuration at a time.

If your existing input bucket already has event notifications configured, you have two options:

#### Option A: Let Terraform Manage Notifications (Recommended)
Remove existing event notifications and let Terraform configure them:

```bash
# Remove existing notifications
aws s3api put-bucket-notification-configuration \
  --bucket my-existing-input-bucket \
  --notification-configuration '{}'

# Then run Terraform
terraform apply
```

#### Option B: Manually Configure Notifications
Set `create_input_bucket = true` to avoid conflicts, or manually configure S3 to send events to the SQS queue created by Terraform.

### Lifecycle Policies

Lifecycle policies (`input_lifecycle_days`) **only apply to newly created buckets**.

If using existing buckets:
- Terraform will NOT modify existing lifecycle policies
- Manage lifecycle policies manually or through existing automation

### Versioning

Versioning settings **only apply to newly created buckets**.

If using existing buckets:
- Existing versioning settings are preserved
- Terraform will NOT enable/disable versioning on existing buckets

## Outputs

Terraform outputs will work regardless of whether buckets are created or existing:

```bash
# Get bucket names
terraform output input_bucket_name
terraform output output_bucket_name

# Get bucket ARNs
terraform output -json | jq -r '.input_bucket_arn.value'
```

## Migration Scenarios

### Scenario 1: Migrating from Existing Infrastructure

You already have input/output buckets with data:

```hcl
# Use existing buckets to preserve data
create_input_bucket  = false
existing_input_bucket_name = "production-ndjson-input"
create_output_bucket = false
existing_output_bucket_name = "production-parquet-output"
```

### Scenario 2: Gradual Migration

Start with existing buckets, then migrate to Terraform-managed buckets later:

**Phase 1: Use existing**
```hcl
create_input_bucket = false
existing_input_bucket_name = "old-input-bucket"
```

**Phase 2: Migrate data, then switch**
```bash
# Copy data to new bucket
aws s3 sync s3://old-input-bucket s3://new-input-bucket

# Update terraform.tfvars
create_input_bucket = true
# existing_input_bucket_name = ""  # Remove or comment out
```

**Phase 3: Apply changes**
```bash
terraform apply
```

## Troubleshooting

### Error: Bucket does not exist

```
Error: reading S3 Bucket (my-bucket): NotFound: Not Found
```

**Solution:** Check the bucket name is correct and exists in the same region:

```bash
aws s3 ls s3://my-bucket --region us-east-1
```

### Error: Access Denied

```
Error: AccessDenied: Access Denied
```

**Solution:** Ensure your AWS credentials have permission to read bucket information:

```bash
aws s3api head-bucket --bucket my-bucket
```

### Error: Bucket already has event notification

```
Error: InvalidArgument: Unable to validate the following destination configurations
```

**Solution:** Remove existing event notifications (see "Event Notifications" section above).

### Terraform Wants to Replace Bucket

If Terraform shows it wants to replace your existing bucket:

```
# module.s3.aws_s3_bucket.input must be replaced
```

**This should NOT happen** if `create_input_bucket = false`. Double-check your configuration.

## Verification Steps

After deployment, verify everything is connected:

### 1. Check Buckets

```bash
# List all buckets
aws s3 ls

# Should see:
# - Your existing input bucket
# - Your existing output bucket
# - New manifest bucket (ndjson-manifest-sqs-*)
# - New quarantine bucket (ndjson-quarantine-sqs-*)
# - New scripts bucket (ndjson-glue-scripts-*)
```

### 2. Check SQS Configuration

```bash
# Get SQS queue URL
terraform output sqs_queue_url

# Verify SQS can receive from S3
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names Policy
```

### 3. Test End-to-End

```bash
# Upload test file to existing input bucket
echo '{"test":"data"}' > test.ndjson
aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/

# Check SQS received message
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages

# Monitor Lambda execution
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow

# Check manifest was created
aws s3 ls s3://$(terraform output -raw manifest_bucket_name)/

# Verify Parquet output (after Glue job completes)
aws s3 ls s3://$(terraform output -raw output_bucket_name)/parquet/
```

## Best Practices

1. **Document Existing Buckets**: Keep a record of which buckets are managed by Terraform vs existing
2. **Use Tags**: Tag existing buckets to indicate they're used by this pipeline
3. **Backup Before Migration**: If migrating from existing to new buckets, backup data first
4. **Test in Dev First**: Always test with existing dev buckets before using production buckets
5. **Monitor Permissions**: Regularly verify IAM roles have correct permissions to existing buckets

## Summary

✅ **Input Bucket**: Optional - can use existing
✅ **Output Bucket**: Optional - can use existing
✅ **Manifest Bucket**: Always created by Terraform
✅ **Quarantine Bucket**: Always created by Terraform
✅ **Scripts Bucket**: Always created by Terraform
✅ **IAM Roles**: Automatically configured for existing buckets
✅ **Event Notifications**: Configured by Terraform (ensure no conflicts)
✅ **Outputs**: Work seamlessly with both created and existing buckets

For more information, see:
- [README.md](./README.md) - Complete Terraform documentation
- [variables.tf](./variables.tf) - All configuration variables
- [SQS-IMPLEMENTATION-VERIFICATION.md](./SQS-IMPLEMENTATION-VERIFICATION.md) - SQS/DLQ implementation details
