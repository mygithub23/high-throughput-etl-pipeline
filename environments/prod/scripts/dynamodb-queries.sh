#!/bin/bash

# DynamoDB PartiQL Query Helper - PRODUCTION
# Run common queries against the file tracking table
#
# Usage:
# ./dynamodb-queries.sh # Show menu
# ./dynamodb-queries.sh pending # Show pending files
# ./dynamodb-queries.sh status # Show status counts

set -e

# Configuration - PRODUCTION
ENV="prod"
REGION="us-east-1"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}PRODUCTION ENVIRONMENT${NC}"
echo ""

show_help() {
    echo -e "${GREEN}DynamoDB PartiQL Query Helper (PROD)${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo " pending Show all pending files"
    echo " manifested Show all manifested files"
    echo " processing Show files being processed"
    echo " completed Show completed files"
    echo " failed Show failed files"
    echo " status Show file count by status"
    echo " date <YYYY-MM-DD> Show all files for a specific date"
    echo " manifests Show all MANIFEST records"
    echo " recent [N] Show N most recent files (default: 20)"
    echo ""
    echo "Note: Destructive operations (delete) are not available in production"
    echo ""
}

run_partiql() {
    local query="$1"
    echo -e "${CYAN}Query:${NC} $query"
    echo ""
    aws dynamodb execute-statement \
        --statement "$query" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No results found.')
    sys.exit(0)

def parse_value(v):
    if 'S' in v: return v['S']
    if 'N' in v: return v['N']
    if 'BOOL' in v: return str(v['BOOL'])
    return str(v)

for i, item in enumerate(items):
    print(f'--- Record {i+1} ---')
    for key, value in item.items():
        print(f' {key}: {parse_value(value)}')
    print()

print(f'Total: {len(items)} records')
"
}

run_partiql_table() {
    local query="$1"
    echo -e "${CYAN}Query:${NC} $query"
    echo ""
    aws dynamodb execute-statement \
        --statement "$query" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No results found.')
    sys.exit(0)

def parse_value(v):
    if 'S' in v: return v['S']
    if 'N' in v: return v['N']
    return str(v)

all_keys = set()
for item in items:
    all_keys.update(item.keys())

priority = ['date_prefix', 'file_key', 'status', 'file_size_mb', 'created_at', 'updated_at']
cols = [k for k in priority if k in all_keys] + sorted([k for k in all_keys if k not in priority])

header = ' | '.join(f'{c[:15]:15}' for c in cols[:6])
print(header)
print('-' * len(header))

for item in items:
    row = ' | '.join(f'{str(parse_value(item.get(c, {\"S\": \"-\"})))[:15]:15}' for c in cols[:6])
    print(row)

print()
print(f'Total: {len(items)} records')
"
}

count_by_status() {
    echo -e "${GREEN}File counts by status:${NC}"
    echo ""

    for status in pending manifested processing completed failed; do
        query="SELECT * FROM \"${TABLE_NAME}\" WHERE status='${status}'"
        count=$(aws dynamodb execute-statement \
            --statement "$query" \
            --region "$REGION" \
            --output json | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))")

        case $status in
            pending) color=$YELLOW ;;
            manifested) color=$CYAN ;;
            processing) color=$YELLOW ;;
            completed) color=$GREEN ;;
            failed) color=$RED ;;
        esac

        echo -e " ${color}${status}${NC}: $count"
    done
    echo ""
}

# Main command handler
case "${1:-help}" in
    pending)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE status='pending'"
        ;;
    manifested)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE status='manifested'"
        ;;
    processing)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE status='processing'"
        ;;
    completed)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE status='completed'"
        ;;
    failed)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE status='failed'"
        ;;
    status)
        count_by_status
        ;;
    date)
        if [ -z "$2" ]; then
            echo "Usage: $0 date <YYYY-MM-DD>"
            exit 1
        fi
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE date_prefix='$2'"
        ;;
    manifests)
        run_partiql "SELECT * FROM \"${TABLE_NAME}\" WHERE file_key='MANIFEST'"
        ;;
    recent)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\""
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
