#!/bin/bash

# Generate Test Data for Production Testing
# Creates large NDJSON files (3.5-4GB) matching production specs

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Generating PRODUCTION Test Data (GB-sized files)${NC}"
echo ""
echo -e "${RED}WARNING: This will create large files (3.5-4GB each)${NC}"
echo -e "${RED}Make sure you have enough disk space!${NC}"
echo ""

# Configuration
NUM_FILES=${1:-5}
TARGET_SIZE_GB=${2:-3.5}
OUTPUT_DIR="./test-data-prod"
DATE_PREFIX=$(date +%Y-%m-%d)

# Calculate records needed for target size
# Each record is ~200 bytes, so for 3.5GB we need ~18.5M records
BYTES_PER_RECORD=200
TARGET_SIZE_BYTES=$((TARGET_SIZE_GB * 1024 * 1024 * 1024))
RECORDS_PER_FILE=$((TARGET_SIZE_BYTES / BYTES_PER_RECORD))

echo "Configuration:"
echo "  Files: $NUM_FILES"
echo "  Target size per file: ${TARGET_SIZE_GB} GB"
echo "  Records per file: ~$RECORDS_PER_FILE"
echo "  Total data: ~$((NUM_FILES * TARGET_SIZE_GB)) GB"
echo ""

read -p "Continue? This will take time and space! (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}Generating files (this will take a while)...${NC}"
echo ""

for i in $(seq 1 $NUM_FILES); do
    FILE="$OUTPUT_DIR/${DATE_PREFIX}-prod-${i}.ndjson"
    echo "  Generating file $i/$NUM_FILES..."
    echo "  Target: ${TARGET_SIZE_GB}GB (~$RECORDS_PER_FILE records)"

    START_TIME=$(date +%s)

    # Generate in batches to show progress
    BATCH_SIZE=100000
    BATCHES=$((RECORDS_PER_FILE / BATCH_SIZE))

    for batch in $(seq 1 $BATCHES); do
        for j in $(seq 1 $BATCH_SIZE); do
            RECORD_ID=$(((batch - 1) * BATCH_SIZE + j))
            cat <<EOF >> "$FILE"
{"id":"${i}-${RECORD_ID}","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","user_id":"user_$((RANDOM % 10000))","session_id":"session_$((RANDOM % 100000))","event":"production_event","ip_address":"192.168.$((RANDOM % 256)).$((RANDOM % 256))","user_agent":"Mozilla/5.0 (compatible; TestBot/1.0)","data":{"transaction_id":"txn_${RECORD_ID}","amount":$((RANDOM % 10000)),"currency":"USD","status":"completed","items":["item1","item2","item3"],"metadata":{"campaign":"summer_2024","channel":"web","device":"desktop"}},"geo":{"country":"US","region":"CA","city":"San Francisco","lat":37.7749,"lon":-122.4194},"system":{"app_version":"2.1.0","platform":"web","build":"12345"}}
EOF
        done

        # Progress update every 10 batches
        if [ $((batch % 10)) -eq 0 ]; then
            CURRENT_SIZE=$(wc -c < "$FILE")
            CURRENT_SIZE_GB=$(echo "scale=2; $CURRENT_SIZE / 1024 / 1024 / 1024" | bc)
            PROGRESS=$((batch * 100 / BATCHES))
            echo "    Progress: ${PROGRESS}% (${CURRENT_SIZE_GB}GB)"
        fi
    done

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    FILE_SIZE=$(wc -c < "$FILE")
    FILE_SIZE_GB=$(echo "scale=2; $FILE_SIZE / 1024 / 1024 / 1024" | bc)
    ACTUAL_RECORDS=$(wc -l < "$FILE")

    echo "  ✓ Created: $FILE"
    echo "    Size: ${FILE_SIZE_GB}GB"
    echo "    Records: $ACTUAL_RECORDS"
    echo "    Time: ${DURATION}s"
    echo ""
done

echo -e "${GREEN}✓ Generated $NUM_FILES production test files${NC}"
echo ""

# Summary
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
echo "Summary:"
echo "  Total size: $TOTAL_SIZE"
echo "  Location: $OUTPUT_DIR"
echo ""

echo "Next steps:"
echo "  1. Review files: ls -lh $OUTPUT_DIR"
echo "  2. Compress for upload: tar -czf test-data-prod.tar.gz $OUTPUT_DIR"
echo "  3. Upload to S3: ./upload-test-data.sh"
echo ""
echo -e "${YELLOW}NOTE: Large file upload will take time. Consider using AWS CLI multipart upload.${NC}"
