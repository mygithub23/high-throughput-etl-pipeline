#!/bin/bash

# Comprehensive Pipeline Trace
# Shows the correlation between input files, manifests, and output parquets

set -e

ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

MANIFEST_BUCKET="ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"
STATE_MACHINE_ARN="arn:aws:states:${REGION}:${AWS_ACCOUNT_ID}:stateMachine:ndjson-parquet-processor-${ENV}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Pipeline Full Trace & Correlation${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. DynamoDB Status Summary
echo -e "${CYAN}1. DynamoDB Status Summary${NC}"
aws dynamodb execute-statement \
  --statement "SELECT status FROM \"${TABLE_NAME}\"" \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
items = data.get('Items', [])
statuses = [item.get('status', {}).get('S', 'unknown') for item in items]
counts = Counter(statuses)

print(f'Total records: {len(items)}')
for status, count in sorted(counts.items()):
    print(f' {status}: {count}')
"
echo ""

# 2. MANIFEST Records (Step Functions updates these)
echo -e "${CYAN}2. MANIFEST Tracking Records${NC}"
echo "These are created by Lambda and updated by Step Functions"
aws dynamodb execute-statement \
  --statement "SELECT date_prefix, status, glue_job_run_id, completed_time, error_message FROM \"${TABLE_NAME}\" WHERE file_key='MANIFEST'" \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No MANIFEST records found!')
    sys.exit(0)

print(f'Found {len(items)} MANIFEST record(s):')
print()

for i, item in enumerate(items, 1):
    date = item.get('date_prefix', {}).get('S', 'N/A')
    status = item.get('status', {}).get('S', 'N/A')
    job_id = item.get('glue_job_run_id', {}).get('S', 'N/A')
    completed = item.get('completed_time', {}).get('S', 'N/A')
    error = item.get('error_message', {}).get('S', 'N/A')

    print(f'{i}. Date: {date}, Status: {status}')
    if job_id != 'N/A':
        print(f' Glue Job ID: {job_id}')
    if completed != 'N/A':
        print(f' Completed: {completed}')
    if error != 'N/A':
        print(f' Error: {error}')
    print()
"
echo ""

# 3. Manifest Files Created
echo -e "${CYAN}3. Manifest Files in S3${NC}"
MANIFEST_COUNT=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive | wc -l)
echo "Total manifest files: ${MANIFEST_COUNT}"

if [ "$MANIFEST_COUNT" -gt 0 ]; then
    echo "Recent manifests:"
    aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive --human-readable | tail -10
fi
echo ""

# 4. Parquet Files Created
echo -e "${CYAN}4. Parquet Files in S3${NC}"
PARQUET_COUNT=$(aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive 2>/dev/null | grep -c '\.parquet$' || echo "0")
echo "Total parquet files: ${PARQUET_COUNT}"

if [ "$PARQUET_COUNT" -gt 0 ]; then
    echo "Parquet output directories:"
    aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive | grep '\.parquet$' | awk -F'/' '{print $1"/"$2}' | sort -u
fi
echo ""

# 5. Step Functions Execution Summary
echo -e "${CYAN}5. Step Functions Executions${NC}"
aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --max-results 50 \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
executions = data.get('executions', [])

if not executions:
    print('No executions found')
    sys.exit(0)

statuses = Counter(ex['status'] for ex in executions)

print(f'Total executions: {len(executions)}')
for status, count in sorted(statuses.items()):
    print(f' {status}: {count}')

print()
print('Recent executions:')
for ex in executions[:10]:
    name = ex.get('name', 'N/A')
    status = ex.get('status', 'N/A')
    start = ex.get('startDate', 'N/A')
    print(f' {name}: {status} (started: {start})')
"
echo ""

# 6. Correlation Analysis
echo -e "${CYAN}6. Correlation Analysis${NC}"
echo "Checking if manifests -> Step Functions -> Parquet files match up..."
echo ""

# Get manifest count by date
aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive | awk '{print $4}' | while read manifest_key; do
    echo "$manifest_key"
done | awk -F'/' '{print $2}' | sort | uniq -c | python3 -c "
import sys

print('Manifests by date:')
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        count = parts[0]
        date = parts[1]
        print(f' {date}: {count} manifest(s) = {int(count) * 10} files (at 10 files per manifest)')
print()
"

# Get parquet count by date
aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive 2>/dev/null | grep '\.parquet$' | awk '{print $4}' | while read parquet_key; do
    echo "$parquet_key"
done | grep -oP 'merged-parquet-\K[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | uniq -c | python3 -c "
import sys

print('Parquet outputs by date:')
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        count = parts[0]
        date = parts[1]
        print(f' {date}: {count} parquet file(s)')
print()
" || echo "No parquet files found"

# 7. Recommendations
echo -e "${CYAN}7. Diagnostic Recommendations${NC}"
echo ""
echo "If manifests > parquet files:"
echo " -> Step Functions or Glue jobs failed"
echo " -> Check: aws stepfunctions list-executions --state-machine-arn $STATE_MACHINE_ARN --status-filter FAILED"
echo ""
echo "If many files are 'manifested' but few MANIFEST records are 'completed':"
echo " -> Step Functions UpdateStatusCompleted is failing"
echo " -> Check Step Functions execution history for errors"
echo ""
echo "If files stuck in 'pending':"
echo " -> Lambda retry loop isn't working or lock contention"
echo " -> Check Lambda logs for 'Lock contention' or 'Max retries reached'"
echo ""
echo -e "${CYAN}========================================${NC}"
