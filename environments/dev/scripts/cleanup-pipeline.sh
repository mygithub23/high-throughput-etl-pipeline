#!/bin/bash

# Pipeline Cleanup Script
# Removes test data, manifests, DynamoDB records, and resets pipeline state
#
# Usage:
# ./cleanup-pipeline.sh # Show menu
# ./cleanup-pipeline.sh all # Clean everything
# ./cleanup-pipeline.sh date 2025-12-25 # Clean specific date
# ./cleanup-pipeline.sh s3 # Clean S3 only
# ./cleanup-pipeline.sh dynamodb # Clean DynamoDB only

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
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}Pipeline Cleanup Script${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo " status Show current pipeline state (counts)"
    echo " all Clean everything (S3 + DynamoDB + stop executions)"
    echo " date <YYYY-MM-DD> Clean all data for a specific date"
    echo " s3 Clean all S3 buckets (input, manifest, output)"
    echo " s3-input Clean input bucket only"
    echo " s3-manifests Clean manifest bucket only"
    echo " s3-output Clean output bucket only"
    echo " dynamodb Clean all DynamoDB records"
    echo " dynamodb-pending Delete only pending records"
    echo " stop-executions Stop all running Step Function executions"
    echo " local Clean local test-data directories"
    echo ""
    echo "Options:"
    echo " --force Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo " $0 status"
    echo " $0 date 2025-12-25"
    echo " $0 all --force"
    echo ""
}

show_status() {
    echo -e "${GREEN}Pipeline Status:${NC}"
    echo ""

    # S3 counts
    echo -e "${CYAN}S3 Buckets:${NC}"
    for bucket in "$INPUT_BUCKET" "$MANIFEST_BUCKET" "$OUTPUT_BUCKET" "$QUARANTINE_BUCKET"; do
        count=$(aws s3 ls "s3://${bucket}/" --recursive --region "$REGION" 2>/dev/null | wc -l || echo "0")
        echo " $bucket: $count files"
    done
    echo ""

    # DynamoDB counts
    echo -e "${CYAN}DynamoDB (${TABLE_NAME}):${NC}"
    for status in pending manifested processing completed failed; do
        count=$(aws dynamodb execute-statement \
            --statement "SELECT * FROM \"${TABLE_NAME}\" WHERE status='${status}'" \
            --region "$REGION" \
            --output json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))" || echo "0")
        echo " $status: $count"
    done
    echo ""

    # Step Functions
    echo -e "${CYAN}Step Functions (${STATE_MACHINE_NAME}):${NC}"
    SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text)

    if [ -n "$SM_ARN" ]; then
        running=$(aws stepfunctions list-executions \
            --state-machine-arn "$SM_ARN" \
            --status-filter RUNNING \
            --region "$REGION" \
            --output json | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('executions',[])))")
        echo " Running executions: $running"
    else
        echo " State machine not found"
    fi
    echo ""
}

confirm_action() {
    local message="$1"
    if [ "$FORCE" == "true" ]; then
        return 0
    fi

    echo -e "${RED}WARNING: $message${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
}

clean_s3_bucket() {
    local bucket="$1"
    local prefix="${2:-}"

    echo -e "${YELLOW}Cleaning s3://${bucket}/${prefix}...${NC}"

    if [ -n "$prefix" ]; then
        aws s3 rm "s3://${bucket}/${prefix}" --recursive --region "$REGION" 2>/dev/null || true
    else
        aws s3 rm "s3://${bucket}/" --recursive --region "$REGION" 2>/dev/null || true
    fi

    echo -e "${GREEN}Cleaned${NC}"
}

