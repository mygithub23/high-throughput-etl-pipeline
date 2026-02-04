#!/bin/bash

# Update Batch Configuration
# Easily modify batch processing settings

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

echo -e "${GREEN}=== Update Batch Configuration ===${NC}"
echo ""

# Get current configuration
echo -e "${YELLOW}Current Lambda Configuration:${NC}"
echo "----------------------------------------"

LAMBDA_CONFIG=$(aws lambda get-function-configuration \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query 'Environment.Variables' \
  --output json)

echo "$LAMBDA_CONFIG" | python3 << 'EOF'
import sys
import json

config = json.load(sys.stdin)

# Extract relevant settings
max_files = config.get('MAX_FILES_PER_MANIFEST', 'NOT SET')
max_size = config.get('MAX_BATCH_SIZE_GB', 'NOT SET')
file_size = config.get('EXPECTED_FILE_SIZE_MB', 'NOT SET')

print(f"  MAX_FILES_PER_MANIFEST: {max_files}")
print(f"  MAX_BATCH_SIZE_GB: {max_size}")
print(f"  EXPECTED_FILE_SIZE_MB: {file_size}")
EOF

echo ""
echo -e "${YELLOW}Current Glue Configuration:${NC}"
echo "----------------------------------------"

GLUE_CONFIG=$(aws glue get-job \
  --job-name "${STACK_NAME}-streaming-processor" \
  --region $REGION \
  --query 'Job' \
  --output json)

echo "$GLUE_CONFIG" | python3 << 'EOF'
import sys
import json

job = json.load(sys.stdin)

command = job.get('Command', {}).get('Name', 'UNKNOWN')
worker_type = job.get('WorkerType', 'UNKNOWN')
num_workers = job.get('NumberOfWorkers', 'UNKNOWN')
max_concurrent = job.get('ExecutionProperty', {}).get('MaxConcurrentRuns', 'UNKNOWN')
timeout = job.get('Timeout', 'UNKNOWN')

print(f"  Command (mode): {command}")
print(f"  WorkerType: {worker_type}")
print(f"  NumberOfWorkers: {num_workers}")
print(f"  MaxConcurrentRuns: {max_concurrent}")
print(f"  Timeout: {timeout} minutes")
EOF

echo ""
echo "=========================================="
echo ""

# Offer configuration options
echo "Configuration Presets:"
echo ""
echo "1. Light Load (50K files/day, 2-4GB files)"
echo "   Lambda: MAX_FILES_PER_MANIFEST=100, MAX_BATCH_SIZE_GB=400"
echo "   Glue: 20 concurrent jobs, 15 workers, G.2X"
echo ""
echo "2. Medium Load (150K files/day, 3.5-4GB files) - CURRENT TARGET"
echo "   Lambda: MAX_FILES_PER_MANIFEST=100, MAX_BATCH_SIZE_GB=500"
echo "   Glue: 30 concurrent jobs, 20 workers, G.2X"
echo ""
echo "3. Heavy Load (338K files/day, 3.5-4.5GB files)"
echo "   Lambda: MAX_FILES_PER_MANIFEST=100, MAX_BATCH_SIZE_GB=500"
echo "   Glue: 50 concurrent jobs, 20 workers, G.2X"
echo ""
echo "4. Custom Configuration"
echo ""
echo "5. Exit (no changes)"
echo ""

read -p "Select preset (1-5): " PRESET

case $PRESET in
    1)
        MAX_FILES=100
        MAX_SIZE=400
        CONCURRENT=20
        WORKERS=15
        ;;
    2)
        MAX_FILES=100
        MAX_SIZE=500
        CONCURRENT=30
        WORKERS=20
        ;;
    3)
        MAX_FILES=100
        MAX_SIZE=500
        CONCURRENT=50
        WORKERS=20
        ;;
    4)
        read -p "MAX_FILES_PER_MANIFEST: " MAX_FILES
        read -p "MAX_BATCH_SIZE_GB: " MAX_SIZE
        read -p "Glue MaxConcurrentRuns: " CONCURRENT
        read -p "Glue NumberOfWorkers: " WORKERS
        ;;
    5)
        echo "Cancelled"
        exit 0
        ;;
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac

echo ""
echo -e "${YELLOW}Will apply:${NC}"
echo "  Lambda MAX_FILES_PER_MANIFEST: $MAX_FILES"
echo "  Lambda MAX_BATCH_SIZE_GB: $MAX_SIZE"
echo "  Glue MaxConcurrentRuns: $CONCURRENT"
echo "  Glue NumberOfWorkers: $WORKERS"
echo ""

read -p "Apply these changes? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Update Lambda
echo ""
echo -e "${YELLOW}Updating Lambda configuration...${NC}"

# Get all current environment variables
ALL_ENV=$(aws lambda get-function-configuration \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query 'Environment.Variables' \
  --output json)

# Update specific values
UPDATED_ENV=$(echo "$ALL_ENV" | python3 -c "
import sys
import json

env = json.load(sys.stdin)
env['MAX_FILES_PER_MANIFEST'] = '$MAX_FILES'
env['MAX_BATCH_SIZE_GB'] = '$MAX_SIZE'

print(json.dumps({'Variables': env}))
")

aws lambda update-function-configuration \
  --function-name "${STACK_NAME}-manifest-builder" \
  --environment "$UPDATED_ENV" \
  --region $REGION \
  --output text \
  --query 'FunctionName' > /dev/null

echo -e "${GREEN}✓ Lambda updated${NC}"

# Update Glue
echo ""
echo -e "${YELLOW}Updating Glue configuration...${NC}"

aws glue update-job \
  --job-name "${STACK_NAME}-streaming-processor" \
  --job-update "{
    \"WorkerType\": \"G.2X\",
    \"NumberOfWorkers\": $WORKERS,
    \"ExecutionProperty\": {
      \"MaxConcurrentRuns\": $CONCURRENT
    }
  }" \
  --region $REGION > /dev/null

echo -e "${GREEN}✓ Glue updated${NC}"

echo ""
echo -e "${GREEN}✓ Configuration updated successfully${NC}"
echo ""

# Show new config
echo -e "${YELLOW}New Configuration:${NC}"
echo "  Processing capacity: $((CONCURRENT * MAX_FILES)) files in parallel"
echo "  Batch size: $MAX_FILES files per manifest (~$((MAX_FILES * 4))GB max)"
echo "  Worker capacity: $((CONCURRENT * WORKERS)) total workers"
echo ""
echo "Estimated performance for 338K files/day:"
MANIFESTS=$((338000 / MAX_FILES))
BATCHES=$((MANIFESTS / CONCURRENT))
HOURS=$((BATCHES * 5 / 60))
echo "  Manifests per day: ~$MANIFESTS"
echo "  Processing time: ~$HOURS hours"
echo ""
