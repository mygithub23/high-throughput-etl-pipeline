#!/bin/bash

# Generate Test Data for Development
# Creates small NDJSON files (KB size) for quick testing

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Generating DEV Test Data (KB-sized files)${NC}"
echo ""

# Configuration
NUM_FILES=${1:-10}
RECORDS_PER_FILE=${2:-100}
OUTPUT_DIR="./test-data-dev"
DATE_PREFIX=$(date +%Y-%m-%d)

echo "Configuration:"
echo " Files: $NUM_FILES"
echo " Records per file: $RECORDS_PER_FILE"
echo " File size: ~10-20 KB each"
echo " Output: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${YELLOW}Generating files...${NC}"

for i in $(seq 1 $NUM_FILES); do
    FILE="$OUTPUT_DIR/${DATE_PREFIX}-test-${i}.ndjson"

    # Generate NDJSON records
    for j in $(seq 1 $RECORDS_PER_FILE); do
        cat <<EOF >> "$FILE"
{"id":"${i}-${j}","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","user_id":"user_$((RANDOM % 1000))","event":"test_event","data":{"field1":"value1","field2":123,"field3":true},"metadata":{"source":"dev_test","version":"1.0"}}
EOF
    done

    FILE_SIZE=$(wc -c < "$FILE")
    FILE_SIZE_KB=$((FILE_SIZE / 1024))
    echo " Created: $FILE ($FILE_SIZE_KB KB, $RECORDS_PER_FILE records)"
done

echo ""
echo -e "${GREEN}Generated $NUM_FILES test files${NC}"
echo ""

# Summary
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
echo "Summary:"
echo " Total size: $TOTAL_SIZE"
echo " Location: $OUTPUT_DIR"
echo ""

echo "Next steps:"
echo " 1. Review files: ls -lh $OUTPUT_DIR"
echo " 2. Upload to S3: ./upload-test-data.sh"
echo ""
