#!/bin/bash

# Create properly formatted test files for the pipeline
# Files must:
# 1. Start with date prefix (YYYY-MM-DD) in UTC timezone
# 2. Be at least 100KB (0.1 MB) to pass size validation
# 3. Be NDJSON format (one JSON object per line)
#
# IMPORTANT: Always use UTC dates to match Lambda's timezone!
# Lambda uses UTC to determine "today" for orphan detection.

set -e

DATE=$(date -u +%Y-%m-%d) # CRITICAL: Use UTC (-u flag) to match Lambda's timezone
TIMESTAMP=$(date -u +%H%M%S)
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(( RANDOM % 10000 ))")

echo "Creating 10 test files for date: $DATE (UTC)"
echo "Current UTC time: $(date -u)"
echo ""

for i in {1..10}; do
    FILENAME="${DATE}-test$(printf '%04d' $i)-${TIMESTAMP}-${UUID}.ndjson"
    
    # Create a file with ~150KB of NDJSON data (well within 0.1-19.9 MB range)
    # Each line is ~150 bytes, so 1000 lines = ~150KB
    echo -n "Creating $FILENAME (150KB)... "
    
    > "$FILENAME" # Create empty file
    for j in {1..1000}; do
        echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"test_id\":$i,\"record_id\":$j,\"data\":\"This is test data with some padding to reach the right size per line for validation\"}" >> "$FILENAME"
    done
    
    FILE_SIZE=$(stat -f%z "$FILENAME" 2>/dev/null || stat -c%s "$FILENAME" 2>/dev/null || wc -c < "$FILENAME")
    FILE_SIZE_KB=$((FILE_SIZE / 1024))
    echo "Done (${FILE_SIZE_KB}KB)"
done

echo ""
echo "Created 10 test files with correct format and size"
echo ""
echo "Files created:"
ls -lh ${DATE}-test*.ndjson 2>/dev/null | awk '{print " " $9 " - " $5}'
echo ""
echo "To upload these files, run:"
echo " aws s3 cp . s3://ndjson-input-sqs-<ACCOUNT>-dev/pipeline/input/ --recursive --exclude '*' --include '${DATE}-test*.ndjson'"
