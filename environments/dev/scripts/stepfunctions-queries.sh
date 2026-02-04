#!/bin/bash

# Step Functions Query & Diagnostic Helper
# Inspect executions, failures, and performance metrics
#
# Usage:
#   ./stepfunctions-queries.sh                    # Show menu
#   ./stepfunctions-queries.sh list               # List recent executions
#   ./stepfunctions-queries.sh running            # Show running executions
#   ./stepfunctions-queries.sh failed             # Show failed executions
#   ./stepfunctions-queries.sh details <exec-arn> # Show execution details

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
STATE_MACHINE_NAME="ndjson-parquet-processor-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get state machine ARN
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
    echo -e "${GREEN}Step Functions Query Helper${NC}"
    echo ""
    echo "State Machine: $STATE_MACHINE_NAME"
    echo "ARN: $STATE_MACHINE_ARN"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list [N]              List N most recent executions (default: 10)"
    echo "  running               Show currently running executions"
    echo "  succeeded             Show succeeded executions"
    echo "  failed                Show failed executions"
    echo "  aborted               Show aborted executions"
    echo "  details <exec-arn>    Show detailed execution info"
    echo "  history <exec-arn>    Show execution event history"
    echo "  input <exec-arn>      Show execution input"
    echo "  output <exec-arn>     Show execution output"
    echo "  errors                Show error summary from recent failures"
    echo "  stats                 Show execution statistics"
    echo "  stop <exec-arn>       Stop a running execution"
    echo "  stop-all              Stop all running executions"
    echo ""
    echo "Examples:"
    echo "  $0 list 20"
    echo "  $0 failed"
    echo "  $0 details arn:aws:states:us-east-1:123456789:execution:..."
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
from datetime import datetime

data = json.load(sys.stdin)
executions = data.get('executions', [])

if not executions:
    print('No executions found.')
    sys.exit(0)

# Color codes
colors = {
    'RUNNING': '\033[1;33m',   # Yellow
    'SUCCEEDED': '\033[0;32m', # Green
    'FAILED': '\033[0;31m',    # Red
    'ABORTED': '\033[0;35m',   # Purple
    'TIMED_OUT': '\033[0;31m', # Red
}
NC = '\033[0m'

print(f'{'Name':<40} {'Status':<12} {'Start Time':<22} {'Duration':<10}')
print('-' * 90)

for ex in executions:
    name = ex['name'][:38]
    status = ex['status']
    start = ex['startDate']
    stop = ex.get('stopDate')

    # Format times
    start_str = start[:19].replace('T', ' ')

    # Calculate duration
    if stop:
        from datetime import datetime
        try:
            start_dt = datetime.fromisoformat(start.replace('Z', '+00:00'))
            stop_dt = datetime.fromisoformat(stop.replace('Z', '+00:00'))
            duration = (stop_dt - start_dt).total_seconds()
            dur_str = f'{duration:.1f}s'
        except:
            dur_str = '-'
    else:
        dur_str = 'running...'

    color = colors.get(status, '')
    print(f'{name:<40} {color}{status:<12}{NC} {start_str:<22} {dur_str:<10}')

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

# Parse and show input
if 'input' in data:
    print('Input:')
    try:
        inp = json.loads(data['input'])
        print(json.dumps(inp, indent=2))
    except:
        print(data['input'])
    print()

# Parse and show output
if 'output' in data:
    print('Output:')
    try:
        out = json.loads(data['output'])
        print(json.dumps(out, indent=2))
    except:
        print(data['output'])
    print()

# Show error if failed
if data.get('status') == 'FAILED':
    print('Error:')
    print(f'  Cause: {data.get(\"cause\", \"N/A\")}')
    print(f'  Error: {data.get(\"error\", \"N/A\")}')
"
}

