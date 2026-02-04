#!/bin/bash

# Force Manifest Creation for Pending Files
# This script manually triggers Lambda to process pending files when stuck

set -e

ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
INPUT_PREFIX="pipeline/input"  # From terraform.tfvars
LAMBDA_FUNCTION="ndjson-parquet-manifest-builder-${ENV}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Force Manifest Creation${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. Check current state
echo -e "${CYAN}1. Current Pipeline State${NC}"
echo ""

echo "Checking DynamoDB for pending files..."
PENDING_COUNT=$(aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --index-name "status-index" \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --select "COUNT" \
  --region "$REGION" \
  --output json | python3 -c "import sys, json; print(json.load(sys.stdin).get('Count', 0))")

echo "Total pending files: $PENDING_COUNT"
echo ""

if [ "$PENDING_COUNT" -lt 10 ]; then
    echo -e "${YELLOW}⚠️  Less than 10 files pending (threshold for manifest creation)${NC}"
    echo "No action needed - wait for more files to arrive"
    exit 0
fi

# 2. Get a sample pending file to trigger Lambda
echo -e "${CYAN}2. Finding a sample pending file to trigger Lambda${NC}"
echo ""

SAMPLE_FILE=$(aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --index-name "status-index" \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --limit 1 \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('Items', [])
if items:
    item = items[0]
    date_prefix = item.get('date_prefix', {}).get('S', '')
    file_key = item.get('file_key', {}).get('S', '')
    # Output as 'date_prefix|file_key' to preserve full paths with slashes
    print(f'{date_prefix}|{file_key}')
else:
    print('')
")

if [ -z "$SAMPLE_FILE" ]; then
    echo -e "${RED}✗ Could not find any pending files in DynamoDB${NC}"
    exit 1
fi

# Extract date_prefix and file_key (separated by pipe to preserve full paths)
DATE_PREFIX=$(echo "$SAMPLE_FILE" | cut -d'|' -f1)
FILE_KEY=$(echo "$SAMPLE_FILE" | cut -d'|' -f2)

# file_key in DynamoDB is just the filename, need to add the input prefix
# Actual S3 path: s3://bucket/pipeline/input/filename.ndjson
S3_KEY="${INPUT_PREFIX}/${FILE_KEY}"

echo "Sample file date: $DATE_PREFIX"
echo "Sample file key: $FILE_KEY"
echo "Full S3 path: s3://${INPUT_BUCKET}/${S3_KEY}"
echo ""

# 3. Create a test event to trigger Lambda
echo -e "${CYAN}3. Triggering Lambda with test S3 event${NC}"
echo ""

# Create test event JSON
TEST_EVENT=$(cat <<EOF
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "${REGION}",
      "eventTime": "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "s3SchemaVersion": "1.0",
        "bucket": {
          "name": "${INPUT_BUCKET}",
          "arn": "arn:aws:s3:::${INPUT_BUCKET}"
        },
        "object": {
          "key": "${S3_KEY}",
          "size": 1024
        }
      }
    }
  ]
}
EOF
)

echo "Invoking Lambda function: $LAMBDA_FUNCTION"
echo ""

# Invoke Lambda
RESULT=$(aws lambda invoke \
  --function-name "$LAMBDA_FUNCTION" \
  --invocation-type RequestResponse \
  --payload "$TEST_EVENT" \
  --region "$REGION" \
  /tmp/lambda-response.json 2>&1)

# Check result
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Lambda invoked successfully${NC}"
    echo ""

    # Check if there was a function error
    if echo "$RESULT" | grep -q "FunctionError"; then
        echo -e "${RED}✗ Lambda execution failed${NC}"
        echo "Error details:"
        echo "$RESULT"
        echo ""
        echo "Lambda Response:"
        cat /tmp/lambda-response.json
        echo ""
        exit 1
    fi

    echo "Lambda Response:"
    cat /tmp/lambda-response.json | python3 -m json.tool 2>/dev/null || cat /tmp/lambda-response.json
    echo ""

    # Check for error in response
    if grep -q "errorMessage" /tmp/lambda-response.json; then
        echo -e "${YELLOW}⚠️  Lambda returned an error${NC}"
    fi
else
    echo -e "${RED}✗ Lambda invocation failed${NC}"
    echo "$RESULT"
    exit 1
fi

# 4. Wait and check results
echo ""
echo -e "${CYAN}4. Checking Results (waiting 5 seconds...)${NC}"
sleep 5
echo ""

# Check if manifests were created
NEW_PENDING_COUNT=$(aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --index-name "status-index" \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --select "COUNT" \
  --region "$REGION" \
  --output json | python3 -c "import sys, json; print(json.load(sys.stdin).get('Count', 0))")

PROCESSED=$((PENDING_COUNT - NEW_PENDING_COUNT))

echo "Previous pending count: $PENDING_COUNT"
echo "Current pending count: $NEW_PENDING_COUNT"
echo "Files processed: $PROCESSED"
echo ""

if [ "$PROCESSED" -gt 0 ]; then
    echo -e "${GREEN}✓ Success! $PROCESSED files were processed into manifests${NC}"
    echo ""
    echo "Check manifest creation:"
    echo "  bash debug-glue-output.sh"
    echo ""
    echo "Monitor pipeline:"
    echo "  bash trace-pipeline.sh"
else
    echo -e "${YELLOW}⚠️  No files were processed${NC}"
    echo ""
    echo "Possible causes:"
    echo "  1. LOCK record is still active (check with: bash check-locks.sh)"
    echo "  2. Lambda retry loop didn't complete"
    echo "  3. Files are from different dates and didn't reach threshold"
    echo ""
    echo "Check Lambda logs:"
    echo "  aws logs tail /aws/lambda/$LAMBDA_FUNCTION --follow --region $REGION"
fi

echo -e "${CYAN}========================================${NC}"
