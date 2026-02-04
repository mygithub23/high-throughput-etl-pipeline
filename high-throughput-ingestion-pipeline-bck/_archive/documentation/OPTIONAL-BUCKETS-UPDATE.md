# Optional S3 Buckets Update Summary

## Overview

The Terraform configuration has been updated to support **using existing S3 buckets** for input and output, while still creating the necessary infrastructure buckets (manifest, quarantine, scripts).

## What Changed

### ✅ Input and Output Buckets are Now Optional

You can now choose to:
1. **Use existing buckets** (set `create_input_bucket = false` / `create_output_bucket = false`)
2. **Create new buckets** (set `create_input_bucket = true` / `create_output_bucket = true`) - default behavior

### 🔧 Always Created Buckets

These buckets are **always created** by Terraform:
- **Manifest Bucket** - Stores batch manifest files
- **Quarantine Bucket** - Stores problematic files
- **Scripts Bucket** - Stores Lambda and Glue code

## Files Modified

### 1. S3 Module

#### [terraform/modules/s3/variables.tf](./modules/s3/variables.tf)
Added 4 new variables:
```hcl
variable "create_input_bucket" {
  description = "Whether to create input bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "input_bucket_name" {
  description = "Name of existing input bucket (only used if create_input_bucket = false)"
  type        = string
  default     = ""
}

variable "create_output_bucket" {
  description = "Whether to create output bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "output_bucket_name" {
  description = "Name of existing output bucket (only used if create_output_bucket = false)"
  type        = string
  default     = ""
}
```

#### [terraform/modules/s3/main.tf](./modules/s3/main.tf)
- Added data sources to read existing buckets
- Made input/output bucket resources conditional (using `count`)
- Updated all related resources (versioning, lifecycle, encryption, etc.) to be conditional

**Key Changes:**
```hcl
# Data sources for existing buckets
data "aws_s3_bucket" "existing_input" {
  count  = var.create_input_bucket ? 0 : 1
  bucket = var.input_bucket_name
}

data "aws_s3_bucket" "existing_output" {
  count  = var.create_output_bucket ? 0 : 1
  bucket = var.output_bucket_name
}

# Conditional bucket creation
resource "aws_s3_bucket" "input" {
  count  = var.create_input_bucket ? 1 : 0
  bucket = var.input_bucket_name != "" ? var.input_bucket_name : "${local.bucket_prefix}-input-sqs-${var.account_id}-${var.environment}"
  ...
}

resource "aws_s3_bucket" "output" {
  count  = var.create_output_bucket ? 1 : 0
  bucket = var.output_bucket_name != "" ? var.output_bucket_name : "${local.bucket_prefix}-output-sqs-${var.account_id}-${var.environment}"
  ...
}
```

#### [terraform/modules/s3/outputs.tf](./modules/s3/outputs.tf)
Updated outputs to work with both created and existing buckets:
```hcl
output "input_bucket_name" {
  description = "Input bucket name"
  value       = var.create_input_bucket ? aws_s3_bucket.input[0].bucket : data.aws_s3_bucket.existing_input[0].bucket
}

output "output_bucket_name" {
  description = "Output bucket name"
  value       = var.create_output_bucket ? aws_s3_bucket.output[0].bucket : data.aws_s3_bucket.existing_output[0].bucket
}
```

### 2. Root Module

#### [terraform/variables.tf](./variables.tf)
Added 4 new root-level variables:
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

#### [terraform/main.tf](./main.tf)
Updated S3 module invocation to pass new variables:
```hcl
module "s3" {
  source = "./modules/s3"

  environment = var.environment
  account_id  = local.account_id

  # Optional bucket creation
  create_input_bucket  = var.create_input_bucket
  input_bucket_name    = var.existing_input_bucket_name
  create_output_bucket = var.create_output_bucket
  output_bucket_name   = var.existing_output_bucket_name

  # ... rest of configuration
}
```

### 3. Example Configuration Files

