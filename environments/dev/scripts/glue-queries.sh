#!/bin/bash

# Glue Job Query & Diagnostic Helper
# Inspect job runs, errors, metrics, and logs
#
# Usage:
# ./glue-queries.sh # Show menu
# ./glue-queries.sh list # List recent job runs
# ./glue-queries.sh running # Show running jobs
# ./glue-queries.sh failed # Show failed jobs
# ./glue-queries.sh logs <run-id> # Show job logs

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
JOB_NAME="ndjson-parquet-batch-job-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${GREEN}Glue Job Query Helper${NC}"
    echo ""
    echo "Job Name: $JOB_NAME"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo " list [N] List N most recent job runs (default: 10)"
    echo " running Show currently running jobs"
    echo " succeeded Show succeeded jobs"
    echo " failed Show failed jobs"
    echo " details <run-id> Show detailed job run info"
    echo " logs <run-id> Show CloudWatch logs for a job run"
    echo " errors Show error messages from recent failures"
    echo " stats Show job run statistics"
    echo " metrics <run-id> Show job metrics (workers, duration, etc.)"
    echo " stop <run-id> Stop a running job"
    echo " stop-all Stop all running jobs"
    echo " config Show job configuration"
    echo ""
    echo "Examples:"
    echo " $0 list 20"
    echo " $0 failed"
    echo " $0 logs jr_abc123def456"
    echo ""
}

list_job_runs() {
    local max_results="${1:-10}"

    echo -e "${GREEN}Recent Job Runs (${JOB_NAME}):${NC}"
    echo ""

    aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --max-results "$max_results" \
        --output json | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
runs = data.get('JobRuns', [])

if not runs:
    print('No job runs found.')
    sys.exit(0)

# Color codes
colors = {
    'RUNNING': '\033[1;33m',
    'STARTING': '\033[1;33m',
    'STOPPING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
    'STOPPED': '\033[0;35m',
    'TIMEOUT': '\033[0;31m',
    'ERROR': '\033[0;31m',
}
NC = '\033[0m'

print(f'{'Run ID':<45} {'Status':<12} {'Started':<20} {'Duration':<10} {'Workers'}')
print('-' * 100)

for run in runs:
    run_id = run['Id'][:43]
    status = run['JobRunState']
    started = run.get('StartedOn', '')
    if started:
        started = str(started)[:19]
    exec_time = run.get('ExecutionTime', 0)
    workers = run.get('NumberOfWorkers', 'N/A')

    duration = f'{exec_time}s' if exec_time else '-'

    color = colors.get(status, '')
    print(f'{run_id:<45} {color}{status:<12}{NC} {started:<20} {duration:<10} {workers}')

print()
print(f'Total: {len(runs)} runs')
"
}

