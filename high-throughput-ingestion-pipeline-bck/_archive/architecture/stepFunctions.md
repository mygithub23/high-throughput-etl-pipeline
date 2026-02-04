# Step Functions Standard Implementation

## Overview

This document tracks the implementation of AWS Step Functions Standard to orchestrate the NDJSON to Parquet pipeline, replacing the need for manual Glue job triggering and the lambda_state_management module.

**Note:** Standard workflow (not Express) is required because we need `.sync` integration to wait for Glue job completion. Express workflows don't support synchronous service integrations.

## Architecture

### Before (Current)

```
S3 → SQS → Lambda Manifest Builder → Manifest S3
                    │
                    └──(MISSING)──→ Glue Job

Lambda State Management (separate, disabled)
├── get_stats
├── find_orphans
├── reset_stuck_files
└── etc.
```

### After (With Step Functions)

```
S3 → SQS → Lambda Manifest Builder → Step Functions Standard
                                          │
                                          ├── Update DynamoDB (processing)
                                          ├── Start Glue Job (.sync)
                                          ├── Wait for Completion
                                          ├── Update DynamoDB (completed/failed)
                                          ├── Handle Errors/Retries
                                          └── Send SNS Notifications
```

## Step Functions Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STEP FUNCTIONS EXPRESS WORKFLOW                           │
│                    "ndjson-parquet-processor-{env}"                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐                                                            │
│  │   START     │  Input: manifest_path, date_prefix, file_count            │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────────┐                                                        │
│  │ Update DynamoDB │  status: "processing"                                  │
│  │ (Pass State)    │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                  │
│           ▼                                                                  │
│  ┌─────────────────┐                                                        │
│  │  Start Glue Job │  .sync (waits for completion)                         │
│  │  (Task State)   │  JobName, Arguments: --MANIFEST_PATH                  │
│  └────────┬────────┘                                                        │
│           │                                                                  │
│     ┌─────┴─────┐                                                           │
│     │           │                                                           │
│  Success     Failure                                                        │
│     │           │                                                           │
│     ▼           ▼                                                           │
│  ┌─────────┐ ┌─────────────┐                                               │
│  │ Update  │ │   Retry?    │  Max 2 retries, exponential backoff           │
│  │ Status: │ │             │                                               │
│  │completed│ └──────┬──────┘                                               │
│  └────┬────┘        │                                                       │
│       │        ┌────┴────┐                                                  │
│       │        │         │                                                  │
│       │      Retry    Max Retries Exceeded                                 │
│       │        │         │                                                  │
│       │        ▼         ▼                                                  │
│       │   (back to   ┌─────────────┐                                       │
│       │   Glue Job)  │ Update      │                                       │
│       │              │ Status:     │                                       │
│       │              │ failed      │                                       │
│       │              └──────┬──────┘                                       │
│       │                     │                                               │
│       │                     ▼                                               │
│       │              ┌─────────────┐                                       │
│       │              │ Send Alert  │  SNS notification                     │
│       │              │             │                                       │
│       │              └──────┬──────┘                                       │
│       │                     │                                               │
│       └──────────┬──────────┘                                               │
│                  │                                                          │
│                  ▼                                                          │
│           ┌─────────────┐                                                   │
│           │    END      │                                                   │
│           └─────────────┘                                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Automatic Glue Triggering | Step Functions starts Glue job when manifest created |
| Job State Tracking | Built-in execution history (90 days retention) |
| Automatic Retries | 2 retries on failure with exponential backoff |
| Error Notifications | SNS alert on final failure |
| DynamoDB Updates | Automatic status updates (processing → completed/failed) |
| Visual Monitoring | AWS Console Step Functions visualization |
| Replaces State Management | No need for separate lambda_state_management |

## Implementation Changes

### Summary

| Area | Files Changed | New Files | Complexity |
|------|---------------|-----------|------------|
| Terraform | 3 modified | 1 new module | Medium |
| Lambda Code | 2 modified | 0 | Small |
| IAM | 1 modified | 0 | Small |
| **Total** | **6 modified** | **3 new files** | **Medium** |

---

### 1. NEW: Terraform Step Functions Module

**Location:** `terraform/modules/step_functions/`

**Files:**
- `main.tf` - Step Function state machine definition
- `variables.tf` - Input variables
- `outputs.tf` - Output values