#### [terraform/terraform.tfvars.dev.example](./terraform.tfvars.dev.example)
```hcl
# S3 Configuration
# Set to false and provide bucket names if using existing buckets
create_input_bucket          = false  # Using existing bucket
existing_input_bucket_name   = "your-existing-input-bucket-name"
create_output_bucket         = false  # Using existing bucket
existing_output_bucket_name  = "your-existing-output-bucket-name"
```

#### [terraform/terraform.tfvars.prod.example](./terraform.tfvars.prod.example)
Same configuration as dev example.

### 4. Documentation

#### [terraform/EXISTING-BUCKETS-GUIDE.md](./EXISTING-BUCKETS-GUIDE.md) *(NEW)*
Comprehensive guide covering:
- Configuration options
- Step-by-step setup
- Architecture diagrams
- Important considerations (permissions, event notifications, lifecycle policies)
- Migration scenarios
- Troubleshooting
- Verification steps
- Best practices

#### [terraform/README.md](./README.md)
Added section on S3 bucket configuration with link to detailed guide.

## Usage Examples

### Example 1: Use Existing Buckets (Your Scenario)

**File:** `terraform.tfvars`
```hcl
environment = "dev"

# Use your existing buckets
create_input_bucket          = false
existing_input_bucket_name   = "my-project-input-bucket"
create_output_bucket         = false
existing_output_bucket_name  = "my-project-output-bucket"

# Rest of configuration...
```

**What Terraform Will Do:**
- ✅ Read existing input bucket
- ✅ Read existing output bucket
- ✅ Create manifest bucket
- ✅ Create quarantine bucket
- ✅ Create scripts bucket
- ✅ Create all Lambda functions with access to existing buckets
- ✅ Create Glue job with access to existing buckets
- ✅ Configure SQS to receive events from existing input bucket

### Example 2: Create All New Buckets (Default)

**File:** `terraform.tfvars`
```hcl
environment = "dev"

# Create all new buckets (can omit these as they default to true)
create_input_bucket  = true
create_output_bucket = true

# Rest of configuration...
```

**What Terraform Will Do:**
- ✅ Create new input bucket
- ✅ Create new output bucket
- ✅ Create manifest bucket
- ✅ Create quarantine bucket
- ✅ Create scripts bucket
- ✅ Apply lifecycle policies to input bucket

### Example 3: Mixed Approach

```hcl
# Use existing input bucket, create new output bucket
create_input_bucket          = false
existing_input_bucket_name   = "legacy-input-bucket"
create_output_bucket         = true  # Will create new output bucket
```

## Deployment Steps

### Step 1: Update Configuration

Edit your `terraform.tfvars`:

```hcl
create_input_bucket          = false
existing_input_bucket_name   = "your-actual-input-bucket-name"
create_output_bucket         = false
existing_output_bucket_name  = "your-actual-output-bucket-name"
```

### Step 2: Initialize and Plan

```bash
cd terraform
terraform init
terraform plan
```

**Verify the plan shows:**
- `data.aws_s3_bucket.existing_input[0] will be read`
- `data.aws_s3_bucket.existing_output[0] will be read`
- `aws_s3_bucket.manifest will be created`
- `aws_s3_bucket.quarantine will be created`
- `aws_s3_bucket.scripts will be created`

**Should NOT show:**
- `aws_s3_bucket.input will be created` (if using existing)
- `aws_s3_bucket.output will be created` (if using existing)

### Step 3: Apply Changes

```bash
terraform apply
```

### Step 4: Verify

```bash
# Check outputs work correctly
terraform output input_bucket_name
terraform output output_bucket_name

# Verify SQS queue was created
terraform output sqs_queue_url

# Test end-to-end
echo '{"test": "data"}' > test.ndjson
aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/
```

## Important Considerations

### 1. S3 Event Notifications

⚠️ **Critical:** S3 buckets can only have ONE event notification configuration.

