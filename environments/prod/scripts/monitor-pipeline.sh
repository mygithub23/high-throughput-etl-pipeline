#!/bin/bash

# Production Pipeline Monitoring
# Real-time monitoring for 338K files/day scale

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}=== Production Pipeline Monitoring ===${NC}"
echo "Time: $(date)"
echo "Account: $AWS_ACCOUNT_ID"
echo ""

# 1. Current Processing Rate
echo -e "${YELLOW}1. Current Processing Rate${NC}"
echo "----------------------------------------"

# Files uploaded in last hour
FILES_LAST_HOUR=$(aws s3 ls s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}/ --recursive --region $REGION | \
  awk '{print $1" "$2}' | \
  awk -v date="$(date -u -d '1 hour ago' '+%Y-%m-%d %H:%M')" '$0 > date' | \
  wc -l)

echo "Files uploaded (last hour): $FILES_LAST_HOUR"

if [ $FILES_LAST_HOUR -gt 7000 ]; then
    echo -e "${RED}PEAK LOAD! Above 7K/hour${NC}"
elif [ $FILES_LAST_HOUR -gt 3000 ]; then
    echo -e "${YELLOW}High load${NC}"
else
    echo -e "${GREEN}Normal load${NC}"
fi
echo ""

# 2. Manifest Creation
echo -e "${YELLOW}2. Manifest Creation${NC}"
echo "----------------------------------------"

MANIFESTS_TODAY=$(aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/$(date +%Y-%m-%d)/ \
  --region $REGION 2>/dev/null | wc -l || echo "0")

echo "Manifests created today: $MANIFESTS_TODAY"
echo "Expected for 338K files: ~3,380"

if [ $MANIFESTS_TODAY -gt 5000 ]; then
    echo -e "${YELLOW}High manifest count (check batch size)${NC}"
fi
echo ""

# 3. Glue Job Status
echo -e "${YELLOW}3. Glue Job Status${NC}"
echo "----------------------------------------"

