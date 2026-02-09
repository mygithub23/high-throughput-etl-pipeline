#!/bin/bash

# Reprocess Failed Manifests and Flush Pending Files
# This script helps recover from pipeline failures
#
# Usage:
# ./reprocess-failed.sh list-failed # List failed Step Function executions
# ./reprocess-failed.sh list-pending # List pending files by date
# ./reprocess-failed.sh retry-failed # Retry all failed executions
# ./reprocess-failed.sh trigger-flush # Upload a dummy file to trigger orphan flush
# ./reprocess-failed.sh reset-manifested # Reset manifested files back to pending

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${AWS_ACCOUNT_ID}:stateMachine:ndjson-parquet-processor-${ENV}"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}Reprocess Failed Manifests and Flush Pending Files${NC}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo " list-failed List all failed Step Function executions"
    echo " list-pending List pending files grouped by date"
    echo " list-manifested List manifested files grouped by date"
    echo " retry-failed Retry all failed Step Function executions"
    echo " trigger-flush Upload a test file to trigger orphan flush"
    echo " reset-manifested Reset manifested files back to pending status"
    echo " reset-date <date> Reset all files for a specific date to pending"
    echo ""
}

list_failed() {
    echo -e "${CYAN}Failed Step Function Executions:${NC}"
    echo ""

    aws stepfunctions list-executions \
        --state-machine-arn "$STATE_MACHINE_ARN" \
        --status-filter FAILED \
        --max-results 50 \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
executions = data.get('executions', [])

if not executions:
    print('No failed executions found.')
    sys.exit(0)

print(f'Found {len(executions)} failed execution(s):')
print()

for i, ex in enumerate(executions, 1):
    name = ex.get('name', 'N/A')
    start = ex.get('startDate', 'N/A')
    stop = ex.get('stopDate', 'N/A')
    arn = ex.get('executionArn', 'N/A')

    # Format dates
    if isinstance(start, (int, float)):
        start = datetime.fromtimestamp(start).strftime('%Y-%m-%d %H:%M:%S')
    if isinstance(stop, (int, float)):
        stop = datetime.fromtimestamp(stop).strftime('%Y-%m-%d %H:%M:%S')

    print(f'{i}. {name}')
    print(f' Started: {start}')
    print(f' Stopped: {stop}')
    print(f' ARN: {arn}')
    print()
"
}

list_pending() {
    echo -e "${CYAN}Pending Files by Date:${NC}"
    echo ""

    aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE status='pending'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
from collections import defaultdict

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No pending files found.')
    sys.exit(0)

# Group by date
by_date = defaultdict(list)
for item in items:
    date = item.get('date_prefix', {}).get('S', 'unknown')
    file_key = item.get('file_key', {}).get('S', 'unknown')
    by_date[date].append(file_key)

print(f'Total pending files: {len(items)}')
print()

for date in sorted(by_date.keys()):
    files = by_date[date]
    print(f'{date}: {len(files)} files')
    for f in files[:3]: # Show first 3
        print(f' - {f}')
    if len(files) > 3:
        print(f' ... and {len(files) - 3} more')
    print()
"
}

list_manifested() {
    echo -e "${CYAN}Manifested Files by Date:${NC}"
    echo ""

    aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key, manifest_path FROM \"${TABLE_NAME}\" WHERE status='manifested'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
from collections import defaultdict

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No manifested files found.')
    sys.exit(0)

# Group by date
by_date = defaultdict(list)
for item in items:
    date = item.get('date_prefix', {}).get('S', 'unknown')
    file_key = item.get('file_key', {}).get('S', 'unknown')
    manifest = item.get('manifest_path', {}).get('S', 'unknown')
    by_date[date].append((file_key, manifest))

print(f'Total manifested files: {len(items)}')
print()

for date in sorted(by_date.keys()):
    files = by_date[date]
    manifests = set(f[1] for f in files)
    print(f'{date}: {len(files)} files in {len(manifests)} manifest(s)')
    print()
"
}

retry_failed() {
    echo -e "${YELLOW}Retrying failed executions...${NC}"
    echo ""

    # Get failed executions
    failed=$(aws stepfunctions list-executions \
        --state-machine-arn "$STATE_MACHINE_ARN" \
        --status-filter FAILED \
        --max-results 50 \
        --region "$REGION" \
        --output json)

    count=$(echo "$failed" | python3 -c "import sys, json; print(len(json.load(sys.stdin).get('executions', [])))")

    if [ "$count" == "0" ]; then
        echo "No failed executions to retry."
        return
    fi

    echo "Found $count failed execution(s). Retrieving input and retrying..."
    echo ""

    # Process each failed execution
    echo "$failed" | python3 -c "
import sys, json, subprocess

data = json.load(sys.stdin)
executions = data.get('executions', [])

for ex in executions:
    arn = ex.get('executionArn')
    name = ex.get('name')

    # Get the execution input
    result = subprocess.run(
        ['aws', 'stepfunctions', 'describe-execution', '--execution-arn', arn, '--region', '${REGION}', '--output', 'json'],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f'Failed to get details for {name}')
        continue

    details = json.loads(result.stdout)
    input_data = details.get('input', '{}')

    print(f'Retrying: {name}')
    print(f' Input: {input_data[:100]}...')

    # Start new execution
    retry_result = subprocess.run(
        ['aws', 'stepfunctions', 'start-execution',
         '--state-machine-arn', '${STATE_MACHINE_ARN}',
         '--input', input_data,
         '--region', '${REGION}',
         '--output', 'json'],
        capture_output=True, text=True
    )

    if retry_result.returncode == 0:
        new_arn = json.loads(retry_result.stdout).get('executionArn', 'unknown')
        print(f' Started: {new_arn}')
    else:
        print(f' Failed: {retry_result.stderr}')
    print()
"
}

