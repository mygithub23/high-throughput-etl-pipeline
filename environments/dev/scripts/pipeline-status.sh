#!/bin/bash

# Pipeline Status Dashboard
# Shows comprehensive status of all pipeline components
#
# Usage:
# ./pipeline-status.sh # Full status
# ./pipeline-status.sh --quick # Quick summary only

set -e

# Configuration
ENV="dev"
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

echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║ NDJSON to Parquet Pipeline Status ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Environment:${NC} $ENV"
echo -e "${CYAN}Account:${NC} $AWS_ACCOUNT_ID"
echo -e "${CYAN}Region:${NC} $REGION"
echo -e "${CYAN}Date:${NC} $TODAY"
echo ""

# Quick mode check
QUICK_MODE=false
if [ "$1" == "--quick" ]; then
    QUICK_MODE=true
fi

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
        size=$(aws s3 ls "s3://${bucket}/${prefix}/" --recursive --summarize --region "$REGION" 2>/dev/null | grep "Total Size" | awk '{print $3, $4}' || echo "0 Bytes")
    else
        count=$(aws s3 ls "s3://${bucket}/" --recursive --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
        size=$(aws s3 ls "s3://${bucket}/" --recursive --summarize --region "$REGION" 2>/dev/null | grep "Total Size" | awk '{print $3, $4}' || echo "0 Bytes")
    fi

    printf " %-12s %6s files %s\n" "$label:" "$count" "$size"
done
echo ""

#############################################################################
# DYNAMODB
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ DYNAMODB FILE TRACKING │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

# Status counts
for status in pending manifested processing completed failed; do
    count=$(aws dynamodb execute-statement \
        --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='${status}'" \
        --region "$REGION" \
        --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")

    case $status in
        pending) color=$YELLOW; icon="" ;;
        manifested) color=$CYAN; icon="" ;;
        processing) color=$YELLOW; icon="" ;;
        completed) color=$GREEN; icon="" ;;
        failed) color=$RED; icon="" ;;
    esac

    printf " ${color}%-12s${NC} %6s %s\n" "$status:" "$count" "$icon"
done

# Today's count
today_count=$(aws dynamodb execute-statement \
    --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE date_prefix='${TODAY}'" \
    --region "$REGION" \
    --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")
echo ""
echo -e " ${CYAN}Today (${TODAY}):${NC} $today_count records"
echo ""

#############################################################################
# SQS QUEUE
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ SQS QUEUE │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null || echo "")

if [ -n "$QUEUE_URL" ]; then
    attrs=$(aws sqs get-queue-attributes \
        --queue-url "$QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
        --region "$REGION" \
        --output json)

    visible=$(echo "$attrs" | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes'].get('ApproximateNumberOfMessages', '0'))")
    in_flight=$(echo "$attrs" | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes'].get('ApproximateNumberOfMessagesNotVisible', '0'))")
    delayed=$(echo "$attrs" | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes'].get('ApproximateNumberOfMessagesDelayed', '0'))")

    echo " Messages available: $visible"
    echo " Messages in-flight: $in_flight"
    echo " Messages delayed: $delayed"
else
    echo -e " ${RED}Queue not found${NC}"
fi
echo ""

#############################################################################
# LAMBDA
#############################################################################
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│ LAMBDA FUNCTION │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"

lambda_config=$(aws lambda get-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --region "$REGION" \
    --output json 2>/dev/null || echo "{}")

if [ "$lambda_config" != "{}" ]; then
    state=$(echo "$lambda_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('State', 'Unknown'))")
    memory=$(echo "$lambda_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('MemorySize', 'N/A'))")
    timeout=$(echo "$lambda_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Timeout', 'N/A'))")
    last_modified=$(echo "$lambda_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('LastModified', 'N/A')[:19])")

    if [ "$state" == "Active" ]; then
        echo -e " State: ${GREEN}$state${NC}"
    else
        echo -e " State: ${RED}$state${NC}"
    fi
    echo " Memory: ${memory} MB"
    echo " Timeout: ${timeout}s"
    echo " Last Modified: $last_modified"

    # Check event source mapping
    esm_state=$(aws lambda list-event-source-mappings \
        --function-name "$LAMBDA_NAME" \
        --region "$REGION" \
        --query 'EventSourceMappings[0].State' \
        --output text 2>/dev/null || echo "Unknown")

    if [ "$esm_state" == "Enabled" ]; then
        echo -e " SQS Trigger: ${GREEN}Enabled${NC}"
    else
        echo -e " SQS Trigger: ${RED}$esm_state${NC}"
    fi
else
    echo -e " ${RED}Lambda not found${NC}"
fi
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

glue_runs=$(aws glue get-job-runs \
    --job-name "$GLUE_JOB_NAME" \
    --region "$REGION" \
    --max-results 20 \
    --output json 2>/dev/null || echo '{"JobRuns": []}')

if [ "$glue_runs" != '{"JobRuns": []}' ]; then
    echo "$glue_runs" | python3 -c "
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

# Latest run
if runs:
    latest = runs[0]
    print()
    print(f\" Latest run: {latest['JobRunState']} ({latest.get('ExecutionTime', 0)}s)\")
"
else
    echo -e " ${RED}Glue job not found${NC}"
fi
echo ""

#############################################################################
# QUICK TIPS
#############################################################################
if [ "$QUICK_MODE" != "true" ]; then
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│ QUICK COMMANDS │${NC}"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo " DynamoDB queries: ./dynamodb-queries.sh status"
    echo " Step Functions: ./stepfunctions-queries.sh list"
    echo " Glue jobs: ./glue-queries.sh list"
    echo " Generate test data: ./generate-test-files.sh 10 1 --upload"
    echo " Cleanup: ./cleanup-pipeline.sh status"
    echo ""
fi

echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