**State Machine Definition (ASL):**
```json
{
  "Comment": "NDJSON to Parquet Processing Workflow",
  "StartAt": "UpdateStatusProcessing",
  "States": {
    "UpdateStatusProcessing": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${tracking_table}",
        "Key": {...},
        "UpdateExpression": "SET #status = :status",
        "ExpressionAttributeValues": {":status": {"S": "processing"}}
      },
      "Next": "StartGlueJob"
    },
    "StartGlueJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${glue_job_name}",
        "Arguments": {
          "--MANIFEST_PATH.$": "$.manifest_path"
        }
      },
      "Retry": [...],
      "Catch": [...],
      "Next": "UpdateStatusCompleted"
    },
    ...
  }
}
```

---

### 2. MODIFY: terraform/main.tf

**Add module block:**
```hcl
module "step_functions" {
  source = "./modules/step_functions"

  environment               = var.environment
  glue_job_name            = module.glue.job_name
  glue_job_arn             = module.glue.job_arn
  file_tracking_table_name = module.dynamodb.file_tracking_table_name
  file_tracking_table_arn  = module.dynamodb.file_tracking_table_arn
  sns_topic_arn            = module.monitoring.sns_topic_arn
  step_functions_role_arn  = module.iam.step_functions_role_arn
  log_retention_days       = var.log_retention_days

  tags = local.common_tags
}
```

---

### 3. MODIFY: terraform/modules/iam/main.tf

**Add Step Functions IAM role:**
```hcl
resource "aws_iam_role" "step_functions" {
  name = "ndjson-parquet-step-functions-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  name = "ndjson-parquet-step-functions-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Glue permissions
      {
        Effect = "Allow"
        Action = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = "*"
      },
      # DynamoDB permissions
      {
        Effect = "Allow"
        Action = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [var.file_tracking_table_arn]
      },
      # SNS permissions
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [var.sns_topic_arn]
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}
```

---

### 4. MODIFY: terraform/modules/iam/outputs.tf

**Add output:**
```hcl
output "step_functions_role_arn" {
  description = "Step Functions role ARN"
  value       = aws_iam_role.step_functions.arn
}
```

---

### 5. MODIFY: Lambda Manifest Builder

**Files:**
- `environments/dev/lambda/lambda_manifest_builder.py`
- `environments/prod/lambda/lambda_manifest_builder.py`

**Changes:**

```python
# Add to imports (after boto3)
sfn_client = boto3.client('stepfunctions')

# Add environment variable (after LOCK_TTL_SECONDS)
STEP_FUNCTION_ARN = os.environ.get('STEP_FUNCTION_ARN', '')

# Add new function
def start_step_function(manifest_path: str, date_prefix: str, file_count: int) -> Optional[str]:
    """Start Step Functions workflow to process manifest."""
    if not STEP_FUNCTION_ARN:
        logger.warning("STEP_FUNCTION_ARN not set, skipping Step Function trigger")
        return None

    try:
        response = sfn_client.start_execution(
            stateMachineArn=STEP_FUNCTION_ARN,
            input=json.dumps({
                'manifest_path': manifest_path,
                'date_prefix': date_prefix,
                'file_count': file_count,
                'timestamp': datetime.utcnow().isoformat()
            })
        )
        logger.info(f"Started Step Function execution: {response['executionArn']}")
        return response['executionArn']
    except Exception as e:
        logger.error(f"Failed to start Step Function: {str(e)}")
        return None

# Modify create_manifests_if_ready() - after manifest creation
# Add call to start_step_function()
```

---

### 6. MODIFY: terraform/modules/lambda/main.tf

**Add environment variable:**
```hcl
environment {
  variables = {
    # ... existing variables
    STEP_FUNCTION_ARN = var.step_function_arn
  }
}
```

---

### 7. MODIFY: terraform/modules/lambda/variables.tf

**Add variable:**
```hcl
variable "step_function_arn" {
  description = "Step Functions state machine ARN"
  type        = string
  default     = ""
}
```

---

### 8. MODIFY: terraform/outputs.tf

**Add output:**
```hcl
output "step_function_arn" {
  description = "Step Functions state machine ARN"
  value       = module.step_functions.state_machine_arn
}

output "step_function_name" {
  description = "Step Functions state machine name"
  value       = module.step_functions.state_machine_name
}
```

