#!/bin/bash

# Fix Lambda SQS Trigger
# Re-enables or recreates the event source mapping

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_NAME="${STACK_NAME}-manifest-builder"

echo -e "${GREEN}Fixing Lambda SQS Trigger${NC}"
echo "Lambda: $LAMBDA_NAME"
echo ""

# Get Queue ARN
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "${STACK_NAME}-file-events" \
  --region $REGION \
  --query 'QueueUrl' \
  --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --region $REGION \
  --query 'Attributes.QueueArn' \
  --output text)

echo "Queue ARN: $QUEUE_ARN"
echo ""

# Check existing event source mappings
echo -e "${YELLOW}Checking existing event source mappings...${NC}"
MAPPINGS=$(aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --output json)

MAPPING_UUID=$(echo "$MAPPINGS" | python -c "import sys, json; data=json.load(sys.stdin); print(data['EventSourceMappings'][0]['UUID'] if data['EventSourceMappings'] else '')" 2>/dev/null || echo "")
MAPPING_STATE=$(echo "$MAPPINGS" | python -c "import sys, json; data=json.load(sys.stdin); print(data['EventSourceMappings'][0]['State'] if data['EventSourceMappings'] else '')" 2>/dev/null || echo "")

if [ -z "$MAPPING_UUID" ]; then
    echo -e "${RED}No event source mapping found!${NC}"
    echo "Creating new mapping..."

    aws lambda create-event-source-mapping \
      --function-name "$LAMBDA_NAME" \
      --event-source-arn "$QUEUE_ARN" \
      --batch-size 10 \
      --maximum-batching-window-in-seconds 30 \
      --region $REGION

    echo -e "${GREEN}Event source mapping created${NC}"
elif [ "$MAPPING_STATE" == "Disabled" ]; then
    echo -e "${YELLOW}Mapping exists but is disabled. Enabling...${NC}"

    aws lambda update-event-source-mapping \
      --uuid "$MAPPING_UUID" \
      --enabled \
      --region $REGION

    echo -e "${GREEN}Event source mapping enabled${NC}"
elif [ "$MAPPING_STATE" == "Enabled" ]; then
    echo -e "${GREEN}Event source mapping already enabled${NC}"
    echo ""
    echo "Mapping details:"
    echo "$MAPPINGS" | python -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data['EventSourceMappings'][0], indent=2))"
else
    echo -e "${YELLOW}Mapping state: $MAPPING_STATE${NC}"
    echo "Trying to enable..."

    aws lambda update-event-source-mapping \
      --uuid "$MAPPING_UUID" \
      --enabled \
      --region $REGION || echo "Could not enable mapping"
fi

echo ""
echo -e "${YELLOW}Current mapping status:${NC}"
aws lambda list-event-source-mappings \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --query 'EventSourceMappings[*].{UUID:UUID,State:State,BatchSize:BatchSize,LastProcessingResult:LastProcessingResult}' \
  --output table

echo ""
echo -e "${GREEN}Trigger configuration complete${NC}"
echo ""
echo "Next steps:"
echo " 1. Wait 1-2 minutes for Lambda to process queued messages"
echo " 2. Check logs: ./check-lambda-logs.sh"
echo " 3. Check for manifests: aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/ --recursive"
