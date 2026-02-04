#!/bin/bash
# =============================================================================
# Terraform Import Script for Existing AWS Resources
# =============================================================================
# Run this script after configuring AWS credentials to import existing
# resources into Terraform state.
#
# Prerequisites:
# 1. Configure AWS credentials: aws configure
# 2. Run: terraform init
# 3. Run this script: bash import-existing-resources.sh
# =============================================================================

set -e

# AWS Configuration
ACCOUNT_ID="<ACCOUNT>"
REGION="us-east-1"
ENV="dev"

echo "=========================================="
echo "Importing resources for:"
echo "  Account ID: $ACCOUNT_ID"
echo "  Region: $REGION"
echo "  Environment: $ENV"
echo "=========================================="

# Function to safely import (skip if already imported)
safe_import() {
    local resource=$1
    local id=$2
    echo "Importing: $resource"
    terraform import "$resource" "$id" 2>/dev/null || echo "  -> Already imported or doesn't exist"
}

# =============================================================================
# S3 Buckets
# =============================================================================
echo ""
echo ">>> Importing S3 Buckets..."

safe_import "module.s3.aws_s3_bucket.input[0]" "ndjson-input-sqs-${ACCOUNT_ID}-${ENV}"
safe_import "module.s3.aws_s3_bucket.output[0]" "ndjson-output-${ACCOUNT_ID}-${ENV}"
safe_import "module.s3.aws_s3_bucket.manifest[0]" "ndjson-manifest-${ACCOUNT_ID}-${ENV}"
safe_import "module.s3.aws_s3_bucket.quarantine[0]" "ndjson-quarantine-${ACCOUNT_ID}-${ENV}"
safe_import "module.s3.aws_s3_bucket.scripts[0]" "ndjson-scripts-${ACCOUNT_ID}-${ENV}"

# =============================================================================
# DynamoDB Tables
# =============================================================================
echo ""
echo ">>> Importing DynamoDB Tables..."

safe_import "module.dynamodb.aws_dynamodb_table.file_tracking" "ndjson-parquet-sqs-file-tracking-${ENV}"
safe_import "module.dynamodb.aws_dynamodb_table.metrics" "ndjson-parquet-metrics-${ENV}"

# =============================================================================
# IAM Roles
# =============================================================================
echo ""
echo ">>> Importing IAM Roles..."

safe_import "module.iam.aws_iam_role.lambda" "ndjson-parquet-lambda-role-${ENV}"
safe_import "module.iam.aws_iam_role.state_management" "ndjson-parquet-state-management-role-${ENV}"
safe_import "module.iam.aws_iam_role.glue" "ndjson-parquet-glue-role-${ENV}"
safe_import "module.iam.aws_iam_role.eventbridge" "ndjson-parquet-eventbridge-role-${ENV}"

# Note: Step Functions role is new and doesn't need import

# =============================================================================
# IAM Role Policies
# =============================================================================
echo ""
echo ">>> Importing IAM Role Policies..."

safe_import "module.iam.aws_iam_role_policy.lambda" "ndjson-parquet-lambda-role-${ENV}:ndjson-parquet-lambda-policy"
safe_import "module.iam.aws_iam_role_policy.state_management" "ndjson-parquet-state-management-role-${ENV}:ndjson-parquet-state-management-policy"
safe_import "module.iam.aws_iam_role_policy.glue" "ndjson-parquet-glue-role-${ENV}:ndjson-parquet-glue-policy"
safe_import "module.iam.aws_iam_role_policy.eventbridge" "ndjson-parquet-eventbridge-role-${ENV}:ndjson-parquet-eventbridge-policy"

# =============================================================================
# IAM Role Policy Attachments
# =============================================================================
echo ""
echo ">>> Importing IAM Role Policy Attachments..."

safe_import "module.iam.aws_iam_role_policy_attachment.lambda_basic" "ndjson-parquet-lambda-role-${ENV}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
safe_import "module.iam.aws_iam_role_policy_attachment.state_management_basic" "ndjson-parquet-state-management-role-${ENV}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
safe_import "module.iam.aws_iam_role_policy_attachment.glue_service" "ndjson-parquet-glue-role-${ENV}/arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"

# =============================================================================
# SQS Queues
# =============================================================================
echo ""
echo ">>> Importing SQS Queues..."

safe_import "module.sqs.aws_sqs_queue.main" "https://sqs.${REGION}.amazonaws.com/${ACCOUNT_ID}/ndjson-parquet-queue-${ENV}"
safe_import "module.sqs.aws_sqs_queue.dlq" "https://sqs.${REGION}.amazonaws.com/${ACCOUNT_ID}/ndjson-parquet-dlq-${ENV}"

# =============================================================================
# SNS Topic
# =============================================================================
echo ""
echo ">>> Importing SNS Topics..."

safe_import "module.monitoring.aws_sns_topic.alerts" "arn:aws:sns:${REGION}:${ACCOUNT_ID}:ndjson-parquet-alerts-${ENV}"

# =============================================================================
# Lambda Functions
# =============================================================================
echo ""
echo ">>> Importing Lambda Functions..."

safe_import "module.lambda.aws_lambda_function.manifest_builder" "ndjson-parquet-manifest-builder-${ENV}"

# =============================================================================
# Glue Job
# =============================================================================
echo ""
echo ">>> Importing Glue Jobs..."

safe_import "module.glue.aws_glue_job.batch_processor" "ndjson-parquet-batch-job-${ENV}"

# =============================================================================
# CloudWatch Log Groups
# =============================================================================
echo ""
echo ">>> Importing CloudWatch Log Groups..."

safe_import "module.lambda.aws_cloudwatch_log_group.manifest_builder" "/aws/lambda/ndjson-parquet-manifest-builder-${ENV}"
safe_import "module.glue.aws_cloudwatch_log_group.glue_job" "/aws-glue/jobs/ndjson-parquet-batch-job-${ENV}"

# =============================================================================
echo ""
echo "=========================================="
echo "Import complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Run: terraform plan"
echo "2. Review the plan for any remaining differences"
echo "3. Run: terraform apply"