show_execution_history() {
    local exec_arn="$1"

    echo -e "${GREEN}Execution History:${NC}"
    echo ""

    aws stepfunctions get-execution-history \
        --execution-arn "$exec_arn" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
events = data.get('events', [])

# Color codes
colors = {
    'ExecutionStarted': '\033[0;32m',
    'ExecutionSucceeded': '\033[0;32m',
    'ExecutionFailed': '\033[0;31m',
    'TaskStateEntered': '\033[0;36m',
    'TaskStateExited': '\033[0;36m',
    'TaskSucceeded': '\033[0;32m',
    'TaskFailed': '\033[0;31m',
}
NC = '\033[0m'

for event in events:
    event_type = event['type']
    event_id = event['id']
    timestamp = event['timestamp'][:19].replace('T', ' ')

    color = colors.get(event_type, '')

    # Get relevant details
    details = ''
    if 'stateEnteredEventDetails' in event:
        details = f\"State: {event['stateEnteredEventDetails'].get('name', '')}\"
    elif 'stateExitedEventDetails' in event:
        details = f\"State: {event['stateExitedEventDetails'].get('name', '')}\"
    elif 'taskFailedEventDetails' in event:
        details = f\"Error: {event['taskFailedEventDetails'].get('error', '')}\"
    elif 'executionFailedEventDetails' in event:
        details = f\"Error: {event['executionFailedEventDetails'].get('error', '')}\"

    print(f'{event_id:>4} {timestamp} {color}{event_type:<30}{NC} {details}')
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

for ex in executions[:5]:  # Only show details for first 5
    arn = ex['executionArn']
    name = ex['name']

    # Get execution details
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
            ABORTED)   color=$YELLOW ;;
            TIMED_OUT) color=$RED ;;
        esac

        echo -e "  ${color}${status}${NC}: $count"
    done
    echo ""
}

stop_execution() {
    local exec_arn="$1"

    echo -e "${YELLOW}Stopping execution: $exec_arn${NC}"
    aws stepfunctions stop-execution \
        --execution-arn "$exec_arn" \
        --region "$REGION"

    echo -e "${GREEN}Execution stopped${NC}"
}

stop_all_running() {
    echo -e "${RED}WARNING: This will stop ALL running executions${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    arns=$(aws stepfunctions list-executions \
        --state-machine-arn "$STATE_MACHINE_ARN" \
        --region "$REGION" \
        --status-filter RUNNING \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ex in data.get('executions', []):
    print(ex['executionArn'])
")

    count=0
    while read -r arn; do
        if [ -n "$arn" ]; then
            echo "Stopping: $arn"
            aws stepfunctions stop-execution \
                --execution-arn "$arn" \
                --region "$REGION" 2>/dev/null || true
            ((count++))
        fi
    done <<< "$arns"

    echo -e "${GREEN}Stopped $count executions${NC}"
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
    aborted)
        list_executions "ABORTED" "${2:-10}"
        ;;
    details)
        if [ -z "$2" ]; then
            echo "Usage: $0 details <execution-arn>"
            exit 1
        fi
        show_execution_details "$2"
        ;;
    history)
        if [ -z "$2" ]; then
            echo "Usage: $0 history <execution-arn>"
            exit 1
        fi
        show_execution_history "$2"
        ;;
    input)
        if [ -z "$2" ]; then
            echo "Usage: $0 input <execution-arn>"
            exit 1
        fi
        aws stepfunctions describe-execution \
            --execution-arn "$2" \
            --region "$REGION" \
            --query 'input' \
            --output text | python3 -m json.tool
        ;;
    output)
        if [ -z "$2" ]; then
            echo "Usage: $0 output <execution-arn>"
            exit 1
        fi
        aws stepfunctions describe-execution \
            --execution-arn "$2" \
            --region "$REGION" \
            --query 'output' \
            --output text | python3 -m json.tool
        ;;
    errors)
        show_error_summary
        ;;
    stats)
        show_stats
        ;;
    stop)
        if [ -z "$2" ]; then
            echo "Usage: $0 stop <execution-arn>"
            exit 1
        fi
        stop_execution "$2"
        ;;
    stop-all)
        stop_all_running
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
