#!/bin/bash

# Manual Trigger for Pipeline Processing
# Re-run Step Functions or Glue job for a specific manifest
#
# Usage:
#   ./trigger-processing.sh list                    # List available manifests
#   ./trigger-processing.sh stepfn <manifest-path>  # Trigger via Step Functions
#   ./trigger-processing.sh glue <manifest-path>    # Trigger Glue directly
#   ./trigger-processing.sh retry-failed            # Retry all failed executions

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

MANIFEST_BUCKET="ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
GLUE_JOB_NAME="ndjson-parquet-batch-job-${ENV}"
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}Manual Trigger for Pipeline Processing${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list [date]              List manifests (optionally for specific date)"
    echo "  stepfn <manifest-path>   Trigger processing via Step Functions"
    echo "  glue <manifest-path>     Trigger Glue job directly (skips Step Functions)"
    echo "  retry-failed             Retry all failed Step Function executions"
    echo "  show <manifest-path>     Show manifest contents"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 list 2026-01-20"
    echo "  $0 stepfn s3://bucket/manifests/2026-01-20/batch-0001.json"
    echo "  $0 glue s3://bucket/manifests/2026-01-20/batch-0001.json"
    echo ""
}

list_manifests() {
    local date_filter="${1:-}"

    echo -e "${GREEN}Available Manifests:${NC}"
    echo ""

    if [ -n "$date_filter" ]; then
        echo "Filtering by date: $date_filter"
        aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/${date_filter}/" --region "$REGION" 2>/dev/null || echo "No manifests found for $date_filter"
    else
        echo "All dates:"
        aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --region "$REGION" 2>/dev/null | while read -r line; do
            date_dir=$(echo "$line" | awk '{print $2}' | tr -d '/')
            if [ -n "$date_dir" ]; then
                count=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/${date_dir}/" --region "$REGION" 2>/dev/null | wc -l | tr -d ' ')
                echo "  $date_dir: $count manifests"
            fi
        done
    fi
    echo ""
}

show_manifest() {
    local manifest_path="$1"

    echo -e "${GREEN}Manifest Contents:${NC}"
    echo "Path: $manifest_path"
    echo ""

    aws s3 cp "$manifest_path" - --region "$REGION" | python3 -m json.tool
}

trigger_stepfn() {
    local manifest_path="$1"

    # Extract date_prefix from manifest path
    # e.g., s3://bucket/manifests/2026-01-20/batch-0001.json -> 2026-01-20
    date_prefix=$(echo "$manifest_path" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)

    if [ -z "$date_prefix" ]; then
        echo -e "${RED}Could not extract date from manifest path${NC}"
        exit 1
    fi

    # Get file count from manifest
    file_count=$(aws s3 cp "$manifest_path" - --region "$REGION" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
locations = data.get('entries', data.get('fileLocations', []))
if isinstance(locations, dict):
    locations = locations.get('URIPrefixes', [])
print(len(locations))
" || echo "10")

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%6N)

    # Get state machine ARN
    SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text)

    if [ -z "$SM_ARN" ]; then
        echo -e "${RED}State machine not found: ${STATE_MACHINE_NAME}${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Triggering Step Functions...${NC}"
    echo "  State Machine: $STATE_MACHINE_NAME"
    echo "  Manifest: $manifest_path"
    echo "  Date Prefix: $date_prefix"
    echo "  File Count: $file_count"
    echo ""

    # Build input JSON
    input_json=$(cat <<EOF
{
  "manifest_path": "$manifest_path",
  "date_prefix": "$date_prefix",
  "file_count": $file_count,
  "timestamp": "$timestamp"
}
EOF
)

    echo "Input:"
    echo "$input_json" | python3 -m json.tool
    echo ""

    read -p "Proceed? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    # Start execution
    result=$(aws stepfunctions start-execution \
        --state-machine-arn "$SM_ARN" \
        --input "$input_json" \
        --region "$REGION" \
        --output json)

    exec_arn=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['executionArn'])")

    echo -e "${GREEN}✓ Execution started${NC}"
    echo "  ARN: $exec_arn"
    echo ""
    echo "Monitor with:"
    echo "  ./stepfunctions-queries.sh details $exec_arn"
}

