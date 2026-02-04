#!/bin/bash

# Test Production Scale - Progressive Load Testing
# Tests with production-sized files at increasing volumes

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}=== Production Scale Testing ===${NC}"
echo ""
echo -e "${YELLOW}This will test with PRODUCTION-SIZED files (3.5-4GB)${NC}"
echo -e "${RED}WARNING: This will incur AWS costs!${NC}"
echo ""

# Test phases
echo "Test Phases:"
echo "  Phase 1: 10 files (35GB) - Quick validation"
echo "  Phase 2: 100 files (350GB) - 1 manifest test"
echo "  Phase 3: 1,000 files (3.5TB) - 10 manifests"
echo "  Phase 4: 10,000 files (35TB) - 100 manifests"
echo ""

read -p "Which phase do you want to run? (1-4): " PHASE

case $PHASE in
    1)
        NUM_FILES=10
        EXPECTED_MANIFESTS=1
        EXPECTED_TIME="5-10 minutes"
        EXPECTED_COST="\$5-10"
        ;;
    2)
        NUM_FILES=100
        EXPECTED_MANIFESTS=1
        EXPECTED_TIME="10-15 minutes"
        EXPECTED_COST="\$20-30"
        ;;
    3)
        NUM_FILES=1000
        EXPECTED_MANIFESTS=10
        EXPECTED_TIME="30-60 minutes"
        EXPECTED_COST="\$200-300"
        ;;
    4)
        NUM_FILES=10000
        EXPECTED_MANIFESTS=100
        EXPECTED_TIME="3-5 hours"
        EXPECTED_COST="\$2,000-3,000"
        ;;
    *)
        echo "Invalid phase"
        exit 1
        ;;
esac

echo ""
echo "Configuration:"
echo "  Files: $NUM_FILES"
echo "  Expected manifests: $EXPECTED_MANIFESTS"
echo "  Expected time: $EXPECTED_TIME"
echo "  Expected cost: $EXPECTED_COST"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Step 1: Generate test data
echo ""
echo -e "${YELLOW}Step 1: Generating $NUM_FILES production-sized files...${NC}"
echo "This will take a while..."
echo ""

./generate-test-data.sh $NUM_FILES 3.5

# Step 2: Upload to S3
echo ""
echo -e "${YELLOW}Step 2: Uploading to S3...${NC}"
echo ""

INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}"

for file in ./test-data-prod/*.ndjson; do
    filename=$(basename "$file")
    echo "  Uploading: $filename"
    aws s3 cp "$file" "s3://${INPUT_BUCKET}/$filename" --region $REGION
done

UPLOAD_TIME=$(date +%s)

echo ""
echo -e "${GREEN}✓ Upload complete at $(date)${NC}"
echo ""

# Step 3: Monitor processing
echo -e "${YELLOW}Step 3: Monitoring processing...${NC}"
echo ""

echo "Waiting 2 minutes for Lambda to process files..."
sleep 120

# Check DynamoDB
echo ""
echo "Checking file tracking..."
TRACKED_FILES=$(aws dynamodb scan \
  --table-name "${STACK_NAME}-file-tracking" \
  --filter-expression "attribute_exists(#s)" \
  --expression-attribute-names '{"#s":"status"}' \
  --region $REGION \
  --select COUNT \
  --query 'Count' \
  --output text)

echo "  Files tracked in DynamoDB: $TRACKED_FILES / $NUM_FILES"

# Check manifests
echo ""
echo "Checking manifests..."
DATE_PREFIX=$(date +%Y-%m-%d)
MANIFESTS=$(aws s3 ls "s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/${DATE_PREFIX}/" \
  --region $REGION 2>/dev/null | wc -l || echo "0")

echo "  Manifests created: $MANIFESTS / $EXPECTED_MANIFESTS"

# Check Glue jobs
echo ""
echo "Checking Glue jobs..."
RUNNING_JOBS=$(aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 50 \
  --query 'JobRuns[?JobRunState==`RUNNING`]' \
  --output json | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

echo "  Jobs running: $RUNNING_JOBS"

# Monitor until complete
echo ""
echo "Monitoring until all jobs complete..."
echo "Press Ctrl+C to stop monitoring (jobs will continue)"
echo ""

while true; do
    sleep 60

    # Get job stats
    STATS=$(aws glue get-job-runs \
      --job-name "${STACK_NAME}-streaming-processor" \
      --region $REGION \
      --max-results 100 \
      --output json | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
upload_time = $UPLOAD_TIME

running = 0
succeeded = 0
failed = 0

for job in data.get('JobRuns', []):
    started_str = job['StartedOn']
    # Parse ISO format
    started = datetime.fromisoformat(started_str.replace('Z', '+00:00').replace('+00:00', ''))
    started_epoch = started.timestamp()

    if started_epoch < upload_time:
        continue

    state = job['JobRunState']
    if state == 'RUNNING':
        running += 1
    elif state == 'SUCCEEDED':
        succeeded += 1
    elif state == 'FAILED':
        failed += 1

print(f'{running},{succeeded},{failed}')
")

    IFS=',' read -r RUNNING SUCCEEDED FAILED <<< "$STATS"

    TOTAL=$((SUCCEEDED + FAILED))

    echo "$(date +%H:%M:%S) - Running: $RUNNING, Completed: $SUCCEEDED, Failed: $FAILED (Total: $TOTAL/$EXPECTED_MANIFESTS)"

    # Check if done
    if [ $RUNNING -eq 0 ] && [ $TOTAL -ge $EXPECTED_MANIFESTS ]; then
        echo ""
        echo -e "${GREEN}✓ All jobs complete!${NC}"
        break
    fi

    # Check for failures
    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}⚠️  Some jobs failed - run ./check-glue-errors.sh for details${NC}"
    fi
done

# Final stats
echo ""
echo -e "${YELLOW}Final Results:${NC}"
echo "----------------------------------------"

END_TIME=$(date +%s)
DURATION=$((END_TIME - UPLOAD_TIME))
DURATION_MIN=$((DURATION / 60))

echo "Total processing time: ${DURATION_MIN} minutes"
echo "Jobs succeeded: $SUCCEEDED"
echo "Jobs failed: $FAILED"
echo ""

# Check output
echo "Checking Parquet output..."
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}"
PARQUET_FILES=$(aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive --region $REGION | wc -l)
echo "  Parquet files created: $PARQUET_FILES"
echo ""

# Cost estimate
echo "Estimated costs:"
GLUE_HOURS=$(echo "scale=2; $DURATION / 3600 * $SUCCEEDED" | bc)
GLUE_COST=$(echo "scale=2; $GLUE_HOURS * 20 * 2 * 0.44" | bc)
echo "  Glue: \$${GLUE_COST} ($GLUE_HOURS DPU-hours)"
echo "  Lambda: ~\$1"
echo "  S3: ~\$5"
echo "  Total: ~\$${GLUE_COST}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ TEST PASSED - All files processed successfully${NC}"
else
    echo -e "${RED}✗ TEST FAILED - Some jobs failed${NC}"
    echo "Run ./check-glue-errors.sh for details"
fi
echo ""