If your existing input bucket already has event notifications:
- Remove existing notifications before running Terraform
- Or manually configure notifications to send to Terraform-created SQS queue

```bash
# Remove existing notifications
aws s3api put-bucket-notification-configuration \
  --bucket your-existing-input-bucket \
  --notification-configuration '{}'
```

### 2. IAM Permissions

Terraform automatically configures IAM roles to access existing buckets:
- Lambda role gets `s3:GetObject` on input bucket
- Glue role gets `s3:PutObject` on output bucket

### 3. Lifecycle Policies

Lifecycle policies (`input_lifecycle_days`) **only apply to newly created buckets**.

If using existing buckets:
- Existing lifecycle policies are preserved
- Terraform will NOT modify them

### 4. Bucket Versioning

Versioning settings **only apply to newly created buckets**.

If using existing buckets:
- Existing versioning settings are preserved
- Terraform will NOT enable/disable versioning

## Benefits

✅ **Flexibility**: Use existing buckets without recreating them
✅ **Data Preservation**: Keep existing data in place
✅ **Gradual Migration**: Can migrate from existing to Terraform-managed buckets later
✅ **Integration**: Easy integration with existing data workflows
✅ **Cost Savings**: No need to copy data to new buckets
✅ **Backwards Compatible**: Default behavior unchanged (creates new buckets)

## Validation

Run these checks after deployment:

### 1. Verify Bucket Access

```bash
# Check Lambda can read from input bucket
aws s3 ls s3://$(terraform output -raw input_bucket_name)/ \
  --profile <lambda-role>

# Check Glue can write to output bucket
aws s3 ls s3://$(terraform output -raw output_bucket_name)/ \
  --profile <glue-role>
```

### 2. Verify SQS Integration

```bash
# Upload test file
echo '{"test": "data"}' > test.ndjson
aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/

# Check SQS received message
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw sqs_queue_url) \
  --attribute-names ApproximateNumberOfMessages
```

### 3. Verify Lambda Execution

```bash
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow
```

## Rollback

If you need to revert to creating new buckets:

1. **Update terraform.tfvars:**
```hcl
create_input_bucket  = true
create_output_bucket = true
# existing_input_bucket_name = ""   # Comment out or remove
# existing_output_bucket_name = ""  # Comment out or remove
```

2. **Apply changes:**
```bash
terraform apply
```

**Note:** This will create NEW buckets. If you want to use the same bucket names, you'll need to:
- Delete existing buckets first (after backing up data)
- Or change the bucket naming in Terraform

## Migration Path

If you currently use Terraform-created buckets and want to switch to existing buckets:

### Option A: Import Existing Buckets

```bash
# Stop managing bucket with Terraform
terraform state rm module.s3.aws_s3_bucket.input

# Update config to use existing
create_input_bucket = false
existing_input_bucket_name = "the-bucket-name"

# Apply
terraform apply
```

### Option B: Create New Infrastructure

Deploy fresh infrastructure with existing buckets, then decommission old.

## Documentation

📖 **[EXISTING-BUCKETS-GUIDE.md](./EXISTING-BUCKETS-GUIDE.md)** - Complete guide with:
- Detailed configuration instructions
- Architecture diagrams
- Troubleshooting steps
- Best practices
- Verification procedures

📖 **[README.md](./README.md)** - Updated with S3 bucket configuration section

## Summary

### What's Required

1. Set `create_input_bucket = false` to use existing input bucket
2. Set `create_output_bucket = false` to use existing output bucket
3. Provide bucket names via `existing_input_bucket_name` and `existing_output_bucket_name`

### What's Optional

- Lifecycle policies (only for new buckets)
- Versioning settings (only for new buckets)

### What's Automatic

- IAM permission configuration
- SQS event notification setup (ensure no conflicts)
- Data source configuration
- Output generation

✅ **Result**: Terraform integrates seamlessly with your existing S3 buckets while creating the necessary infrastructure components!