trigger_glue() {
    local manifest_path="$1"

    echo -e "${YELLOW}Triggering Glue Job directly...${NC}"
    echo "  Job: $GLUE_JOB_NAME"
    echo "  Manifest: $manifest_path"
    echo "  Output Bucket: $OUTPUT_BUCKET"
    echo ""

    read -p "Proceed? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    result=$(aws glue start-job-run \
        --job-name "$GLUE_JOB_NAME" \
        --arguments "{
            \"--MANIFEST_PATH\": \"$manifest_path\",
            \"--MANIFEST_BUCKET\": \"$MANIFEST_BUCKET\",
            \"--OUTPUT_BUCKET\": \"$OUTPUT_BUCKET\",
            \"--COMPRESSION_TYPE\": \"snappy\"
        }" \
        --region "$REGION" \
        --output json)

    run_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['JobRunId'])")

    echo -e "${GREEN}✓ Glue job started${NC}"
    echo "  Run ID: $run_id"
    echo ""
    echo "Monitor with:"
    echo "  ./glue-queries.sh details $run_id"
    echo ""
    echo -e "${YELLOW}Note: DynamoDB status will NOT be updated (Step Functions skipped)${NC}"
}

retry_failed() {
    echo -e "${YELLOW}Finding failed Step Function executions...${NC}"

    SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text)

    if [ -z "$SM_ARN" ]; then
        echo -e "${RED}State machine not found${NC}"
        exit 1
    fi

    # Get failed executions
    failed=$(aws stepfunctions list-executions \
        --state-machine-arn "$SM_ARN" \
        --status-filter FAILED \
        --region "$REGION" \
        --max-results 10 \
        --output json)

    count=$(echo "$failed" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('executions',[])))")

    if [ "$count" -eq "0" ]; then
        echo "No failed executions found."
        exit 0
    fi

    echo "Found $count failed executions:"
    echo ""

    # List them
    echo "$failed" | python3 -c "
import sys, json

data = json.load(sys.stdin)
for i, ex in enumerate(data.get('executions', []), 1):
    print(f\"{i}. {ex['name']}\")
    print(f\"   Started: {ex['startDate'][:19]}\")
"

    echo ""
    read -p "Retry all? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    # Retry each
    echo "$failed" | python3 -c "
import sys, json, subprocess

data = json.load(sys.stdin)
for ex in data.get('executions', []):
    arn = ex['executionArn']

    # Get original input
    result = subprocess.run(
        ['aws', 'stepfunctions', 'describe-execution',
         '--execution-arn', arn,
         '--region', 'us-east-1',
         '--query', 'input',
         '--output', 'text'],
        capture_output=True, text=True
    )

    if result.returncode == 0:
        print(f'Input: {result.stdout.strip()[:100]}...')
        print(arn)
" | while read -r line; do
        if [[ "$line" == arn:* ]]; then
            # Get input from the execution
            input_json=$(aws stepfunctions describe-execution \
                --execution-arn "$line" \
                --region "$REGION" \
                --query 'input' \
                --output text)

            echo "Retrying: $line"

            aws stepfunctions start-execution \
                --state-machine-arn "$SM_ARN" \
                --input "$input_json" \
                --region "$REGION" \
                --output json | python3 -c "import sys,json; print(f\"  New ARN: {json.load(sys.stdin)['executionArn']}\")"
        fi
    done

    echo ""
    echo -e "${GREEN}✓ Retry complete${NC}"
}

# Main command handler
case "${1:-help}" in
    list)
        list_manifests "$2"
        ;;
    show)
        if [ -z "$2" ]; then
            echo "Usage: $0 show <manifest-path>"
            exit 1
        fi
        show_manifest "$2"
        ;;
    stepfn)
        if [ -z "$2" ]; then
            echo "Usage: $0 stepfn <manifest-path>"
            echo ""
            echo "Example:"
            echo "  $0 stepfn s3://${MANIFEST_BUCKET}/manifests/2026-01-20/batch-0001.json"
            exit 1
        fi
        trigger_stepfn "$2"
        ;;
    glue)
        if [ -z "$2" ]; then
            echo "Usage: $0 glue <manifest-path>"
            exit 1
        fi
        trigger_glue "$2"
        ;;
    retry-failed)
        retry_failed
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac
