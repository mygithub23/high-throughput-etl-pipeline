#!/bin/bash

# Deploy Production Lambda Function
# Optimized for 338K files/day at 3.5-4.5 GB each

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_NAME="${STACK_NAME}-manifest-builder"

echo -e "${GREEN}Deploying Production Lambda${NC}"
echo "Function: $LAMBDA_NAME"
echo "Region: $REGION"
echo ""

# Confirmation
echo -e "${YELLOW}This will deploy PRODUCTION Lambda with:${NC}"
echo "  - INFO logging only"
echo "  - File-count batching (100 files/manifest)"
echo "  - Optimized for 3.5-4.5 GB files"
echo "  - Expected: 338K files/day"
echo ""
read -p "Continue with production deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Package Lambda
echo -e "${YELLOW}Step 1: Packaging Lambda code...${NC}"
cd ../lambda
if [ -f lambda.zip ]; then
    rm lambda.zip
fi

zip -r lambda.zip lambda_manifest_builder.py
echo "✓ Package created: lambda.zip"
echo ""

# Deploy code
echo -e "${YELLOW}Step 2: Deploying Lambda code...${NC}"
aws lambda update-function-code \
  --function-name "$LAMBDA_NAME" \
  --zip-file fileb://lambda.zip \
  --region $REGION \
  --query '{FunctionName:FunctionName,LastModified:LastModified,CodeSize:CodeSize}' \
  --output table

echo "✓ Code deployed"
echo ""

# Update configuration
echo -e "${YELLOW}Step 3: Updating Lambda configuration...${NC}"
aws lambda update-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --environment "Variables={
    TRACKING_TABLE=${STACK_NAME}-file-tracking,
    METRICS_TABLE=${STACK_NAME}-metrics,
    MANIFEST_BUCKET=ndjson-manifests-${AWS_ACCOUNT_ID},
    GLUE_JOB_NAME=${STACK_NAME}-streaming-processor,
    MAX_FILES_PER_MANIFEST=100,
    MAX_BATCH_SIZE_GB=500,
    QUARANTINE_BUCKET=ndjson-quarantine-${AWS_ACCOUNT_ID},
    EXPECTED_FILE_SIZE_MB=3500,
    SIZE_TOLERANCE_PERCENT=20,
    LOCK_TABLE=${STACK_NAME}-file-tracking,
    LOCK_TTL_SECONDS=300
  }" \
  --memory-size 1024 \
  --timeout 300 \
  --region $REGION \
  --query '{FunctionName:FunctionName,MemorySize:MemorySize,Timeout:Timeout}' \
  --output table

echo "✓ Configuration updated"
echo ""

# Wait for update
echo "Waiting for Lambda to be ready (10 seconds)..."
sleep 10

# Verify
echo -e "${YELLOW}Step 4: Verifying deployment...${NC}"
aws lambda get-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --query '{State:State,LastModified:LastModified,Version:Version}' \
  --output table

echo ""
echo -e "${GREEN}✓ Production Lambda Deployed Successfully!${NC}"
echo ""

echo "Configuration:"
echo "  MAX_FILES_PER_MANIFEST: 100"
echo "  MAX_BATCH_SIZE_GB: 500"
echo "  EXPECTED_FILE_SIZE_MB: 3500 (3.5 GB)"
echo "  Memory: 1024 MB"
echo "  Timeout: 300 seconds"
echo ""

echo "Next steps:"
echo "  1. Deploy Glue job: ./deploy-glue.sh"
echo "  2. Test with production data: ./test-production.sh"
echo "  3. Monitor: ./monitor-pipeline.sh"
echo ""

# Cleanup
rm -f lambda.zip
