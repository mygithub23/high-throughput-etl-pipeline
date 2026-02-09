#!/bin/bash

# Check Glue Job Logs
# Shows recent output and error logs from Glue job runs

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo -e "${GREEN}Checking Glue Job Logs${NC}"
echo "Job: $JOB_NAME"
echo ""

# Get most recent job run
echo -e "${YELLOW}Getting most recent job run...${NC}"
JOB_RUN=$(aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --max-results 1 \
  --output json)

JOB_RUN_ID=$(echo "$JOB_RUN" | python -c "import sys, json; data=json.load(sys.stdin); print(data['JobRuns'][0]['Id'] if data['JobRuns'] else '')")
JOB_STATE=$(echo "$JOB_RUN" | python -c "import sys, json; data=json.load(sys.stdin); print(data['JobRuns'][0]['JobRunState'] if data['JobRuns'] else '')")
ERROR_MSG=$(echo "$JOB_RUN" | python -c "import sys, json; data=json.load(sys.stdin); print(data['JobRuns'][0].get('ErrorMessage', 'N/A') if data['JobRuns'] else 'N/A')")

echo "Job Run ID: $JOB_RUN_ID"
echo "State: $JOB_STATE"
echo "Error: $ERROR_MSG"
echo ""

if [ -z "$JOB_RUN_ID" ]; then
    echo -e "${RED}No job runs found${NC}"
    exit 1
fi

# Get output logs
echo -e "${YELLOW}Output logs (last 50 lines):${NC}"
echo "----------------------------------------"
aws logs tail "///aws-glue/jobs/output" \
  --log-stream-names "$JOB_RUN_ID" \
  --region $REGION \
  --since 2h \
  --format short 2>/dev/null | tail -50 || echo "No output logs found"

echo ""
echo "----------------------------------------"
echo ""

# Get error logs
echo -e "${YELLOW}Error logs (last 50 lines):${NC}"
echo "----------------------------------------"
aws logs tail "///aws-glue/jobs/error" \
  --log-stream-names "$JOB_RUN_ID" \
  --region $REGION \
  --since 2h \
  --format short 2>/dev/null | tail -50 || echo "No error logs found"

echo ""
echo "----------------------------------------"
echo ""

echo -e "${GREEN}Log check complete${NC}"
echo ""
echo "To see full logs:"
echo " Output: aws logs tail ///aws-glue/jobs/output --log-stream-names $JOB_RUN_ID --region $REGION --follow"
echo " Errors: aws logs tail ///aws-glue/jobs/error --log-stream-names $JOB_RUN_ID --region $REGION --follow"
echo ""
