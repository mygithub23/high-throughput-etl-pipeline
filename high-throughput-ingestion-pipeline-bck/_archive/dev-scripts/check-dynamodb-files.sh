#!/bin/bash

# Check Files in DynamoDB Tracking Table
# Shows what files Lambda has tracked and their status

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
TABLE_NAME="${STACK_NAME}-file-tracking"
DATE_PREFIX=$(date +%Y-%m-%d)

echo -e "${GREEN}Checking DynamoDB File Tracking Table${NC}"
echo "Table: $TABLE_NAME"
echo "Date: $DATE_PREFIX"
echo ""

# Scan for today's files
echo -e "${YELLOW}Files tracked for today:${NC}"
aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values "{\":date\":{\"S\":\"$DATE_PREFIX\"}}" \
  --region $REGION \
  --query 'Items[*].{FileName:file_name.S,Status:status.S,SizeMB:file_size_mb.N,CreatedAt:created_at.S}' \
  --output table

echo ""

# Count by status
echo -e "${YELLOW}File counts by status:${NC}"
aws dynamodb query \
  --table-name "$TABLE_NAME" \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values "{\":date\":{\"S\":\"$DATE_PREFIX\"}}" \
  --region $REGION \
  --output json | python -c "
import sys, json
data = json.load(sys.stdin)
statuses = {}
total_size = 0
for item in data.get('Items', []):
    status = item.get('status', {}).get('S', 'unknown')
    size_mb = float(item.get('file_size_mb', {}).get('N', 0))
    statuses[status] = statuses.get(status, 0) + 1
    total_size += size_mb

print('Status counts:')
for status, count in statuses.items():
    print(f'  {status}: {count}')
print(f'\nTotal size: {total_size:.4f} MB ({total_size/1024:.6f} GB)')
print(f'Batch threshold: 0.001 GB (1 MB)')
print(f'Ready to create manifest: {\"YES\" if total_size/1024 >= 0.001 else \"NO\"}')
"

echo ""
echo -e "${GREEN}DynamoDB check complete${NC}"
