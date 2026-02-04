#!/bin/bash

# Open CloudWatch Dashboard
# Shows URLs for monitoring the pipeline

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Dashboard name
DASHBOARD_NAME="ndjson-parquet-pipeline-${ENV}"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}Pipeline Monitoring URLs${NC}"
echo ""

# CloudWatch Dashboard
DASHBOARD_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo -e "${CYAN}CloudWatch Dashboard:${NC}"
echo "  $DASHBOARD_URL"
echo ""

# Lambda Logs
LAMBDA_NAME="ndjson-parquet-sqs-manifest-builder-${ENV}"
LAMBDA_LOGS_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${LAMBDA_NAME}"
echo -e "${CYAN}Lambda Logs:${NC}"
echo "  $LAMBDA_LOGS_URL"
echo ""

# Step Functions
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"
STEPFN_URL="https://${REGION}.console.aws.amazon.com/states/home?region=${REGION}#/statemachines/view/arn:aws:states:${REGION}:${AWS_ACCOUNT_ID}:stateMachine:${STATE_MACHINE_NAME}"
echo -e "${CYAN}Step Functions:${NC}"
echo "  $STEPFN_URL"
echo ""

# Glue Job
GLUE_JOB_NAME="ndjson-parquet-batch-job-${ENV}"
GLUE_URL="https://${REGION}.console.aws.amazon.com/glue/home?region=${REGION}#/v2/etl-configuration/jobs/view/${GLUE_JOB_NAME}"
echo -e "${CYAN}Glue Job:${NC}"
echo "  $GLUE_URL"
echo ""

# DynamoDB Table
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
DYNAMODB_URL="https://${REGION}.console.aws.amazon.com/dynamodbv2/home?region=${REGION}#table?name=${TABLE_NAME}"
echo -e "${CYAN}DynamoDB Table:${NC}"
echo "  $DYNAMODB_URL"
echo ""

# S3 Buckets
echo -e "${CYAN}S3 Buckets:${NC}"
echo "  Input:      https://s3.console.aws.amazon.com/s3/buckets/ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
echo "  Manifest:   https://s3.console.aws.amazon.com/s3/buckets/ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
echo "  Output:     https://s3.console.aws.amazon.com/s3/buckets/ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
echo "  Quarantine: https://s3.console.aws.amazon.com/s3/buckets/ndjson-quarantine-sqs-${AWS_ACCOUNT_ID}-${ENV}"
echo ""

# Check if dashboard exists
echo -e "${CYAN}Checking dashboard status...${NC}"
if aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" --region "$REGION" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓ Dashboard exists${NC}"
else
    echo -e "  ⚠️  Dashboard not found. Run 'terraform apply' with create_dashboard=true"
fi
echo ""

# Try to open in browser (works on Mac/Linux with xdg-open or open)
if command -v xdg-open &> /dev/null; then
    read -p "Open dashboard in browser? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        xdg-open "$DASHBOARD_URL"
    fi
elif command -v open &> /dev/null; then
    read -p "Open dashboard in browser? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "$DASHBOARD_URL"
    fi
fi
