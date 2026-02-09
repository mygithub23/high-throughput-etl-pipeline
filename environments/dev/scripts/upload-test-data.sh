#!/bin/bash

# Upload Test NDJSON Data
# Generates small test files and uploads to input bucket

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}"
REGION="us-east-1"

echo -e "${GREEN}Uploading Test NDJSON Data${NC}"
echo "Bucket: s3://${INPUT_BUCKET}"
echo ""

# Create temp directory for test files
TEMP_DIR="./build/test-data"
mkdir -p "$TEMP_DIR"

# Generate small test NDJSON files (10 files, 100 records each)
echo -e "${YELLOW}Generating test data...${NC}"
DATE_PREFIX=$(date +%Y-%m-%d)

for i in {1..10}; do
    FILE="$TEMP_DIR/test-data-${DATE_PREFIX}-${i}.ndjson"

    # Generate 100 simple JSON records
    for j in {1..100}; do
        echo "{\"id\": $((i * 100 + j)), \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"value\": $((RANDOM % 1000)), \"category\": \"test\", \"batch\": $i}" >> "$FILE"
    done

    echo "Created: $FILE (100 records)"
done

echo -e "${GREEN}Generated 10 files with 1,000 total records${NC}"
echo ""

# Upload to S3 (to root of bucket, not /input/ prefix)
echo -e "${YELLOW}Uploading to S3...${NC}"
echo "Target: s3://${INPUT_BUCKET}/${DATE_PREFIX}/"
aws s3 cp "$TEMP_DIR/" "s3://${INPUT_BUCKET}/${DATE_PREFIX}/" --recursive --region $REGION

echo -e "${GREEN}Test data uploaded${NC}"
echo ""

# Verify upload
echo "Verifying uploaded files..."
aws s3 ls "s3://${INPUT_BUCKET}/${DATE_PREFIX}/" --region $REGION

# Clean up
rm -rf "$TEMP_DIR"

echo ""
echo "Files uploaded to: s3://${INPUT_BUCKET}/${DATE_PREFIX}/"
echo ""
echo "Next steps:"
echo " 1. Wait ~1-2 minutes for Lambda to process files"
echo " 2. Check for manifests:"
echo " aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/"
echo " 3. Run Glue job:"
echo " ./run-glue-batch.sh"
echo ""
echo "Estimated costs:"
echo " - S3 storage: < \$0.01"
echo " - Lambda: Free tier"
echo " - Glue job: ~\$0.88-1.76 (1-2 workers × 5-10 min)"
echo ""