JOB_STATS=$(aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 100 \
  --output json | python3 -c "
import sys, json
from datetime import datetime, timedelta

data = json.load(sys.stdin)
now = datetime.utcnow()
one_hour_ago = now - timedelta(hours=1)

running = 0
succeeded = 0
failed = 0
total_time = 0

for job in data.get('JobRuns', []):
    started = datetime.fromisoformat(job['StartedOn'].replace('Z', '+00:00').replace('+00:00', ''))

    if started < one_hour_ago:
        continue

    state = job['JobRunState']
    if state == 'RUNNING':
        running += 1
    elif state == 'SUCCEEDED':
        succeeded += 1
        total_time += job.get('ExecutionTime', 0)
    elif state == 'FAILED':
        failed += 1

avg_time = total_time / succeeded if succeeded > 0 else 0

print(f'Running: {running}')
print(f'Succeeded (last hour): {succeeded}')
print(f'Failed (last hour): {failed}')
print(f'Avg execution time: {avg_time:.1f}s')
print(f'Files processed: ~{succeeded * 100}')
")

echo "$JOB_STATS"
echo ""

# Check for failed jobs
RECENT_FAILURES=$(aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 10 \
  --query 'JobRuns[?JobRunState==`FAILED`]' \
  --output json | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

if [ "$RECENT_FAILURES" -gt "0" ]; then
    echo -e "${RED}$RECENT_FAILURES failed jobs in last 10 runs${NC}"
    echo "Run './check-glue-errors.sh' for details"
fi
echo ""

# 4. DynamoDB Status
echo -e "${YELLOW}4. DynamoDB File Tracking${NC}"
echo "----------------------------------------"

DATE_PREFIX=$(date +%Y-%m-%d)
DB_STATS=$(aws dynamodb query \
  --table-name "${STACK_NAME}-file-tracking" \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values "{\":date\":{\"S\":\"$DATE_PREFIX\"}}" \
  --region $REGION \
  --output json | python3 -c "
import sys, json

data = json.load(sys.stdin)
pending = 0
manifested = 0
total_size = 0

for item in data.get('Items', []):
    status = item.get('status', {}).get('S', 'unknown')
    size_mb = float(item.get('file_size_mb', {}).get('N', 0))

    if status == 'pending':
        pending += 1
    elif status == 'manifested':
        manifested += 1

    total_size += size_mb

total_size_tb = total_size / (1024 * 1024)

print(f'Pending: {pending}')
print(f'Manifested: {manifested}')
print(f'Total: {pending + manifested}')
print(f'Data volume: {total_size_tb:.2f} TB')
")

echo "$DB_STATS"
echo ""

# 5. SQS Queue Depth
echo -e "${YELLOW}5. SQS Queue Status${NC}"
echo "----------------------------------------"

QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "${STACK_NAME}-file-events" \
  --region $REGION \
  --query 'QueueUrl' \
  --output text)

QUEUE_STATS=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region $REGION \
  --query 'Attributes' \
  --output json | python3 -c "
import sys, json
attrs = json.load(sys.stdin)
visible = int(attrs.get('ApproximateNumberOfMessages', 0))
inflight = int(attrs.get('ApproximateNumberOfMessagesNotVisible', 0))
print(f'Messages waiting: {visible}')
print(f'Messages in-flight: {inflight}')
print(f'Total: {visible + inflight}')
")

echo "$QUEUE_STATS"

MESSAGES_WAITING=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region $REGION \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)

if [ "$MESSAGES_WAITING" -gt "1000" ]; then
    echo -e "${RED}High queue backlog!${NC}"
fi
echo ""

# 6. Cost Estimate (Today)
echo -e "${YELLOW}6. Estimated Cost (Today)${NC}"
echo "----------------------------------------"

# Get Glue job runs today
JOBS_TODAY=$(aws glue get-job-runs \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --max-results 200 \
  --output json | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
today = datetime.utcnow().date()
total_time = 0

for job in data.get('JobRuns', []):
    started = datetime.fromisoformat(job['StartedOn'].replace('Z', '+00:00').replace('+00:00', ''))
    if started.date() == today and job['JobRunState'] == 'SUCCEEDED':
        total_time += job.get('ExecutionTime', 0)

# 20 workers × 2 DPU × \$0.44/hour
total_hours = total_time / 3600
cost = total_hours * 20 * 2 * 0.44

print(f'Total execution time: {total_hours:.1f} hours')
print(f'Estimated Glue cost: \${cost:.2f}')
print(f'Lambda cost: ~\$20')
print(f'DynamoDB cost: ~\$15')
print(f'S3 cost: ~\$400')
print(f'Total estimated: \${cost + 435:.2f}')
")

echo "$JOBS_TODAY"
echo ""

# 7. Health Summary
echo -e "${YELLOW}7. Health Summary${NC}"
echo "=========================================="

HEALTH="HEALTHY"

# Check for issues
if [ "$RECENT_FAILURES" -gt "2" ]; then
    HEALTH="DEGRADED"
    echo -e "${RED}Multiple Glue job failures${NC}"
fi

if [ "$MESSAGES_WAITING" -gt "1000" ]; then
    HEALTH="DEGRADED"
    echo -e "${RED}High SQS backlog${NC}"
fi

if [ "$FILES_LAST_HOUR" -gt "7000" ]; then
    echo -e "${YELLOW}Peak load - monitor closely${NC}"
fi

if [ "$HEALTH" = "HEALTHY" ]; then
    echo -e "${GREEN}All systems healthy${NC}"
fi

echo ""
echo "=========================================="
echo ""

echo "Monitoring commands:"
echo " Real-time: watch -n 30 './monitor-pipeline.sh'"
echo " Glue logs: ./check-glue-errors.sh"
echo " Lambda logs: ../../dev/scripts/check-lambda-logs.sh"
echo " Full diagnostic: ../../dev/scripts/diagnose-pipeline.sh"
echo ""