clean_dynamodb_all() {
    echo -e "${YELLOW}Cleaning DynamoDB table: ${TABLE_NAME}${NC}"

    # Get all items
    items=$(aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\"" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    dp = item['date_prefix']['S']
    fk = item['file_key']['S']
    print(f'{dp}|{fk}')
")

    count=0
    while IFS='|' read -r dp fk; do
        if [ -n "$dp" ] && [ -n "$fk" ]; then
            aws dynamodb delete-item \
                --table-name "$TABLE_NAME" \
                --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                --region "$REGION" 2>/dev/null || true
            ((count++))

            # Progress indicator
            if [ $((count % 10)) -eq 0 ]; then
                echo -ne "\r Deleted: $count records"
            fi
        fi
    done <<< "$items"

    echo -e "\r${GREEN}Deleted $count records${NC} "
}

clean_dynamodb_by_status() {
    local status="$1"

    echo -e "${YELLOW}Deleting DynamoDB records with status: ${status}${NC}"

    items=$(aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE status='${status}'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    dp = item['date_prefix']['S']
    fk = item['file_key']['S']
    print(f'{dp}|{fk}')
")

    count=0
    while IFS='|' read -r dp fk; do
        if [ -n "$dp" ] && [ -n "$fk" ]; then
            aws dynamodb delete-item \
                --table-name "$TABLE_NAME" \
                --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                --region "$REGION" 2>/dev/null || true
            ((count++))
        fi
    done <<< "$items"

    echo -e "${GREEN}Deleted $count records${NC}"
}

clean_dynamodb_by_date() {
    local date_prefix="$1"

    echo -e "${YELLOW}Deleting DynamoDB records for date: ${date_prefix}${NC}"

    items=$(aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE date_prefix='${date_prefix}'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    dp = item['date_prefix']['S']
    fk = item['file_key']['S']
    print(f'{dp}|{fk}')
")

    count=0
    while IFS='|' read -r dp fk; do
        if [ -n "$dp" ] && [ -n "$fk" ]; then
            aws dynamodb delete-item \
                --table-name "$TABLE_NAME" \
                --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                --region "$REGION" 2>/dev/null || true
            ((count++))
        fi
    done <<< "$items"

    echo -e "${GREEN}Deleted $count records${NC}"
}

stop_all_executions() {
    echo -e "${YELLOW}Stopping all running Step Function executions...${NC}"

    SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" --output text)

    if [ -z "$SM_ARN" ]; then
        echo "State machine not found"
        return
    fi

    arns=$(aws stepfunctions list-executions \
        --state-machine-arn "$SM_ARN" \
        --status-filter RUNNING \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ex in data.get('executions', []):
    print(ex['executionArn'])
")

    count=0
    while read -r arn; do
        if [ -n "$arn" ]; then
            aws stepfunctions stop-execution \
                --execution-arn "$arn" \
                --region "$REGION" 2>/dev/null || true
            ((count++))
        fi
    done <<< "$arns"

    echo -e "${GREEN}Stopped $count executions${NC}"
}

clean_local() {
    echo -e "${YELLOW}Cleaning local test data directories...${NC}"

    rm -rf ./test-data-* ./build/test-data 2>/dev/null || true

    echo -e "${GREEN}Local cleanup complete${NC}"
}

# Parse --force flag
FORCE="false"
for arg in "$@"; do
    if [ "$arg" == "--force" ]; then
        FORCE="true"
    fi
done

# Main command handler
case "${1:-help}" in
    status)
        show_status
        ;;
    all)
        confirm_action "This will delete ALL data from S3, DynamoDB, and stop all executions"
        echo ""
        stop_all_executions
        echo ""
        clean_s3_bucket "$INPUT_BUCKET" "pipeline/input"
        clean_s3_bucket "$MANIFEST_BUCKET" "manifests"
        clean_s3_bucket "$OUTPUT_BUCKET" "merged-parquet"
        clean_s3_bucket "$QUARANTINE_BUCKET"
        echo ""
        clean_dynamodb_all
        echo ""
        clean_local
        echo ""
        echo -e "${GREEN}=== Full cleanup complete ===${NC}"
        ;;
    date)
        if [ -z "$2" ]; then
            echo "Usage: $0 date <YYYY-MM-DD>"
            exit 1
        fi
        DATE_PREFIX="$2"
        confirm_action "This will delete all data for date: $DATE_PREFIX"
        echo ""
        clean_s3_bucket "$INPUT_BUCKET" "pipeline/input/${DATE_PREFIX}"
        clean_s3_bucket "$MANIFEST_BUCKET" "manifests/${DATE_PREFIX}"
        clean_s3_bucket "$OUTPUT_BUCKET" "merged-parquet/${DATE_PREFIX}"
        echo ""
        clean_dynamodb_by_date "$DATE_PREFIX"
        echo ""
        echo -e "${GREEN}=== Cleanup for ${DATE_PREFIX} complete ===${NC}"
        ;;
    s3)
        confirm_action "This will delete all files from S3 buckets"
        clean_s3_bucket "$INPUT_BUCKET" "pipeline/input"
        clean_s3_bucket "$MANIFEST_BUCKET" "manifests"
        clean_s3_bucket "$OUTPUT_BUCKET" "merged-parquet"
        ;;
    s3-input)
        confirm_action "This will delete all files from input bucket"
        clean_s3_bucket "$INPUT_BUCKET" "pipeline/input"
        ;;
    s3-manifests)
        confirm_action "This will delete all manifests"
        clean_s3_bucket "$MANIFEST_BUCKET" "manifests"
        ;;
    s3-output)
        confirm_action "This will delete all output Parquet files"
        clean_s3_bucket "$OUTPUT_BUCKET" "merged-parquet"
        ;;
    dynamodb)
        confirm_action "This will delete all DynamoDB records"
        clean_dynamodb_all
        ;;
    dynamodb-pending)
        confirm_action "This will delete all pending DynamoDB records"
        clean_dynamodb_by_status "pending"
        ;;
    stop-executions)
        confirm_action "This will stop all running Step Function executions"
        stop_all_executions
        ;;
    local)
        clean_local
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
