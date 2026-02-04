#!/bin/bash

# Quick End-to-End Pipeline Test
# Generates files, uploads, and monitors the pipeline
#
# Usage:
#   ./quick-test.sh                 # Run with defaults (10 files, 1MB each)
#   ./quick-test.sh 20 2            # 20 files, 2MB each
#   ./quick-test.sh 20 2 --clean    # Clean before test

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
MANIFEST_BUCKET="ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"
GLUE_JOB_NAME="ndjson-parquet-batch-job-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parameters
NUM_FILES=${1:-10}
SIZE_MB=${2:-1}
CLEAN_FLAG=${3:-""}
DATE_PREFIX=$(date +%Y-%m-%d)

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Quick Pipeline Test                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Configuration:"
echo "  Files: $NUM_FILES"
echo "  Size per file: ~${SIZE_MB} MB"
echo "  Date prefix: $DATE_PREFIX"
echo ""

#############################################################################
# STEP 0: Optional Cleanup
#############################################################################
if [ "$CLEAN_FLAG" == "--clean" ]; then
    echo -e "${YELLOW}Step 0: Cleaning up previous test data...${NC}"
    ./cleanup-pipeline.sh date "$DATE_PREFIX" --force 2>/dev/null || true
    echo ""
fi

#############################################################################
# STEP 1: Generate and Upload Test Files
#############################################################################
echo -e "${YELLOW}Step 1: Generating and uploading test files...${NC}"

./generate-test-files.sh "$NUM_FILES" "$SIZE_MB" "$DATE_PREFIX" --upload

echo ""

#############################################################################
# STEP 2: Wait for Lambda Processing
#############################################################################
echo -e "${YELLOW}Step 2: Waiting for Lambda to process files...${NC}"
echo "  (Checking every 10 seconds for up to 2 minutes)"

for i in {1..12}; do
    sleep 10

    # Check pending count
    pending=$(aws dynamodb execute-statement \
        --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='pending' AND date_prefix='${DATE_PREFIX}'" \
        --region "$REGION" \
        --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

    manifested=$(aws dynamodb execute-statement \
        --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='manifested' AND date_prefix='${DATE_PREFIX}'" \
        --region "$REGION" \
        --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

    echo "  [$i/12] Pending: $pending, Manifested: $manifested"

    # Check if manifest was created
    manifest_count=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/${DATE_PREFIX}/" --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$manifest_count" -gt "0" ]; then
        echo -e "  ${GREEN}✓ Manifest(s) created!${NC}"
        break
    fi
done

echo ""

# List manifests
echo "Manifests created:"
aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/${DATE_PREFIX}/" --region "$REGION" 2>/dev/null || echo "  None found"
echo ""

#############################################################################
# STEP 3: Monitor Step Functions
#############################################################################
echo -e "${YELLOW}Step 3: Monitoring Step Functions execution...${NC}"

SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
    --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text)

echo "  (Checking every 15 seconds for up to 5 minutes)"

for i in {1..20}; do
    sleep 15

    # Get latest execution status
    latest=$(aws stepfunctions list-executions \
        --state-machine-arn "$SM_ARN" \
        --region "$REGION" \
        --max-results 1 \
        --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
execs = data.get('executions', [])
if execs:
    ex = execs[0]
    print(f\"{ex['status']}|{ex['name']}\")
else:
    print('NONE|')
")

    IFS='|' read -r status name <<< "$latest"

    case "$status" in
        RUNNING)
            echo -e "  [$i/20] ${YELLOW}$status${NC} - $name"
            ;;
        SUCCEEDED)
            echo -e "  [$i/20] ${GREEN}$status${NC} - $name"
            echo ""
            break
            ;;
        FAILED)
            echo -e "  [$i/20] ${RED}$status${NC} - $name"
            echo ""
            echo -e "${RED}Execution failed! Checking error...${NC}"
            ./stepfunctions-queries.sh errors
            break
            ;;
        *)
            echo "  [$i/20] Waiting for execution..."
            ;;
    esac
done

#############################################################################
# STEP 4: Check Output
#############################################################################
echo -e "${YELLOW}Step 4: Checking Parquet output...${NC}"

output_files=$(aws s3 ls "s3://${OUTPUT_BUCKET}/merged-parquet/${DATE_PREFIX}/" --recursive --region "$REGION" 2>/dev/null || echo "")

if [ -n "$output_files" ]; then
    echo -e "${GREEN}✓ Output files created:${NC}"
    echo "$output_files" | head -5
    output_count=$(echo "$output_files" | wc -l | tr -d ' ')
    if [ "$output_count" -gt "5" ]; then
        echo "  ... and $((output_count - 5)) more files"
    fi
else
    echo -e "${YELLOW}No output files yet. Glue job may still be running.${NC}"
fi

echo ""

#############################################################################
# STEP 5: Summary
#############################################################################
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Test Summary                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

# DynamoDB status
echo "DynamoDB Status:"
for status in pending manifested processing completed failed; do
    count=$(aws dynamodb execute-statement \
        --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='${status}' AND date_prefix='${DATE_PREFIX}'" \
        --region "$REGION" \
        --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

    if [ "$count" -gt "0" ]; then
        case $status in
            completed) echo -e "  ${GREEN}$status: $count${NC}" ;;
            failed)    echo -e "  ${RED}$status: $count${NC}" ;;
            *)         echo -e "  ${YELLOW}$status: $count${NC}" ;;
        esac
    fi
done
echo ""

# Final check
completed=$(aws dynamodb execute-statement \
    --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='completed' AND date_prefix='${DATE_PREFIX}'" \
    --region "$REGION" \
    --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

if [ "$completed" -gt "0" ]; then
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ TEST PASSED - Pipeline working correctly${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
else
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠ TEST INCOMPLETE - Check status manually${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo ""
    echo "Debug commands:"
    echo "  ./dynamodb-queries.sh date $DATE_PREFIX"
    echo "  ./stepfunctions-queries.sh failed"
    echo "  ./glue-queries.sh errors"
fi
echo ""
