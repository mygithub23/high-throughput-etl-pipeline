#!/bin/bash

# Generate Test NDJSON Files
# Creates NDJSON files with configurable size and uploads to S3
#
# Usage:
#   ./generate-test-files.sh                      # Generate 10 files, ~1MB each
#   ./generate-test-files.sh 20                   # Generate 20 files
#   ./generate-test-files.sh 20 5                 # Generate 20 files, ~5MB each
#   ./generate-test-files.sh 20 5 2025-12-25      # With custom date prefix
#   ./generate-test-files.sh 20 5 2025-12-25 --upload  # Generate and upload

set -e

# Configuration
ENV="dev"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}-${ENV}"
INPUT_PREFIX="pipeline/input"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parameters
NUM_FILES=${1:-10}
TARGET_SIZE_MB=${2:-1}
DATE_PREFIX=${3:-$(date +%Y-%m-%d)}
UPLOAD_FLAG=${4:-""}

# Calculate records needed for target size
# Each record is approximately 200-300 bytes
BYTES_PER_RECORD=250
TARGET_BYTES=$((TARGET_SIZE_MB * 1024 * 1024))
RECORDS_PER_FILE=$((TARGET_BYTES / BYTES_PER_RECORD))

OUTPUT_DIR="./test-data-${DATE_PREFIX}"

echo -e "${GREEN}Generate Test NDJSON Files${NC}"
echo ""
echo "Configuration:"
echo "  Files to generate: $NUM_FILES"
echo "  Target size per file: ~${TARGET_SIZE_MB} MB"
echo "  Records per file: ~$RECORDS_PER_FILE"
echo "  Date prefix: $DATE_PREFIX"
echo "  Output directory: $OUTPUT_DIR"
echo "  Upload to S3: ${UPLOAD_FLAG:-no}"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}Generating files...${NC}"

for i in $(seq -f "%04g" 1 $NUM_FILES); do
    TIMESTAMP=$(date -u +%H%M%S)
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(date +%s)-$RANDOM")
    FILENAME="${DATE_PREFIX}-test${i}-${TIMESTAMP}-${UUID}.ndjson"
    FILEPATH="$OUTPUT_DIR/$FILENAME"

    # Generate NDJSON records
    > "$FILEPATH"  # Clear file

    for j in $(seq 1 $RECORDS_PER_FILE); do
        # Generate varied test data
        user_id=$((RANDOM % 10000))
        event_types=("page_view" "click" "purchase" "signup" "logout" "search" "add_to_cart")
        event_type=${event_types[$((RANDOM % ${#event_types[@]}))]}
        value=$((RANDOM % 10000))
        amount=$(echo "scale=2; $RANDOM / 100" | bc)

        cat <<EOF >> "$FILEPATH"
{"id":"${i}-${j}","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)","user_id":"user_${user_id}","session_id":"sess_${RANDOM}","event_type":"${event_type}","page":"/page/$((RANDOM % 100))","value":${value},"amount":${amount},"metadata":{"source":"test_generator","version":"2.0","batch":"${i}","env":"${ENV}"},"tags":["test","generated","batch_${i}"]}
EOF
    done

    # Get actual file size
    FILE_SIZE=$(stat -f%z "$FILEPATH" 2>/dev/null || stat -c%s "$FILEPATH" 2>/dev/null)
    FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE / 1048576" | bc)

    echo -e "  ${GREEN}✓${NC} $FILENAME (${FILE_SIZE_MB} MB, $RECORDS_PER_FILE records)"
done

echo ""

# Calculate total size
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
TOTAL_FILES=$(ls -1 "$OUTPUT_DIR"/*.ndjson 2>/dev/null | wc -l)

echo -e "${GREEN}Generation Complete${NC}"
echo "  Total files: $TOTAL_FILES"
echo "  Total size: $TOTAL_SIZE"
echo "  Location: $OUTPUT_DIR"
echo ""

# Upload if requested
if [ "$UPLOAD_FLAG" == "--upload" ]; then
    echo -e "${YELLOW}Uploading to S3...${NC}"
    echo "  Target: s3://${INPUT_BUCKET}/${INPUT_PREFIX}/"

    aws s3 cp "$OUTPUT_DIR/" "s3://${INPUT_BUCKET}/${INPUT_PREFIX}/" \
        --recursive \
        --region "$REGION" \
        --only-show-errors

    echo -e "${GREEN}✓ Upload complete${NC}"
    echo ""

    echo "Verify uploaded files:"
    aws s3 ls "s3://${INPUT_BUCKET}/${INPUT_PREFIX}/" --region "$REGION" | grep "$DATE_PREFIX" | head -5
    echo "..."
    echo ""

    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Wait 1-2 minutes for Lambda to process"
    echo "  2. Check DynamoDB: ./dynamodb-queries.sh status"
    echo "  3. Check Step Functions: ./stepfunctions-queries.sh running"
else
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Review files: ls -lh $OUTPUT_DIR"
    echo "  2. Upload to S3:"
    echo "     aws s3 cp $OUTPUT_DIR/ s3://${INPUT_BUCKET}/${INPUT_PREFIX}/ --recursive"
    echo "  Or re-run with --upload flag:"
    echo "     $0 $NUM_FILES $TARGET_SIZE_MB $DATE_PREFIX --upload"
fi
echo ""