trigger_flush() {
    echo -e "${CYAN}Creating test file to trigger orphan flush...${NC}"
    echo ""

    TODAY=$(date -u +%Y-%m-%d)
    TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
    TEST_FILE="/tmp/test-trigger-${TIMESTAMP}.ndjson"

    # Create a test NDJSON file (~3.5MB to pass validation)
    echo "Generating test file..."
    python3 -c "
import json
import random
import string

# Generate ~3.5MB of NDJSON data
target_size = 3.5 * 1024 * 1024 # 3.5 MB
current_size = 0
line_count = 0

with open('${TEST_FILE}', 'w') as f:
    while current_size < target_size:
        record = {
            'id': line_count,
            'timestamp': '${TIMESTAMP}',
            'data': ''.join(random.choices(string.ascii_letters, k=200)),
            'test': True,
            'purpose': 'trigger_orphan_flush'
        }
        line = json.dumps(record) + '\n'
        f.write(line)
        current_size += len(line)
        line_count += 1

print(f'Generated {line_count} records ({current_size / (1024*1024):.2f} MB)')
"

    # Upload to S3
    S3_KEY="pipeline/input/${TODAY}/test-trigger-${TIMESTAMP}.ndjson"
    echo "Uploading to s3://${INPUT_BUCKET}/${S3_KEY}..."

    aws s3 cp "${TEST_FILE}" "s3://${INPUT_BUCKET}/${S3_KEY}" --region "$REGION"

    rm -f "${TEST_FILE}"

    echo ""
    echo -e "${GREEN}Test file uploaded!${NC}"
    echo "This will trigger the Lambda which will:"
    echo " 1. Process the test file"
    echo " 2. Check for orphaned files from previous days"
    echo " 3. Create manifests for any pending files"
    echo ""
    echo "Check Lambda logs in a few seconds to verify the flush."
}

reset_manifested() {
    echo -e "${YELLOW}Resetting manifested files to pending...${NC}"
    echo ""

    read -p "This will reset ALL manifested files to pending. Continue? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return
    fi

    # Get all manifested files
    aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE status='manifested'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json, subprocess

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No manifested files found.')
    sys.exit(0)

print(f'Resetting {len(items)} files to pending...')

success = 0
for item in items:
    date_prefix = item.get('date_prefix', {}).get('S')
    file_key = item.get('file_key', {}).get('S')

    if not date_prefix or not file_key:
        continue

    # Update item
    result = subprocess.run([
        'aws', 'dynamodb', 'update-item',
        '--table-name', '${TABLE_NAME}',
        '--key', json.dumps({'date_prefix': {'S': date_prefix}, 'file_key': {'S': file_key}}),
        '--update-expression', 'SET #s = :status REMOVE manifest_path',
        '--expression-attribute-names', '{\"#s\": \"status\"}',
        '--expression-attribute-values', '{\":status\": {\"S\": \"pending\"}}',
        '--region', '${REGION}'
    ], capture_output=True, text=True)

    if result.returncode == 0:
        success += 1
        if success % 50 == 0:
            print(f' Reset {success}/{len(items)}...')

print(f'Reset {success} files to pending status')
"
}

reset_date() {
    local DATE="$1"

    if [ -z "$DATE" ]; then
        echo -e "${RED}Error: Please specify a date (YYYY-MM-DD)${NC}"
        return 1
    fi

    echo -e "${YELLOW}Resetting all files for ${DATE} to pending...${NC}"
    echo ""

    read -p "Continue? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return
    fi

    # Get all files for this date
    aws dynamodb execute-statement \
        --statement "SELECT file_key, status FROM \"${TABLE_NAME}\" WHERE date_prefix='${DATE}'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json, subprocess

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No files found for this date.')
    sys.exit(0)

print(f'Found {len(items)} files for ${DATE}')

success = 0
for item in items:
    file_key = item.get('file_key', {}).get('S')
    current_status = item.get('status', {}).get('S')

    if not file_key or file_key == 'MANIFEST':
        continue

    if current_status == 'pending':
        continue # Already pending

    # Update item
    result = subprocess.run([
        'aws', 'dynamodb', 'update-item',
        '--table-name', '${TABLE_NAME}',
        '--key', json.dumps({'date_prefix': {'S': '${DATE}'}, 'file_key': {'S': file_key}}),
        '--update-expression', 'SET #s = :status REMOVE manifest_path, error_message',
        '--expression-attribute-names', '{\"#s\": \"status\"}',
        '--expression-attribute-values', '{\":status\": {\"S\": \"pending\"}}',
        '--region', '${REGION}'
    ], capture_output=True, text=True)

    if result.returncode == 0:
        success += 1

print(f'Reset {success} files to pending status')
"
}

# Main command handler
case "${1:-}" in
    list-failed)
        list_failed
        ;;
    list-pending)
        list_pending
        ;;
    list-manifested)
        list_manifested
        ;;
    retry-failed)
        retry_failed
        ;;
    trigger-flush)
        trigger_flush
        ;;
    reset-manifested)
        reset_manifested
        ;;
    reset-date)
        reset_date "$2"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