---

## File Change Summary

| File | Action | Lines |
|------|--------|-------|
| `terraform/modules/step_functions/main.tf` | NEW | ~120 |
| `terraform/modules/step_functions/variables.tf` | NEW | ~50 |
| `terraform/modules/step_functions/outputs.tf` | NEW | ~15 |
| `terraform/main.tf` | MODIFY | +20 |
| `terraform/outputs.tf` | MODIFY | +10 |
| `terraform/modules/iam/main.tf` | MODIFY | +60 |
| `terraform/modules/iam/outputs.tf` | MODIFY | +5 |
| `terraform/modules/lambda/main.tf` | MODIFY | +3 |
| `terraform/modules/lambda/variables.tf` | MODIFY | +5 |
| `environments/dev/lambda/lambda_manifest_builder.py` | MODIFY | +30 |
| `environments/prod/lambda/lambda_manifest_builder.py` | MODIFY | +30 |
| **TOTAL** | | **~350 lines** |

---

## Implementation Progress

- [x] Create Step Functions module (`terraform/modules/step_functions/`)
- [x] Add Step Functions IAM role
- [x] Add IAM outputs
- [x] Modify main.tf to include Step Functions module
- [x] Add Lambda environment variable for Step Function ARN
- [x] Modify Lambda manifest builder to trigger Step Functions
- [x] Update terraform outputs
- [ ] Test deployment

### Implementation Summary (2026-01-16)

All Terraform and Lambda code changes have been implemented:

**Terraform Changes:**

- `terraform/modules/step_functions/main.tf` - Step Functions Express state machine
- `terraform/modules/step_functions/variables.tf` - Module input variables
- `terraform/modules/step_functions/outputs.tf` - Module outputs
- `terraform/modules/iam/main.tf` - Added Step Functions IAM role + Lambda states:StartExecution permission
- `terraform/modules/iam/variables.tf` - Added sns_topic_arn variable
- `terraform/modules/iam/outputs.tf` - Added step_functions_role_arn output
- `terraform/modules/lambda/main.tf` - Added STEP_FUNCTION_ARN environment variable
- `terraform/modules/lambda/variables.tf` - Added step_function_arn variable
- `terraform/main.tf` - Added step_functions module block + sns_topic_arn to IAM module
- `terraform/outputs.tf` - Added step_function_arn and step_function_name outputs

**Lambda Changes:**

- `environments/dev/lambda/lambda_manifest_builder.py` - Added start_step_function() and sfn_client
- `environments/prod/lambda/lambda_manifest_builder.py` - Added start_step_function() and sfn_client

---

## Testing

### After Deployment

1. Upload NDJSON files to input bucket
2. Wait for manifest creation (200 files / 700 MB threshold)
3. Verify Step Function execution starts
4. Monitor in AWS Console → Step Functions → Executions
5. Verify Glue job completes
6. Check DynamoDB status updates
7. Verify Parquet files in output bucket

### AWS CLI Commands

```bash
# List Step Function executions
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:REGION:ACCOUNT:stateMachine:ndjson-parquet-processor-dev

# Get execution details
aws stepfunctions describe-execution \
  --execution-arn arn:aws:states:REGION:ACCOUNT:execution:ndjson-parquet-processor-dev:EXECUTION_ID

# Check Glue job runs
aws glue get-job-runs --job-name ndjson-parquet-batch-job-dev
```

---

## Rollback Plan

If issues occur:

1. Set `STEP_FUNCTION_ARN = ""` in Lambda environment variables
2. Lambda will skip Step Function trigger (logs warning)
3. Glue jobs can be triggered manually

---

## Cost Estimate

**Step Functions Express Pricing:**
- $1.00 per 1 million requests
- $0.00001667 per GB-second of memory

**Example (200 files per manifest, 1000 manifests/month):**
- 1000 executions × ~8 state transitions = 8,000 transitions
- Cost: ~$0.008/month (negligible)

---

## Related Documentation

- [Pipeline Overview](pipeline-overview.md)
- [Lambda Manifest Builder](lambda-manifest-builder.md)
- [Glue Batch Job](glue-batch-job.md)
- [AWS Step Functions Developer Guide](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html)
