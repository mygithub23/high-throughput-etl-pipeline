#!/bin/bash

# Debug Glue Output Issue
# Check why Glue runs successfully but produces no Parquet files

set -e

ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

MANIFEST_BUCKET="ndjson-manifest-sqs-${AWS_ACCOUNT_ID}-${ENV}"
OUTPUT_BUCKET="ndjson-output-sqs-${AWS_ACCOUNT_ID}-${ENV}"
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Glue Output Debug ===${NC}"
echo ""

# 1. Check if manifest files exist
echo -e "${CYAN}1. Checking manifest files...${NC}"
aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive --human-readable | tail -10
echo ""

# 2. Download and inspect a recent manifest
echo -e "${CYAN}2. Inspecting a recent manifest file...${NC}"
LATEST_MANIFEST=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive | sort | tail -1 | awk '{print $4}')

if [ -z "$LATEST_MANIFEST" ]; then
    echo -e "${RED}No manifest files found!${NC}"
    exit 1
fi

echo "Latest manifest: s3://${MANIFEST_BUCKET}/${LATEST_MANIFEST}"
aws s3 cp "s3://${MANIFEST_BUCKET}/${LATEST_MANIFEST}" - | python3 -c "
import sys, json
manifest = json.load(sys.stdin)
print(json.dumps(manifest, indent=2))
print()
print(f'Number of files in manifest: {sum(len(loc.get(\"URIPrefixes\", [])) for loc in manifest.get(\"fileLocations\", []))}')
"
echo ""

# 3. Check if the NDJSON files in the manifest actually exist
echo -e "${CYAN}3. Checking if NDJSON files in manifest exist...${NC}"
aws s3 cp "s3://${MANIFEST_BUCKET}/${LATEST_MANIFEST}" - | python3 -c "
import sys, json, subprocess
manifest = json.load(sys.stdin)
file_paths = []
for location in manifest.get('fileLocations', []):
    file_paths.extend(location.get('URIPrefixes', []))

print(f'Checking {len(file_paths)} files...')
missing = 0
for i, path in enumerate(file_paths[:5]): # Check first 5
    result = subprocess.run(['aws', 's3', 'ls', path], capture_output=True, text=True)
    if result.returncode != 0:
        print(f' MISSING: {path}')
        missing += 1
    else:
        print(f' EXISTS: {path}')

if len(file_paths) > 5:
    print(f' ... and {len(file_paths) - 5} more (not shown)')
"
echo ""

# 4. Check output bucket
echo -e "${CYAN}4. Checking output bucket for Parquet files...${NC}"
PARQUET_COUNT=$(aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive | grep -c '\.parquet$' || echo "0")
echo "Parquet files found: ${PARQUET_COUNT}"

if [ "$PARQUET_COUNT" -eq "0" ]; then
    echo -e "${YELLOW}No Parquet files found in output bucket${NC}"
    aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive --human-readable | head -20
else
    echo -e "${GREEN}Found Parquet files:${NC}"
    aws s3 ls "s3://${OUTPUT_BUCKET}/" --recursive --human-readable | grep '\.parquet$' | tail -10
fi
echo ""

# 5. Check Glue job logs
echo -e "${CYAN}5. Checking recent Glue job logs...${NC}"
GLUE_JOB_NAME="ndjson-parquet-batch-processor-${ENV}"

LATEST_RUN=$(aws glue get-job-runs \
    --job-name "$GLUE_JOB_NAME" \
    --max-results 1 \
    --region "$REGION" \
    --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('JobRuns', [])
if runs:
    run = runs[0]
    print(f\"Run ID: {run.get('Id')}\\nStatus: {run.get('JobRunState')}\\nStarted: {run.get('StartedOn')}\")
    print(f\"Arguments: {json.dumps(run.get('Arguments', {}), indent=2)}\")
    print(f\"Log Group: /aws-glue/jobs/{run.get('JobName')}\")
else:
    print('No runs found')
")

echo ""
echo "$LATEST_RUN"
echo ""

# 6. Get CloudWatch logs for the latest run
echo -e "${CYAN}6. Fetching Glue CloudWatch logs (last 50 lines)...${NC}"
LOG_GROUP="/aws-glue/jobs/output"
LOG_STREAM=$(echo "$LATEST_RUN" | grep "Run ID:" | awk '{print $3}')

if [ ! -z "$LOG_STREAM" ]; then
    aws logs tail "$LOG_GROUP" \
        --follow false \
        --format short \
        --filter-pattern "$LOG_STREAM" \
        --region "$REGION" 2>/dev/null | tail -50 || echo "Could not fetch logs"
else
    echo "No log stream found. Check CloudWatch Logs manually at:"
    echo "https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws-glue\$252Fjobs\$252Foutput"
fi

echo ""
echo -e "${CYAN}=== Diagnosis Complete ===${NC}"
