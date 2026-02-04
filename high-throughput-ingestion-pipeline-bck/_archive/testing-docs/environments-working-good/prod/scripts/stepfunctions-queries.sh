#!/bin/bash

# Step Functions Query Helper - PRODUCTION
# Inspect executions, failures, and performance metrics

set -e

# Configuration - PRODUCTION
ENV="prod"
REGION="us-east-1"
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}⚠️  PRODUCTION ENVIRONMENT${NC}"
echo ""

get_state_machine_arn() {
    aws stepfunctions list-state-machines \
        --region "$REGION" \
        --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" \
        --output text
}

STATE_MACHINE_ARN=$(get_state_machine_arn)

if [ -z "$STATE_MACHINE_ARN" ]; then
    echo -e "${RED}Error: State machine '${STATE_MACHINE_NAME}' not found${NC}"
    exit 1
fi

show_help() {
    echo -e "${GREEN}Step Functions Query Helper (PROD)${NC}"
    echo ""
    echo "State Machine: $STATE_MACHINE_NAME"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list [N]              List N most recent executions (default: 10)"
    echo "  running               Show currently running executions"
    echo "  succeeded             Show succeeded executions"
    echo "  failed                Show failed executions"
    echo "  details <exec-arn>    Show detailed execution info"
    echo "  errors                Show error summary from recent failures"
    echo "  stats                 Show execution statistics"
    echo ""
    echo "Note: Stop operations are not available in production without confirmation"
    echo ""
}

list_executions() {
    local status_filter="$1"
    local max_results="${2:-10}"

    local filter_arg=""
    if [ -n "$status_filter" ]; then
        filter_arg="--status-filter $status_filter"
    fi

    echo -e "${GREEN}Executions (${status_filter:-ALL}):${NC}"
    echo ""

    aws stepfunctions list-executions \
        --state-machine-arn "$STATE_MACHINE_ARN" \
        --region "$REGION" \
        --max-results "$max_results" \
        $filter_arg \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
executions = data.get('executions', [])

if not executions:
    print('No executions found.')
    sys.exit(0)

colors = {
    'RUNNING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
    'ABORTED': '\033[0;35m',
}
NC = '\033[0m'

print(f'{'Name':<40} {'Status':<12} {'Start Time':<22}')
print('-' * 80)

for ex in executions:
    name = ex['name'][:38]
    status = ex['status']
    start = ex['startDate'][:19].replace('T', ' ')

    color = colors.get(status, '')
    print(f'{name:<40} {color}{status:<12}{NC} {start:<22}')

print()
print(f'Total: {len(executions)} executions')
"
}

show_execution_details() {
    local exec_arn="$1"

    echo -e "${GREEN}Execution Details:${NC}"
    echo ""

    aws stepfunctions describe-execution \
        --execution-arn "$exec_arn" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)

print(f'Name:       {data.get(\"name\", \"N/A\")}')
print(f'Status:     {data.get(\"status\", \"N/A\")}')
print(f'Start:      {data.get(\"startDate\", \"N/A\")}')
print(f'Stop:       {data.get(\"stopDate\", \"N/A\")}')
print()

if 'input' in data:
    print('Input:')
    try:
        inp = json.loads(data['input'])
        print(json.dumps(inp, indent=2))
    except:
        print(data['input'])
    print()

if data.get('status') == 'FAILED':
    print('Error:')
    print(f'  Cause: {data.get(\"cause\", \"N/A\")}')
    print(f'  Error: {data.get(\"error\", \"N/A\")}')
"
}

show_error_summary() {
    echo -e "${GREEN}Error Summary from Recent Failures:${NC}"
    echo ""

    aws stepfunctions list-executions \
        --state-machine-arn "$STATE_MACHINE_ARN" \
        --region "$REGION" \
        --status-filter FAILED \
        --max-results 10 \
        --output json | python3 -c "
import sys, json, subprocess

data = json.load(sys.stdin)
executions = data.get('executions', [])

if not executions:
    print('No failed executions found.')
    sys.exit(0)

print(f'Found {len(executions)} failed executions:')
print()

for ex in executions[:5]:
    arn = ex['executionArn']
    name = ex['name']

    result = subprocess.run(
        ['aws', 'stepfunctions', 'describe-execution',
         '--execution-arn', arn,
         '--region', 'us-east-1',
         '--output', 'json'],
        capture_output=True, text=True
    )

    if result.returncode == 0:
        details = json.loads(result.stdout)
        error = details.get('error', 'N/A')
        cause = details.get('cause', 'N/A')

        print(f'Execution: {name}')
        print(f'  Error: {error}')
        print(f'  Cause: {cause[:200]}...' if len(cause) > 200 else f'  Cause: {cause}')
        print()
"
}

show_stats() {
    echo -e "${GREEN}Execution Statistics:${NC}"
    echo ""

    for status in RUNNING SUCCEEDED FAILED ABORTED TIMED_OUT; do
        count=$(aws stepfunctions list-executions \
            --state-machine-arn "$STATE_MACHINE_ARN" \
            --region "$REGION" \
            --status-filter "$status" \
            --output json | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('executions',[])))")

        case $status in
            RUNNING)   color=$YELLOW ;;
            SUCCEEDED) color=$GREEN ;;
            FAILED)    color=$RED ;;
            *)         color=$NC ;;
        esac

        echo -e "  ${color}${status}${NC}: $count"
    done
    echo ""
}

# Main command handler
case "${1:-help}" in
    list)
        list_executions "" "${2:-10}"
        ;;
    running)
        list_executions "RUNNING" "${2:-20}"
        ;;
    succeeded)
        list_executions "SUCCEEDED" "${2:-10}"
        ;;
    failed)
        list_executions "FAILED" "${2:-10}"
        ;;
    details)
        if [ -z "$2" ]; then
            echo "Usage: $0 details <execution-arn>"
            exit 1
        fi
        show_execution_details "$2"
        ;;
    errors)
        show_error_summary
        ;;
    stats)
        show_stats
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
