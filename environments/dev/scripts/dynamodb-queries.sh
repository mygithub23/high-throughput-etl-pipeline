#!/bin/bash

# DynamoDB PartiQL Query Helper
# Run common queries against the file tracking table
#
# Usage:
#   ./dynamodb-queries.sh                    # Show menu
#   ./dynamodb-queries.sh pending            # Show pending files
#   ./dynamodb-queries.sh status             # Show status counts
#   ./dynamodb-queries.sh date 2026-01-20    # Show files for specific date
#   ./dynamodb-queries.sh manifests          # Show manifest records
#   ./dynamodb-queries.sh delete-date 2026-01-20  # Delete all records for date

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
TABLE_NAME="ndjson-parquet-sqs-file-tracking-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}DynamoDB PartiQL Query Helper${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  pending              Show all pending files"
    echo "  manifested           Show all manifested files"
    echo "  processing           Show files being processed"
    echo "  completed            Show completed files"
    echo "  failed               Show failed files"
    echo "  status               Show file count by status"
    echo "  date <YYYY-MM-DD>    Show all files for a specific date"
    echo "  manifests            Show all MANIFEST records"
    echo "  locks                Show all LOCK records"
    echo "  recent [N]           Show N most recent files (default: 20)"
    echo "  delete-date <date>   Delete all records for a specific date"
    echo "  delete-status <s>    Delete all records with given status"
    echo "  cleanup-locks        Delete all expired LOCK records"
    echo "  raw <partiql>        Execute raw PartiQL query"
    echo ""
    echo "Examples:"
    echo "  $0 pending"
    echo "  $0 date 2026-01-20"
    echo "  $0 delete-date 2025-12-25"
    echo "  $0 raw \"SELECT * FROM \\\"${TABLE_NAME}\\\" WHERE status='failed'\""
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
from datetime import datetime

data = json.load(sys.stdin)
items = data.get('Items', [])

if not items:
    print('No results found.')
    sys.exit(0)

# Convert DynamoDB format to readable format
def parse_value(v):
    if 'S' in v: return v['S']
    if 'N' in v: return v['N']
    if 'BOOL' in v: return str(v['BOOL'])
    if 'NULL' in v: return 'NULL'
    if 'L' in v: return str([parse_value(i) for i in v['L']])
    if 'M' in v: return str({k: parse_value(vv) for k, vv in v['M'].items()})
    return str(v)

# Print results
for i, item in enumerate(items):
    print(f'--- Record {i+1} ---')
    for key, value in item.items():
        print(f'  {key}: {parse_value(value)}')
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

# Convert DynamoDB format
def parse_value(v):
    if 'S' in v: return v['S']
    if 'N' in v: return v['N']
    if 'BOOL' in v: return str(v['BOOL'])
    return str(v)

# Get all keys
all_keys = set()
for item in items:
    all_keys.update(item.keys())

# Priority order for columns
priority = ['date_prefix', 'file_key', 'status', 'file_size_mb', 'created_at', 'updated_at']
cols = [k for k in priority if k in all_keys] + sorted([k for k in all_keys if k not in priority])

# Print header
header = ' | '.join(f'{c[:15]:15}' for c in cols[:6])
print(header)
print('-' * len(header))

# Print rows
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

    # Use begins_with to match sharded statuses (e.g. pending#0 .. pending#9)
    for status in pending manifested processing completed failed; do
        query="SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, '${status}')"
        count=$(aws dynamodb execute-statement \
            --statement "$query" \
            --region "$REGION" \
            --output json | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))")

        case $status in
            pending)    color=$YELLOW ;;
            manifested) color=$CYAN ;;
            processing) color=$YELLOW ;;
            completed)  color=$GREEN ;;
            failed)     color=$RED ;;
        esac

        echo -e "  ${color}${status}${NC}: $count"
    done
    echo ""
}

delete_by_date() {
    local date_prefix="$1"

    echo -e "${RED}WARNING: This will delete ALL records for date: ${date_prefix}${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    # First, get all file_keys for this date
    echo "Finding records..."
    keys=$(aws dynamodb execute-statement \
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
            echo "  Deleting: $dp / $fk"
            aws dynamodb delete-item \
                --table-name "$TABLE_NAME" \
                --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                --region "$REGION"
            ((count++))
        fi
    done <<< "$keys"

    echo -e "${GREEN}Deleted $count records${NC}"
}

# Main command handler
case "${1:-help}" in
    pending)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, 'pending')"
        ;;
    manifested)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, 'manifested')"
        ;;
    processing)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, 'processing')"
        ;;
    completed)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, 'completed')"
        ;;
    failed)
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(status, 'failed')"
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
        run_partiql "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(file_key, 'MANIFEST#')"
        ;;
    locks)
        run_partiql "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(file_key, 'LOCK#')"
        ;;
    recent)
        limit=${2:-20}
        # Note: PartiQL doesn't support ORDER BY with LIMIT well, so we get all and filter
        run_partiql_table "SELECT * FROM \"${TABLE_NAME}\""
        ;;
    delete-date)
        if [ -z "$2" ]; then
            echo "Usage: $0 delete-date <YYYY-MM-DD>"
            exit 1
        fi
        delete_by_date "$2"
        ;;
    delete-status)
        if [ -z "$2" ]; then
            echo "Usage: $0 delete-status <status>"
            echo "  e.g. $0 delete-status failed"
            echo "  Matches sharded values too (failed#0, failed#1, ...)"
            exit 1
        fi
        target_status="$2"
        echo -e "${RED}WARNING: This will delete ALL records with status beginning with: ${target_status}${NC}"
        read -p "Are you sure? (type 'yes' to confirm): " confirm

        if [ "$confirm" != "yes" ]; then
            echo "Aborted."
            exit 0
        fi

        echo "Finding records..."
        keys=$(aws dynamodb execute-statement \
            --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE begins_with(status, '${target_status}')" \
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
                echo "  Deleting: $dp / $fk"
                aws dynamodb delete-item \
                    --table-name "$TABLE_NAME" \
                    --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                    --region "$REGION"
                ((count++))
            fi
        done <<< "$keys"

        echo -e "${GREEN}Deleted $count records${NC}"
        ;;
    cleanup-locks)
        echo "Finding expired LOCK records..."
        current_time=$(date +%s)
        run_partiql "SELECT * FROM \"${TABLE_NAME}\" WHERE begins_with(file_key, 'LOCK')"
        echo ""
        echo -e "${YELLOW}Note: Manually delete expired locks using delete-item${NC}"
        ;;
    raw)
        if [ -z "$2" ]; then
            echo "Usage: $0 raw '<partiql-query>'"
            exit 1
        fi
        run_partiql "$2"
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
