#!/bin/bash

# End-to-End Pipeline Test
# Complete test of the NDJSON to Parquet pipeline

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATE_PREFIX=$(date +%Y-%m-%d)

echo -e "${GREEN}=== End-to-End Pipeline Test ===${NC}"
echo "Date: $DATE_PREFIX"
echo "Account: $AWS_ACCOUNT_ID"
echo ""

# Step 1: Clean up old test data
echo -e "${YELLOW}Step 1: Cleaning up old test data...${NC}"
read -p "Delete old manifests and output? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting old manifests..."
    aws s3 rm s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/ --recursive --region $REGION || true

    echo "Deleting old output..."
    aws s3 rm s3://ndjson-parquet-output-${AWS_ACCOUNT_ID}/ --recursive --region $REGION || true

    echo "Cleanup complete"
else
    echo "Skipping cleanup"
fi
echo ""

# Step 2: Upload test data
echo -e "${YELLOW}Step 2: Uploading test data...${NC}"
./upload-test-data.sh
echo ""

# Step 3: Wait for Lambda
echo -e "${YELLOW}Step 3: Waiting for Lambda to process files (90 seconds)...${NC}"
echo "Lambda will:"
echo " - Track files in DynamoDB"
echo " - Create manifest when threshold reached"
sleep 90
echo "Wait complete"
echo ""

# Step 4: Check if manifest was created
echo -e "${YELLOW}Step 4: Checking for manifests...${NC}"
MANIFEST_COUNT=$(aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/${DATE_PREFIX}/ --region $REGION 2>/dev/null | wc -l || echo "0")
echo "Manifests found: $MANIFEST_COUNT"

if [ "$MANIFEST_COUNT" -eq "0" ]; then
    echo -e "${RED}No manifests created!${NC}"
    echo ""
    echo "Troubleshooting:"
    echo " 1. Check Lambda logs: ./check-lambda-logs.sh"
    echo " 2. Check DynamoDB: ./check-dynamodb-files.sh"
    echo " 3. Check SQS: ./check-sqs-queue.sh"
    exit 1
fi

echo "Manifests created"
echo ""

# Step 5: Run Glue job
echo -e "${YELLOW}Step 5: Running Glue job...${NC}"
./run-glue-batch.sh
echo ""

# Step 6: Wait for Glue job
echo -e "${YELLOW}Step 6: Waiting for Glue job to complete (checking every 30 sec)...${NC}"
JOB_NAME="${STACK_NAME}-streaming-processor"

for i in {1..10}; do
    sleep 30

    STATUS=$(aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region $REGION \
        --max-results 1 \
        --query 'JobRuns[0].JobRunState' \
        --output text)

    echo " Status: $STATUS"

    if [ "$STATUS" == "SUCCEEDED" ]; then
        echo -e "${GREEN}Job completed successfully!${NC}"
        break
    elif [ "$STATUS" == "FAILED" ]; then
        echo -e "${RED}Job failed!${NC}"
        echo ""
        echo "Error details:"
        aws glue get-job-runs \
            --job-name "$JOB_NAME" \
            --region $REGION \
            --max-results 1 \
            --query 'JobRuns[0].ErrorMessage' \
            --output text
        exit 1
    fi
done

echo ""

# Step 7: Check output
echo -e "${YELLOW}Step 7: Checking Parquet output...${NC}"
OUTPUT_FILES=$(aws s3 ls s3://ndjson-parquet-output-${AWS_ACCOUNT_ID}/ --recursive --region $REGION)

if [ -z "$OUTPUT_FILES" ]; then
    echo -e "${RED}No output files found!${NC}"
    exit 1
fi

echo "$OUTPUT_FILES"
echo ""

# Step 8: Summary
echo -e "${GREEN}=== Test Complete ===${NC}"
echo ""
echo "Summary:"
echo " Test data uploaded"
echo " Lambda created manifests"
echo " Glue job processed data"
echo " Parquet files created"
echo ""
echo "Next steps:"
echo " 1. Query Parquet with Athena"
echo " 2. Increase batch size for production (1.0 GB)"
echo " 3. Monitor costs"
echo ""
