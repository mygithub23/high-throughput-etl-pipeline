#!/bin/bash

# Run Glue Job in Batch Mode with Specific Manifest
# This processes ONE manifest file and exits (cost-efficient)

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"

echo -e "${GREEN}Running Glue Job in BATCH Mode${NC}"
echo "Job: $JOB_NAME"
echo ""

# Step 1: Find available manifest files
echo -e "${YELLOW}Step 1: Finding available manifest files...${NC}"
MANIFESTS=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive --region $REGION | grep "\.json$" | awk '{print $4}' | head -5)

if [ -z "$MANIFESTS" ]; then
    echo "❌ No manifest files found in s3://${MANIFEST_BUCKET}/manifests/"
    echo ""
    echo "You need to:"
    echo "  1. Upload test NDJSON files to the input bucket"
    echo "  2. Wait for Lambda to create manifests"
    echo "  3. Then run this script"
    echo ""
    exit 1
fi

echo "Found manifest files:"
echo "$MANIFESTS" | nl
echo ""

# Step 2: Select a manifest
echo -e "${YELLOW}Step 2: Select manifest to process${NC}"
MANIFEST_COUNT=$(echo "$MANIFESTS" | wc -l)

if [ $MANIFEST_COUNT -eq 1 ]; then
    SELECTED_KEY=$(echo "$MANIFESTS" | head -1)
    echo "Auto-selecting only manifest: $SELECTED_KEY"
else
    echo "Enter number (1-$MANIFEST_COUNT) or press Enter for most recent:"
    read -r SELECTION

    if [ -z "$SELECTION" ]; then
        SELECTED_KEY=$(echo "$MANIFESTS" | head -1)
    else
        SELECTED_KEY=$(echo "$MANIFESTS" | sed -n "${SELECTION}p")
    fi

    echo "Selected: $SELECTED_KEY"
fi

MANIFEST_PATH="s3://${MANIFEST_BUCKET}/${SELECTED_KEY}"
echo ""

# Step 3: Run the job
echo -e "${YELLOW}Step 3: Starting Glue job...${NC}"
echo "Manifest: $MANIFEST_PATH"
echo ""

JOB_RUN_ID=$(aws glue start-job-run \
  --job-name "$JOB_NAME" \
  --arguments '{
    "--MANIFEST_PATH": "'"${MANIFEST_PATH}"'"
  }' \
  --region $REGION \
  --query 'JobRunId' \
  --output text)

echo -e "${GREEN}✓ Job started successfully!${NC}"
echo ""
echo "Job Run ID: $JOB_RUN_ID"
echo "Manifest: $MANIFEST_PATH"
echo ""
echo "The job will:"
echo "  1. Process the manifest file"
echo "  2. Convert NDJSON to Parquet"
echo "  3. Exit automatically when done"
echo ""
echo -e "${GREEN}Estimated cost: ~\$1-5 (depending on data size)${NC}"
echo ""
echo "Monitor progress:"
echo "  aws glue get-job-run --job-name $JOB_NAME --run-id $JOB_RUN_ID --region $REGION"
echo ""
echo "View logs (wait ~2 min for logs to appear):"
echo "  aws logs tail /aws-glue/jobs/output --follow --log-stream-names $JOB_RUN_ID --region $REGION"
echo ""
