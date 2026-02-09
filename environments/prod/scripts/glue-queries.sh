#!/bin/bash

# Glue Job Query Helper - PRODUCTION
# Inspect job runs, errors, metrics, and logs

set -e

# Configuration - PRODUCTION
ENV="prod"
REGION="us-east-1"
JOB_NAME="ndjson-parquet-batch-job-${ENV}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}PRODUCTION ENVIRONMENT${NC}"
echo ""

show_help() {
    echo -e "${GREEN}Glue Job Query Helper (PROD)${NC}"
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
    echo " config Show job configuration"
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

data = json.load(sys.stdin)
runs = data.get('JobRuns', [])

if not runs:
    print('No job runs found.')
    sys.exit(0)

colors = {
    'RUNNING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
}
NC = '\033[0m'

print(f'{'Run ID':<45} {'Status':<12} {'Started':<20} {'Duration':<10}')
print('-' * 95)

for run in runs:
    run_id = run['Id'][:43]
    status = run['JobRunState']
    started = str(run.get('StartedOn', ''))[:19]
    exec_time = run.get('ExecutionTime', 0)

    duration = f'{exec_time}s' if exec_time else '-'
    color = colors.get(status, '')
    print(f'{run_id:<45} {color}{status:<12}{NC} {started:<20} {duration:<10}')

print()
print(f'Total: {len(runs)} runs')
"
}

list_by_status() {
    local status="$1"

    echo -e "${GREEN}Job Runs with status: ${status}${NC}"
    echo ""

    aws glue get-job-runs \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --max-results 50 \
        --output json | python3 -c "
import sys, json

status_filter = '$status'

data = json.load(sys.stdin)
runs = [r for r in data.get('JobRuns', []) if r['JobRunState'] == status_filter][:10]

if not runs:
    print(f'No {status_filter} job runs found.')
    sys.exit(0)

for run in runs:
    print(f\"Run ID: {run['Id']}\")
    print(f\" Started: {run.get('StartedOn', 'N/A')}\")
    print(f\" Duration: {run.get('ExecutionTime', 0)}s\")
    if run['JobRunState'] == 'FAILED':
        print(f\" Error: {run.get('ErrorMessage', 'N/A')[:100]}...\")
    print()
"
}

show_job_details() {
    local run_id="$1"

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
print()

args = run.get('Arguments', {})
if args:
    print('Arguments:')
    for k, v in args.items():
        print(f' {k}: {v}')

if run.get('JobRunState') == 'FAILED':
    print()
    print('Error Message:')
    print(f\" {run.get('ErrorMessage', 'N/A')}\")
"
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

status_counts = Counter(r['JobRunState'] for r in runs)
durations = [r.get('ExecutionTime', 0) for r in runs if r.get('ExecutionTime')]

colors = {
    'RUNNING': '\033[1;33m',
    'SUCCEEDED': '\033[0;32m',
    'FAILED': '\033[0;31m',
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
"
}

show_job_config() {
    aws glue get-job \
        --job-name "$JOB_NAME" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
job = data.get('Job', {})

print(f\"Name: {job.get('Name', 'N/A')}\")
print(f\"Glue Version: {job.get('GlueVersion', 'N/A')}\")
print(f\"Worker Type: {job.get('WorkerType', 'N/A')}\")
print(f\"Number of Workers: {job.get('NumberOfWorkers', 'N/A')}\")
print(f\"Timeout: {job.get('Timeout', 'N/A')} minutes\")
print(f\"Max Concurrent: {job.get('ExecutionProperty', {}).get('MaxConcurrentRuns', 'N/A')}\")
"
}

# Main command handler
case "${1:-help}" in
    list)
        list_job_runs "${2:-10}"
        ;;
    running)
        list_by_status "RUNNING"
        ;;
    succeeded)
        list_by_status "SUCCEEDED"
        ;;
    failed)
        list_by_status "FAILED"
        ;;
    details)
        if [ -z "$2" ]; then
            echo "Usage: $0 details <run-id>"
            exit 1
        fi
        show_job_details "$2"
        ;;
    errors)
        show_error_summary
        ;;
    stats)
        show_stats
        ;;
    config)
        show_job_config
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
