#!/bin/bash

# Deploy Lambda Function Updates
# Packages and deploys the manifest builder Lambda with latest code changes

set -e

ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

LAMBDA_FUNCTION="ndjson-parquet-manifest-builder-${ENV}"
SCRIPTS_BUCKET="ndjson-glue-scripts-${AWS_ACCOUNT_ID}-${ENV}"
LAMBDA_DIR="$(dirname "$0")/../lambda"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Lambda Deployment Tool${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. Check if Lambda source exists
if [ ! -f "$LAMBDA_DIR/lambda_manifest_builder.py" ]; then
    echo -e "${YELLOW}✗ Lambda source not found at: $LAMBDA_DIR${NC}"
    exit 1
fi

echo -e "${CYAN}1. Packaging Lambda function...${NC}"
echo ""

# Create temp directory for packaging
TEMP_DIR=$(mktemp -d)
echo "Using temp directory: $TEMP_DIR"

# Copy Lambda code
cp "$LAMBDA_DIR/lambda_manifest_builder.py" "$TEMP_DIR/"

# Create deployment package
cd "$TEMP_DIR"
zip -q ndjson-parquet-manifest-builder.zip lambda_manifest_builder.py

echo -e "${GREEN}✓ Lambda package created${NC}"
echo ""

# 2. Upload to S3
echo -e "${CYAN}2. Uploading to S3...${NC}"
aws s3 cp ndjson-parquet-manifest-builder.zip \
    "s3://${SCRIPTS_BUCKET}/lambda/${ENV}/" \
    --region "$REGION"

echo -e "${GREEN}✓ Uploaded to s3://${SCRIPTS_BUCKET}/lambda/${ENV}/ndjson-parquet-manifest-builder.zip${NC}"
echo ""

# 3. Update Lambda function
echo -e "${CYAN}3. Updating Lambda function code...${NC}"
aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION" \
    --s3-bucket "$SCRIPTS_BUCKET" \
    --s3-key "lambda/${ENV}/ndjson-parquet-manifest-builder.zip" \
    --region "$REGION" \
    --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'Function: {data.get(\"FunctionName\")}')
print(f'Version: {data.get(\"Version\")}')
print(f'Last Modified: {data.get(\"LastModified\")}')
print(f'Code Size: {data.get(\"CodeSize\")} bytes')
print(f'State: {data.get(\"State\")}')
"

echo ""
echo -e "${GREEN}✓ Lambda function updated successfully${NC}"
echo ""

# 4. Wait for update to complete
echo -e "${CYAN}4. Waiting for Lambda to be ready...${NC}"
sleep 5

STATUS=$(aws lambda get-function \
    --function-name "$LAMBDA_FUNCTION" \
    --region "$REGION" \
    --query 'Configuration.State' \
    --output text)

if [ "$STATUS" = "Active" ]; then
    echo -e "${GREEN}✓ Lambda is Active and ready${NC}"
else
    echo -e "${YELLOW}⚠️  Lambda state: $STATUS (may need to wait)${NC}"
fi

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "Lambda function '$LAMBDA_FUNCTION' has been updated with:"
echo "  ✓ MANIFEST record creation before Step Functions"
echo "  ✓ Orphan flush mechanism for old dates"
echo "  ✓ Lock contention retry logic"
echo ""
echo "Next steps:"
echo "  1. Test by uploading new files:"
echo "     aws s3 sync test-data/ s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}/"
echo ""
echo "  2. Monitor Lambda logs:"
echo "     aws logs tail /aws/lambda/$LAMBDA_FUNCTION --follow --region $REGION"
echo ""
echo "  3. Check MANIFEST records:"
echo "     bash check-manifest-records.sh"
echo ""