list_by_status() {
    local status="$1"
    local max_results="${2:-10}"

    echo -e "${GREEN}Job Runs with status: ${status}${NC}"
    echo ""

    aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --max-results 50 \
        --output json | python3 -c "
import sys, json

status_filter = '$status'
max_results = $max_results

data = json.load(sys.stdin)
runs = [r for r in data.get('JobRuns', []) if r['JobRunState'] == status_filter][:max_results]

if not runs:
    print(f'No {status_filter} job runs found.')
    sys.exit(0)

for run in runs:
    print(f\"Run ID: {run['Id']}\")
    print(f\" Started: {run.get('StartedOn', 'N/A')}\")
    print(f\" Duration: {run.get('ExecutionTime', 0)}s\")
    print(f\" Workers: {run.get('NumberOfWorkers', 'N/A')}\")

    if run['JobRunState'] == 'FAILED':
        print(f\" Error: {run.get('ErrorMessage', 'N/A')[:100]}...\")
    print()

print(f'Total: {len(runs)} runs')
"
}

show_job_details() {
    local run_id="$1"

    echo -e "${GREEN}Job Run Details:${NC}"
    echo ""

    aws glue get-job-run \
        --job-name "$JOB_NAME" \
        --run-id "$run_id" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
run = data.get('JobRun', {})

print(f\"Run ID: {run.get('Id', 'N/A')}\")
print(f\"Status: {run.get('JobRunState', 'N/A')}\")
print(f\"Started: {run.get('StartedOn', 'N/A')}\")
print(f\"Completed: {run.get('CompletedOn', 'N/A')}\")
print(f\"Execution Time: {run.get('ExecutionTime', 0)} seconds\")
print(f\"Workers: {run.get('NumberOfWorkers', 'N/A')}\")
print(f\"Worker Type: {run.get('WorkerType', 'N/A')}\")
print(f\"Max Capacity: {run.get('MaxCapacity', 'N/A')} DPUs\")
print(f\"Glue Version: {run.get('GlueVersion', 'N/A')}\")
print()

# Arguments
args = run.get('Arguments', {})
if args:
    print('Arguments:')
    for k, v in args.items():
        print(f' {k}: {v}')
    print()

# Error message
if run.get('JobRunState') == 'FAILED':
    print('Error Message:')
    print(f\" {run.get('ErrorMessage', 'N/A')}\")
"
}

show_job_logs() {
    local run_id="$1"

    echo -e "${GREEN}CloudWatch Logs for Job Run: ${run_id}${NC}"
    echo ""

    LOG_GROUP="/aws-glue/jobs"
    LOG_STREAM="${JOB_NAME}/${run_id}"

    # Check if log stream exists
    if ! aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name-prefix "$LOG_STREAM" \
        --region "$REGION" \
        --output json | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('logStreams') else 1)" 2>/dev/null; then

        echo "Log stream not found. Trying alternate format..."
        LOG_STREAM="$run_id"
    fi

    echo "Log Group: $LOG_GROUP"
    echo "Log Stream: $LOG_STREAM"
    echo ""

    aws logs get-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name "$LOG_STREAM" \
        --region "$REGION" \
        --limit 100 \
        --output json 2>/dev/null | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
events = data.get('events', [])

if not events:
    print('No log events found.')
    sys.exit(0)

for event in events:
    ts = event.get('timestamp', 0)
    msg = event.get('message', '').strip()

    # Format timestamp
    if ts:
        dt = datetime.fromtimestamp(ts / 1000)
        ts_str = dt.strftime('%Y-%m-%d %H:%M:%S')
    else:
        ts_str = 'N/A'

    # Color errors
    if 'ERROR' in msg or 'Exception' in msg:
        print(f'\033[0;31m{ts_str} {msg}\033[0m')
    elif 'WARN' in msg:
        print(f'\033[1;33m{ts_str} {msg}\033[0m')
    else:
        print(f'{ts_str} {msg}')
" || echo "Could not retrieve logs. Try: aws logs tail $LOG_GROUP --filter-pattern \"$run_id\""
}

show_error_summary() {
    echo -e "${GREEN}Error Summary from Recent Failures:${NC}"
    echo ""

    aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --max-results 20 \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
failed = [r for r in data.get('JobRuns', []) if r['JobRunState'] == 'FAILED'][:5]

if not failed:
    print('No failed jobs found.')
    sys.exit(0)

print(f'Found {len(failed)} recent failures:')
print()

for run in failed:
    print(f\"Run ID: {run['Id']}\")
    print(f\" Started: {run.get('StartedOn', 'N/A')}\")
    print(f\" Error: {run.get('ErrorMessage', 'No error message')}\")
    print()
"
}

show_stats() {
    echo -e "${GREEN}Job Run Statistics:${NC}"
    echo ""

    aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --max-results 100 \
        --output json | python3 -c "
import sys, json
from collections import Counter

data = json.load(sys.stdin)
runs = data.get('JobRuns', [])

if not runs:
    print('No job runs found.')
    sys.exit(0)

# Count by status
status_counts = Counter(r['JobRunState'] for r in runs)

# Calculate duration stats for completed jobs
durations = [r.get('ExecutionTime', 0) for r in runs if r.get('ExecutionTime')]

colors = {
    'RUNNING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
    'STOPPED': '\033[0;35m',
}
NC = '\033[0m'

print('Status Counts:')
for status, count in status_counts.most_common():
    color = colors.get(status, '')
    print(f' {color}{status}{NC}: {count}')
print()

if durations:
    print('Duration Statistics:')
    print(f' Average: {sum(durations)/len(durations):.1f}s')
    print(f' Min: {min(durations)}s')
    print(f' Max: {max(durations)}s')
    print()

# Success rate
succeeded = status_counts.get('SUCCEEDED', 0)
failed = status_counts.get('FAILED', 0)
total = succeeded + failed
if total > 0:
    rate = (succeeded / total) * 100
    print(f'Success Rate: {rate:.1f}% ({succeeded}/{total})')
"
}

show_job_config() {
    echo -e "${GREEN}Job Configuration:${NC}"
    echo ""

    aws glue get-job \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
job = data.get('Job', {})

print(f\"Name: {job.get('Name', 'N/A')}\")
print(f\"Role: {job.get('Role', 'N/A').split('/')[-1]}\")
print(f\"Glue Version: {job.get('GlueVersion', 'N/A')}\")
print(f\"Worker Type: {job.get('WorkerType', 'N/A')}\")
print(f\"Number of Workers: {job.get('NumberOfWorkers', 'N/A')}\")
print(f\"Max Capacity: {job.get('MaxCapacity', 'N/A')} DPUs\")
print(f\"Timeout: {job.get('Timeout', 'N/A')} minutes\")
print(f\"Max Retries: {job.get('MaxRetries', 'N/A')}\")
print(f\"Max Concurrent: {job.get('ExecutionProperty', {}).get('MaxConcurrentRuns', 'N/A')}\")
print()

# Default arguments
args = job.get('DefaultArguments', {})
if args:
    print('Default Arguments:')
    for k, v in sorted(args.items()):
        print(f' {k}: {v}')
"
}

stop_job() {
    local run_id="$1"

    echo -e "${YELLOW}Stopping job run: $run_id${NC}"

    aws glue batch-stop-job-run \
        --job-name "$JOB_NAME" \
        --job-run-ids "$run_id" \
        --region "$REGION"

    echo -e "${GREEN}Stop request sent${NC}"
}

stop_all_jobs() {
    echo -e "${RED}WARNING: This will stop ALL running Glue jobs${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    run_ids=$(aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('JobRuns', []):
    if r['JobRunState'] in ['RUNNING', 'STARTING']:
        print(r['Id'])
")

    count=0
    while read -r run_id; do
        if [ -n "$run_id" ]; then
            echo "Stopping: $run_id"
            aws glue batch-stop-job-run \
                --job-name "$JOB_NAME" \
                --job-run-ids "$run_id" \
                --region "$REGION" 2>/dev/null || true
            ((count++))
        fi
    done <<< "$run_ids"

    echo -e "${GREEN}Stopped $count jobs${NC}"
}

# Main command handler
case "${1:-help}" in
    list)
        list_job_runs "${2:-10}"
        ;;
    running)
        list_by_status "RUNNING" "${2:-10}"
        ;;
    succeeded)
        list_by_status "SUCCEEDED" "${2:-10}"
        ;;
    failed)
        list_by_status "FAILED" "${2:-10}"
        ;;
    details)
        if [ -z "$2" ]; then
            echo "Usage: $0 details <run-id>"
            exit 1
        fi
        show_job_details "$2"
        ;;
    logs)
        if [ -z "$2" ]; then
            echo "Usage: $0 logs <run-id>"
            exit 1
        fi
        show_job_logs "$2"
        ;;
    errors)
        show_error_summary
        ;;
    stats)
        show_stats
        ;;
    metrics)
        if [ -z "$2" ]; then
            echo "Usage: $0 metrics <run-id>"
            exit 1
        fi
        show_job_details "$2"
        ;;
    config)
        show_job_config
        ;;
    stop)
        if [ -z "$2" ]; then
            echo "Usage: $0 stop <run-id>"
            exit 1
        fi
        stop_job "$2"
        ;;
    stop-all)
        stop_all_jobs
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
