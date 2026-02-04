#!/bin/bash

# Check MANIFEST Records Only
# These are the meta-records that track batch processing through Step Functions

set -e

ENV="dev"
REGION="us-east-1"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   MANIFEST Records Analysis${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

echo -e "${CYAN}Querying DynamoDB for all MANIFEST records...${NC}"
echo ""

aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --filter-expression "begins_with(file_key, :manifest_prefix) OR file_key = :old_manifest_key" \
  --expression-attribute-values '{":manifest_prefix":{"S":"MANIFEST#"}, ":old_manifest_key":{"S":"MANIFEST"}}' \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('❌ No MANIFEST records found!')
    sys.exit(0)

print(f'Total MANIFEST records: {len(items)}')
print()

# Count by status
statuses = Counter()
for item in items:
    status = item.get('status', {}).get('S', 'no-status')
    statuses[status] += 1

print('MANIFEST Records by Status:')
for status, count in sorted(statuses.items()):
    print(f'  {status}: {count}')
print()

# Show details
print('='*80)
print('MANIFEST Record Details:')
print('='*80)

for i, item in enumerate(sorted(items, key=lambda x: x.get('date_prefix', {}).get('S', '')), 1):
    date_prefix = item.get('date_prefix', {}).get('S', 'N/A')
    status = item.get('status', {}).get('S', 'N/A')
    file_count = item.get('file_count', {}).get('N', 'N/A')
    manifest_path = item.get('manifest_path', {}).get('S', 'N/A')
    glue_job_run_id = item.get('glue_job_run_id', {}).get('S', 'N/A')
    completed_time = item.get('completed_time', {}).get('S', 'N/A')
    error_message = item.get('error_message', {}).get('S', 'N/A')

    print(f'{i}. Date: {date_prefix}')
    print(f'   Status: {status}')
    print(f'   Files: {file_count}')
    print(f'   Manifest: {manifest_path.split(\"/\")[-1] if manifest_path != \"N/A\" else \"N/A\"}')

    if glue_job_run_id != 'N/A':
        print(f'   Glue Job ID: {glue_job_run_id[:50]}...')

    if completed_time != 'N/A':
        print(f'   Completed: {completed_time}')

    if error_message != 'N/A':
        print(f'   ❌ Error: {error_message[:100]}...')

    print()
"

echo ""
echo -e "${CYAN}========================================${NC}"
echo ""
echo "Expected counts based on pipeline activity:"
echo "  - 15 manifests created for 2026-01-29"
echo "  - 43 Step Functions executions succeeded"
echo "  - Should have ~43-50 MANIFEST records total (including old dates)"
echo "  - Most should be 'completed' if Step Functions updated them"
echo ""
