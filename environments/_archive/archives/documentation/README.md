# NDJSON to Parquet Pipeline - Terraform Infrastructure

This directory contains Terraform configurations for deploying the high-throughput NDJSON to Parquet data pipeline on AWS.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Module Structure](#module-structure)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Managing Multiple Environments](#managing-multiple-environments)
- [Outputs](#outputs)
- [Cost Estimation](#cost-estimation)
- [Troubleshooting](#troubleshooting)
- [Migration from CloudFormation](#migration-from-cloudformation)

## Architecture Overview

The pipeline consists of the following components:

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐     ┌──────────────┐
│  S3 Input   │────▶│   Lambda     │────▶│ S3 Manifest│────▶│  Glue Job    │
│   Bucket    │     │  (Manifest   │     │   Bucket   │     │  (Batch      │
│             │     │   Builder)   │     │            │     │  Processing) │
└─────────────┘     └──────────────┘     └────────────┘     └──────────────┘
                            │                                        │
                            ▼                                        ▼
                    ┌──────────────┐                        ┌────────────┐
                    │  DynamoDB    │                        │ S3 Output  │
                    │  File Track  │                        │  Bucket    │
                    └──────────────┘                        └────────────┘
```

### Key Components

- **S3 Buckets**: Input, manifest, output, quarantine, and scripts storage
- **Lambda Functions**: Manifest builder, control plane, state management
- **AWS Glue**: Batch processing job for NDJSON to Parquet conversion
- **DynamoDB**: File tracking and metrics storage
- **SQS/DLQ**: Enhanced reliability with Dead Letter Queue for failed messages
- **CloudWatch**: Monitoring, alarms, and dashboards
- **SNS**: Email notifications for alerts

## Prerequisites

1. **Terraform**: Version 1.5.0 or higher
   ```bash
   terraform version
   ```

2. **AWS CLI**: Configured with appropriate credentials
   ```bash
   aws configure
   aws sts get-caller-identity
   ```

3. **Required AWS Permissions**:
   - S3 (buckets, objects, notifications)
   - Lambda (functions, permissions)
   - IAM (roles, policies)
   - DynamoDB (tables, capacity management)
   - Glue (jobs, triggers)
   - CloudWatch (alarms, logs, dashboards)
   - SNS (topics, subscriptions)
   - EventBridge (rules, targets)
   - SQS (queues, policies) - if using SQS

4. **Lambda and Glue Code**: Upload scripts to S3 before deployment

   ```bash
   # See "Uploading Code" section below
   ```

## Quick Start

### 1. Clone and Navigate

```bash
cd terraform
```

### 2. Copy and Customize Variables

For development:

```bash
cp terraform.tfvars.dev.example terraform.tfvars
# Edit terraform.tfvars with your settings
```

For production:

```bash
cp terraform.tfvars.prod.example terraform.tfvars
# Edit terraform.tfvars with your settings
```

### 3. Upload Lambda and Glue Code

Before running Terraform, upload your Lambda and Glue scripts:

```bash
# Set your AWS account ID and environment
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT="dev"  # or "prod"
SCRIPTS_BUCKET="ndjson-glue-scripts-${ACCOUNT_ID}-${ENVIRONMENT}"

# Create scripts bucket if it doesn't exist
aws s3 mb s3://${SCRIPTS_BUCKET}

# Package and upload Lambda functions
cd ../environments/${ENVIRONMENT}/lambda

# Package manifest builder
zip lambda_manifest_builder.zip lambda_manifest_builder.py
aws s3 cp lambda_manifest_builder.zip s3://${SCRIPTS_BUCKET}/lambda/${ENVIRONMENT}/

# Package control plane
zip lambda_control_plane.zip lambda_control_plane.py
aws s3 cp lambda_control_plane.zip s3://${SCRIPTS_BUCKET}/lambda/${ENVIRONMENT}/

# Package state manager
zip lambda_state_manager.zip lambda_state_manager.py
aws s3 cp lambda_state_manager.zip s3://${SCRIPTS_BUCKET}/lambda/${ENVIRONMENT}/

# Upload Glue script
cd ../glue
aws s3 cp glue_batch_job.py s3://${SCRIPTS_BUCKET}/glue/${ENVIRONMENT}/

cd ../../../terraform
```

### 4. Initialize Terraform

```bash
terraform init
```

### 5. Plan Deployment

```bash
terraform plan
```

Review the plan to ensure all resources are correct.

### 6. Deploy

```bash
terraform apply
```

Type `yes` when prompted to confirm.

### 7. Verify Deployment

```bash
# Check outputs
terraform output

# Test by uploading a file
aws s3 cp test.ndjson s3://$(terraform output -raw input_bucket_name)/

# Monitor logs
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-${ENVIRONMENT} --follow
```

## Module Structure

```
terraform/
├── main.tf                          # Root module - orchestrates all components
├── variables.tf                     # Input variables
├── outputs.tf                       # Output values
├── terraform.tfvars.dev.example     # Dev environment example
├── terraform.tfvars.prod.example    # Prod environment example
├── README.md                        # This file
│
└── modules/
    ├── s3/                          # S3 buckets module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── dynamodb/                    # DynamoDB tables module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── iam/                         # IAM roles and policies module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── lambda/                      # Manifest builder Lambda module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── control_plane/               # Control plane Lambda module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── state_management/            # State management Lambda module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── glue/                        # Glue job module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── monitoring/                  # CloudWatch monitoring module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    └── sqs/                         # SQS queues module
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## Configuration

### Key Variables

#### Environment (Required)

```hcl
environment = "dev"  # or "prod"
aws_region  = "us-east-1"
```

#### Lambda Configuration

```hcl
lambda_manifest_memory      = 1024  # MB
lambda_manifest_timeout     = 180   # seconds
lambda_manifest_concurrency = 50    # concurrent executions
```

#### S3 Bucket Configuration (Optional Existing Buckets)

```hcl
# Option 1: Use existing input/output buckets (recommended if you have existing buckets)
create_input_bucket          = false
existing_input_bucket_name   = "your-existing-input-bucket"
create_output_bucket         = false
existing_output_bucket_name  = "your-existing-output-bucket"

# Option 2: Create new buckets (default)
create_input_bucket  = true
create_output_bucket = true
```

**Note:** Manifest, quarantine, and scripts buckets are always created by Terraform.

📖 **See [EXISTING-BUCKETS-GUIDE.md](./EXISTING-BUCKETS-GUIDE.md) for detailed instructions on using existing S3 buckets.**

#### Glue Configuration

```hcl
glue_worker_type        = "G.2X"  # G.1X, G.2X, G.4X, G.8X
glue_number_of_workers  = 20
glue_max_concurrent_runs = 30
```

#### SQS Configuration

```hcl
sqs_message_retention_seconds = 345600  # 4 days
sqs_visibility_timeout        = 360     # 6 minutes
sqs_max_receive_count         = 3       # Retries before DLQ
sqs_batch_size                = 10      # Lambda batch size
```

**SQS Benefits:**
- ✅ Enhanced reliability with Dead Letter Queue
- ✅ Automatic retry logic (up to 3 attempts)
- ✅ Protection against Lambda throttling
- ✅ Better visibility into processing queue depth
- ✅ Message persistence (up to 4 days retention)

#### Monitoring

```hcl
alert_email      = "your-email@example.com"
create_dashboard = true
log_retention_days = 7
```

### Full Variable Reference

See [variables.tf](./variables.tf) for complete list of configurable parameters.

## Deployment

### Standard Deployment

```bash
# Initialize
terraform init

# Plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan
```

### Environment-Specific Deployment

```bash
# Dev environment
terraform apply -var-file="terraform.tfvars.dev.example"

# Prod environment
terraform apply -var-file="terraform.tfvars.prod.example"
```

### Selective Resource Deployment

```bash
# Deploy only S3 buckets
terraform apply -target=module.s3

# Deploy only Lambda functions
terraform apply -target=module.lambda
```

## Managing Multiple Environments

### Option 1: Terraform Workspaces

```bash
# Create workspaces
terraform workspace new dev
terraform workspace new prod

# Switch between workspaces
terraform workspace select dev
terraform apply

terraform workspace select prod
terraform apply
```

### Option 2: Separate State Files

```bash
# Dev deployment
terraform apply -var-file="terraform.tfvars.dev.example" \
  -state="terraform-dev.tfstate"

# Prod deployment
terraform apply -var-file="terraform.tfvars.prod.example" \
  -state="terraform-prod.tfstate"
```

### Option 3: Separate Directories (Recommended)

```bash
terraform/
├── environments/
│   ├── dev/
│   │   ├── main.tf -> ../../main.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   └── prod/
│       ├── main.tf -> ../../main.tf
│       ├── terraform.tfvars
│       └── backend.tf
```

## Outputs

After successful deployment, Terraform will output important values:

```bash
terraform output

# Example output:
# input_bucket_name = "ndjson-input-sqs-123456789012-dev"
# manifest_bucket_name = "ndjson-manifest-sqs-123456789012-dev"
# output_bucket_name = "ndjson-output-sqs-123456789012-dev"
# glue_job_name = "ndjson-parquet-batch-job-dev"
# sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:ndjson-parquet-alerts-dev"
```

Use outputs in scripts:

```bash
INPUT_BUCKET=$(terraform output -raw input_bucket_name)
aws s3 cp file.ndjson s3://${INPUT_BUCKET}/
```

## Cost Estimation

### Development Environment (Low Volume)

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| S3 | 5 buckets, 500 GB | $11.50 |
| DynamoDB | 5 RCU, 5 WCU | $2.92 |
| Lambda | 1M invocations, 1024 MB | $17.00 |
| Glue | G.1X, 10 workers, 100 hours | $44.00 |
| CloudWatch | Logs, alarms, dashboard | $10.00 |
| **Total** | | **~$85/month** |

### Production Environment (High Volume - 338K files/day)

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| S3 | 5 buckets, 50 TB | $1,150.00 |
| DynamoDB | 20 RCU, 20 WCU | $11.68 |
| Lambda | 10M invocations, 1024 MB | $170.00 |
| Glue | G.2X, 20 workers, 720 hours | $1,267.20 |
| SQS | 10M requests | $4.00 |
| CloudWatch | Logs, alarms, dashboard | $50.00 |
| **Total** | | **~$2,652/month** |

Use AWS Pricing Calculator for accurate estimates: https://calculator.aws/

## Troubleshooting

### Common Issues

#### 1. Lambda Code Not Found

**Error**: `Error: InvalidParameterValueException: Error occurred while GetObject. S3 Error Code: NoSuchKey`

**Solution**: Upload Lambda code before deploying:
```bash
./upload-scripts.sh dev
```

#### 2. DynamoDB Throttling

**Error**: `ProvisionedThroughputExceededException`

**Solution**: Increase capacity in terraform.tfvars:
```hcl
dynamodb_read_capacity  = 20
dynamodb_write_capacity = 20
```

#### 3. Glue Job Failures

**Error**: Job fails with memory errors

**Solution**: Increase worker type:
```hcl
glue_worker_type = "G.4X"  # or G.8X
```

#### 4. S3 Bucket Already Exists

**Error**: `BucketAlreadyExists`

**Solution**: Import existing bucket or use different account/region

#### 5. IAM Permission Denied

**Error**: `AccessDeniedException`

**Solution**: Ensure your AWS credentials have required permissions

### Debug Mode

```bash
# Enable Terraform debug logging
export TF_LOG=DEBUG
terraform apply

# View Lambda logs
aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev --follow

# View Glue job logs
aws glue get-job-runs --job-name ndjson-parquet-batch-job-dev
```

## Migration from CloudFormation

If you're migrating from the CloudFormation templates:

### 1. Export CloudFormation Resources

```bash
# List existing stacks
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE

# Get stack outputs
aws cloudformation describe-stacks --stack-name ndjson-parquet-pipeline-dev
```

### 2. Import Existing Resources

```bash
# Import S3 bucket
terraform import module.s3.aws_s3_bucket.input ndjson-input-sqs-123456789012-dev

# Import DynamoDB table
terraform import module.dynamodb.aws_dynamodb_table.file_tracking ndjson-parquet-sqs-file-tracking-dev

# Continue for other resources...
```

### 3. Verify State

```bash
terraform plan
# Should show "No changes" if import was successful
```

### 4. Delete CloudFormation Stack

```bash
# Only after verifying Terraform manages all resources
aws cloudformation delete-stack --stack-name ndjson-parquet-pipeline-dev
```

## Advanced Topics

### Remote State Management

Configure S3 backend in `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "ndjson-parquet-pipeline/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
```

### State Locking

```bash
# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
```

### Automated Deployments (CI/CD)

Example GitHub Actions workflow:

```yaml
name: Terraform Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan
        run: terraform plan -out=tfplan

      - name: Terraform Apply
        run: terraform apply -auto-approve tfplan
```

## Maintenance

### Updating Resources

```bash
# Update specific module
terraform apply -target=module.lambda

# Update all resources
terraform apply
```

### Viewing State

```bash
# List all resources
terraform state list

# Show specific resource
terraform state show module.s3.aws_s3_bucket.input
```

### Destroying Resources

```bash
# Destroy specific resource
terraform destroy -target=module.monitoring

# Destroy everything (use with caution!)
terraform destroy
```

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review CloudWatch logs
3. Consult AWS documentation
4. Create an issue in the project repository

## License

[Your License Here]
