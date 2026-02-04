#!/bin/bash

# Check Lambda Manifest Builder Logs
# Helps debug why manifests aren't being created

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
LAMBDA_NAME="${STACK_NAME}-manifest-builder"

echo -e "${GREEN}Checking Manifest Builder Lambda Logs${NC}"
echo "Lambda: $LAMBDA_NAME"
echo ""

# Check if Lambda exists
echo -e "${YELLOW}Verifying Lambda exists...${NC}"
aws lambda get-function --function-name "$LAMBDA_NAME" --region $REGION > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Lambda found${NC}"
else
    echo -e "${RED}✗ Lambda not found!${NC}"
    exit 1
fi
echo ""

# Get recent invocations
echo -e "${YELLOW}Recent Lambda invocations (last 1 hour):${NC}"
aws lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --query 'Configuration.{Name:FunctionName,LastModified:LastModified,State:State,Timeout:Timeout}' \
  --output table
echo ""

# Check CloudWatch Logs
echo -e "${YELLOW}Recent logs (last 30 minutes):${NC}"
LOG_GROUP="/aws/lambda/${LAMBDA_NAME}"

# Get log streams
LOG_STREAMS=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --max-items 5 \
  --region $REGION \
  --query 'logStreams[*].logStreamName' \
  --output text 2>/dev/null || echo "")

if [ -z "$LOG_STREAMS" ]; then
    echo -e "${RED}No log streams found!${NC}"
    echo "This means the Lambda has never been invoked."
    echo ""
    echo "Check:"
    echo "  1. SQS queue has messages?"
    echo "  2. Lambda has SQS trigger configured?"
    echo "  3. Lambda has correct permissions?"
    exit 1
fi

echo "Found log streams. Showing latest:"
echo ""

# Show logs from most recent stream
LATEST_STREAM=$(echo "$LOG_STREAMS" | awk '{print $1}')
echo "Stream: $LATEST_STREAM"
echo "----------------------------------------"

aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LATEST_STREAM" \
  --limit 50 \
  --region $REGION \
  --query 'events[*].message' \
  --output text

echo ""
echo "----------------------------------------"
echo ""

# Check for errors
echo -e "${YELLOW}Checking for errors in recent logs:${NC}"
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 1800))000 \
  --filter-pattern "ERROR" \
  --region $REGION \
  --query 'events[*].message' \
  --output text 2>/dev/null || echo "No errors found (or no logs)"

echo ""
echo -e "${GREEN}Log check complete${NC}"
echo ""
echo "To tail logs in real-time:"
echo "  aws logs tail $LOG_GROUP --follow --region $REGION"
