#!/bin/bash

# Comprehensive Pipeline Diagnostics
# Checks all components of the pipeline

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}=== Pipeline Diagnostics ===${NC}"
echo "Account: $AWS_ACCOUNT_ID"
echo "Region: $REGION"
echo ""

# Check all buckets
echo -e "${YELLOW}1. S3 Buckets:${NC}"
echo "Input bucket:"
aws s3 ls s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}/ --region $REGION --recursive | wc -l | xargs echo " Files:"

echo "Manifest bucket:"
aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/ --region $REGION --recursive | wc -l | xargs echo " Files:"

echo "Output bucket:"
aws s3 ls s3://ndjson-parquet-output-${AWS_ACCOUNT_ID}/ --region $REGION --recursive | wc -l | xargs echo " Files:"

echo "Quarantine bucket:"
aws s3 ls s3://ndjson-quarantine-${AWS_ACCOUNT_ID}/ --region $REGION --recursive 2>/dev/null | wc -l | xargs echo " Files:" || echo " Bucket doesn't exist"

echo ""

# Check DynamoDB
echo -e "${YELLOW}2. DynamoDB File Tracking:${NC}"
DATE_PREFIX=$(date +%Y-%m-%d)
aws dynamodb query \
  --table-name "${STACK_NAME}-file-tracking" \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values "{\":date\":{\"S\":\"$DATE_PREFIX\"}}" \
  --region $REGION \
  --select COUNT \
  --output json | python -c "import sys, json; print(' Files tracked today:', json.load(sys.stdin)['Count'])"

echo ""

# Check Lambda
echo -e "${YELLOW}3. Lambda Configuration:${NC}"
aws lambda get-function-configuration \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query '{State:State,LastModified:LastModified,Timeout:Timeout,Memory:MemorySize}' \
  --output table

echo ""
echo "Environment variables:"
aws lambda get-function-configuration \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query 'Environment.Variables' \
  --output json

echo ""

# Check Lambda trigger
echo -e "${YELLOW}4. Lambda SQS Trigger:${NC}"
aws lambda list-event-source-mappings \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query 'EventSourceMappings[*].{State:State,BatchSize:BatchSize,LastProcessingResult:LastProcessingResult}' \
  --output table

echo ""

# Check SQS
echo -e "${YELLOW}5. SQS Queue:${NC}"
QUEUE_URL=$(aws sqs get-queue-url --queue-name "${STACK_NAME}-file-events" --region $REGION --query 'QueueUrl' --output text)
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region $REGION \
  --query 'Attributes' \
  --output table

echo ""

# Check Glue job
echo -e "${YELLOW}6. Glue Job Status:${NC}"
aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 3 \
  --query 'JobRuns[*].{StartedOn:StartedOn,State:JobRunState,ExecutionTime:ExecutionTime,Error:ErrorMessage}' \
  --output table

echo ""
echo -e "${GREEN}=== Diagnostics Complete ===${NC}"
echo ""
echo "Summary of potential issues:"
echo " - Check if manifest bucket has files"
echo " - Check if Lambda is being invoked (event source mapping state)"
echo " - Check if SQS has messages waiting"
echo " - Check Glue job error messages"
