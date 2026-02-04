#!/bin/bash

# Check Glue Job Errors - Production Version
# Analyzes failed Glue batch jobs for troubleshooting

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

echo -e "${RED}=== Glue Job Error Analysis ===${NC}"
echo ""

# Get failed job runs
echo -e "${YELLOW}Recent Failed Jobs:${NC}"
echo "----------------------------------------"

FAILED_JOBS=$(aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 50 \
  --query 'JobRuns[?JobRunState==`FAILED`]' \
  --output json)

NUM_FAILURES=$(echo "$FAILED_JOBS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

if [ "$NUM_FAILURES" -eq "0" ]; then
    echo -e "${GREEN}No failed jobs found in last 50 runs${NC}"
    exit 0
fi

echo -e "${RED}Found $NUM_FAILURES failed jobs${NC}"
echo ""

# Analyze each failure
echo "$FAILED_JOBS" | python3 << 'EOF'
import sys
import json
from datetime import datetime

data = json.load(sys.stdin)

for i, job in enumerate(data[:10], 1):  # Show last 10 failures
    job_id = job['Id']
    started = job['StartedOn']
    error = job.get('ErrorMessage', 'No error message')

    print(f"\n{i}. Job Run ID: {job_id}")
    print(f"   Started: {started}")
    print(f"   Error: {error}")

    # Check for common errors
    if 'OutOfMemory' in error or 'heap space' in error:
        print(f"   → ISSUE: Out of memory - consider increasing worker size")
    elif 'timeout' in error.lower():
        print(f"   → ISSUE: Job timeout - increase timeout or add workers")
    elif 'Permission' in error or 'Access Denied' in error:
        print(f"   → ISSUE: IAM permissions problem")
    elif 'No such file' in error or 'FileNotFound' in error:
        print(f"   → ISSUE: Missing input files")

    # Get arguments to see which manifest failed
    if 'Arguments' in job:
        args = job['Arguments']
        if '--manifest_path' in args:
            print(f"   Manifest: {args['--manifest_path']}")

EOF

echo ""
echo "----------------------------------------"
echo ""

# Get CloudWatch logs for most recent failure
echo -e "${YELLOW}CloudWatch Logs (Most Recent Failure):${NC}"
echo "----------------------------------------"

MOST_RECENT_FAILED=$(echo "$FAILED_JOBS" | python3 -c "import sys, json; jobs = json.load(sys.stdin); print(jobs[0]['Id'] if jobs else '')")

if [ -n "$MOST_RECENT_FAILED" ]; then
    LOG_GROUP="/aws-glue/jobs/output"
    LOG_STREAM="${MOST_RECENT_FAILED}"

    echo "Fetching logs for job: $MOST_RECENT_FAILED"
    echo ""

    aws logs get-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name "$LOG_STREAM" \
      --region $REGION \
      --limit 50 \
      --output text \
      --query 'events[*].[message]' 2>/dev/null || echo "Could not fetch logs (may not exist yet)"
fi

echo ""
echo "----------------------------------------"
echo ""
echo "Common Solutions:"
echo "  1. Out of Memory → Increase worker type to G.2X or add more workers"
echo "  2. Timeout → Increase job timeout or reduce files per manifest"
echo "  3. Permissions → Check IAM role has S3, DynamoDB, Glue permissions"
echo "  4. Missing files → Check manifest paths and S3 bucket contents"
echo ""
echo "To view full logs:"
echo "  aws logs tail /aws-glue/jobs/output --follow --region $REGION"
echo ""
