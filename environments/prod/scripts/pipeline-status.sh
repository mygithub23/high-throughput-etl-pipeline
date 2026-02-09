#!/bin/bash

# Pipeline Status Dashboard - PRODUCTION
# Shows comprehensive status of all pipeline components

set -e

# Configuration - PRODUCTION
ENV="prod"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Resource names
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
MANIFEST_BUCKET="ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
QUARANTINE_BUCKET="ndjson-quarantine-sqs-${AWS_ACCOUNT_ID}-${ENV}"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
LAMBDA_NAME="ndjson-parquet-sqs-manifest-builder-${ENV}"
QUEUE_NAME="ndjson-parquet-sqs-file-events-${ENV}"
GLUE_JOB_NAME="ndjson-parquet-batch-job-${ENV}"
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TODAY=$(date +%Y-%m-%d)

echo -e "${BOLD}${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║ PRODUCTION - NDJSON to Parquet Pipeline Status ║${NC}"
echo -e "${BOLD}${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Environment:${NC} ${RED}$ENV${NC}"
echo -e "${CYAN}Account:${NC} $AWS_ACCOUNT_ID"
echo -e "${CYAN}Region:${NC} $REGION"
echo -e "${CYAN}Date:${NC} $TODAY"
echo ""

#############################################################################
# S3 BUCKETS
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ S3 BUCKETS │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

for bucket_info in \
    "${INPUT_BUCKET}|pipeline/input|Input" \
    "${MANIFEST_BUCKET}|manifests|Manifest" \
    "${OUTPUT_BUCKET}|merged-parquet|Output" \
    "${QUARANTINE_BUCKET}||Quarantine"; do

    IFS='|' read -r bucket prefix label <<< "$bucket_info"

    if [ -n "$prefix" ]; then
        count=$(aws s3 ls "s3://${bucket}/${prefix}/" --recursive --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
    else
        count=$(aws s3 ls "s3://${bucket}/" --recursive --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
    fi

    printf " %-12s %6s files\n" "$label:" "$count"
done
echo ""

#############################################################################
# DYNAMODB
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ DYNAMODB FILE TRACKING │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

for status in pending manifested processing completed failed; do
    count=$(aws dynamodb execute-statement \
        --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='${status}'" \
        --region "$REGION" \
        --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

    case $status in
        pending) color=$YELLOW ;;
        manifested) color=$CYAN ;;
        processing) color=$YELLOW ;;
        completed) color=$GREEN ;;
        failed) color=$RED ;;
    esac

    printf " ${color}%-12s${NC} %6s\n" "$status:" "$count"
done
echo ""

#############################################################################
# STEP FUNCTIONS
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ STEP FUNCTIONS │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
    --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text 2>/dev/null || echo "")

if [ -n "$SM_ARN" ]; then
    for status in RUNNING SUCCEEDED FAILED; do
        count=$(aws stepfunctions list-executions \
            --state-machine-arn "$SM_ARN" \
            --status-filter "$status" \
            --region "$REGION" \
            --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('executions',[])))" || echo "0")

        case $status in
            RUNNING) color=$YELLOW ;;
            SUCCEEDED) color=$GREEN ;;
            FAILED) color=$RED ;;
        esac

        printf " ${color}%-12s${NC} %6s\n" "$status:" "$count"
    done
else
    echo -e " ${RED}State machine not found${NC}"
fi
echo ""

#############################################################################
# GLUE JOB
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ GLUE JOB │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

aws glue get-job-runs \
    --job-name "$GLUE_JOB_NAME" \
    --region "$REGION" \
    --max-results 10 \
    --output json 2>/dev/null | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
runs = data.get('JobRuns', [])

if not runs:
    print(' No job runs found')
    sys.exit(0)

status_counts = Counter(r['JobRunState'] for r in runs)

colors = {
    'RUNNING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
}
NC = '\033[0m'

for status in ['RUNNING', 'SUCCEEDED', 'FAILED']:
    count = status_counts.get(status, 0)
    color = colors.get(status, '')
    print(f' {color}{status}:{NC} {count:>4}')
" || echo " Glue job not found"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
