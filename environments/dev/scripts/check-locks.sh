#!/bin/bash

# Check and Clear Stuck LOCK Records
# This script helps diagnose and resolve stuck LOCK records that prevent manifest creation

set -e

ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} LOCK Record Diagnostic Tool${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. Check for LOCK records
echo -e "${CYAN}1. Checking for LOCK records...${NC}"
CURRENT_TIME=$(date +%s)

aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --filter-expression "begins_with(date_prefix, :lock_prefix)" \
  --expression-attribute-values '{":lock_prefix":{"S":"LOCK#"}}' \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
items = data.get('Items', [])
current_time = $CURRENT_TIME

if not items:
    print('No LOCK records found - pipeline is healthy')
    sys.exit(0)

print(f'Found {len(items)} LOCK record(s):')
print()

stuck_locks = []

for i, item in enumerate(items, 1):
    date_prefix = item.get('date_prefix', {}).get('S', 'N/A')
    file_key = item.get('file_key', {}).get('S', 'N/A')
    lock_owner = item.get('lock_owner', {}).get('S', 'N/A')
    ttl = int(item.get('ttl', {}).get('N', '0'))

    # Extract date from LOCK#2026-01-29
    lock_date = date_prefix.replace('LOCK#', '') if 'LOCK#' in date_prefix else 'N/A'

    # Check if expired
    time_remaining = ttl - current_time
    is_expired = time_remaining <= 0

    print(f'{i}. Lock Date: {lock_date}')
    print(f' Lock Owner: {lock_owner}')
    print(f' TTL: {ttl} ({datetime.fromtimestamp(ttl).strftime(\"%Y-%m-%d %H:%M:%S\")})')
    print(f' Current Time: {current_time} ({datetime.fromtimestamp(current_time).strftime(\"%Y-%m-%d %H:%M:%S\")})')

    if is_expired:
        print(f' Status: EXPIRED ({abs(time_remaining)} seconds ago)')
        print(f' Action: Should be auto-deleted by DynamoDB TTL (may take up to 48 hours)')
        stuck_locks.append((date_prefix, file_key))
    else:
        print(f' Status: Active ({time_remaining} seconds remaining)')
    print()

if stuck_locks:
    print('='*50)
    print('STUCK LOCKS DETECTED')
    print('='*50)
    print()
    print('Expired locks found. While DynamoDB TTL will eventually delete these,')
    print('you can manually clear them now to resume pipeline operation.')
    print()
    print('To clear stuck locks, run:')
    print(f' bash {sys.argv[0]} --clear-expired')
    print()
"

echo ""

# 2. Show pending files count
echo -e "${CYAN}2. Pending files waiting for manifest creation:${NC}"
aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --index-name "status-index" \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --select "COUNT" \
  --region "$REGION" \
  --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = data.get('Count', 0)
print(f'Total pending files: {count}')
if count >= 10:
    print('Enough files for manifest creation (threshold: 10)')
    print(' If LOCK is stuck, these files cannot be processed')
"
echo ""

# 3. Check if --clear-expired flag was passed
if [ "$1" == "--clear-expired" ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED} Clearing Expired LOCK Records${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""

    # Get expired locks
    CURRENT_TIME=$(date +%s)
    aws dynamodb scan \
      --table-name "$TABLE_NAME" \
      --filter-expression "begins_with(date_prefix, :lock_prefix)" \
      --expression-attribute-values '{":lock_prefix":{"S":"LOCK#"}}' \
      --region "$REGION" \
      --output json | python3 -c "
import sys, json
import subprocess

data = json.load(sys.stdin)
items = data.get('Items', [])
current_time = $CURRENT_TIME

expired_count = 0

for item in items:
    date_prefix = item.get('date_prefix', {}).get('S', '')
    file_key = item.get('file_key', {}).get('S', '')
    ttl = int(item.get('ttl', {}).get('N', '0'))

    if ttl <= current_time and date_prefix and file_key:
        print(f'Deleting expired LOCK: {date_prefix} / {file_key}')

        # Delete the item
        cmd = [
            'aws', 'dynamodb', 'delete-item',
            '--table-name', '$TABLE_NAME',
            '--key', json.dumps({
                'date_prefix': {'S': date_prefix},
                'file_key': {'S': file_key}
            }),
            '--region', '$REGION'
        ]

        result = subprocess.run(cmd, capture_output=True)
        if result.returncode == 0:
            print(f' Deleted successfully')
            expired_count += 1
        else:
            print(f' Failed: {result.stderr.decode()}')

if expired_count == 0:
    print('No expired locks to clear')
else:
    print()
    print(f'Cleared {expired_count} expired LOCK record(s)')
    print()
    print('Pipeline should now resume processing pending files.')
    print('Monitor with: bash trace-pipeline.sh')
"
fi

echo -e "${CYAN}========================================${NC}"
