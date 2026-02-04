# Pipeline Timezone Handling

## Critical Requirement: All Dates Must Be UTC

The entire pipeline uses **UTC timezone** for all date operations. This is critical for correct file processing and avoiding orphaned files.

## Why UTC?

1. **Consistency**: AWS Lambda, Step Functions, and Glue all run in UTC
2. **No DST issues**: UTC never changes for daylight saving time
3. **Global compatibility**: Works correctly regardless of where files are created
4. **Orphan detection**: Lambda compares file dates against UTC "today"

## How Lambda Handles Dates

### Date Extraction from Filename

Lambda extracts the date prefix from the NDJSON filename:

```python
# From lambda_manifest_builder.py:375-397
match = re.search(r'(\d{4}-\d{2}-\d{2})', key)
if match:
    date_prefix = match.group(1)  # e.g., "2026-01-30"
else:
    # Fallback: use UTC current date
    date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')
```

### Orphan Detection

Lambda determines if a file is from a previous day:

```python
# From lambda_manifest_builder.py:466-470
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')  # UTC!
is_previous_day = date_prefix < today

if is_previous_day:
    # Trigger immediate flush (don't wait for 10 files)
    logger.info(f"🔄 Triggering end-of-day flush for orphaned files")
```

## The Timezone Problem

### Bad Example: Using Local Time

```bash
# ❌ WRONG: Uses EST (UTC-5)
DATE=$(date +%Y-%m-%d)
FILENAME="${DATE}-test0001.ndjson"
```

**Scenario at 11:30 PM EST on Jan 29:**
- Local date: `2026-01-29`
- UTC date: `2026-01-30` (already next day!)
- Filename: `2026-01-29-test0001.ndjson`
- Lambda sees: "File from yesterday, trigger orphan flush!"
- Result: File processed immediately instead of waiting for batch of 10

### Correct Example: Using UTC

```bash
# ✅ CORRECT: Uses UTC with -u flag
DATE=$(date -u +%Y-%m-%d)
FILENAME="${DATE}-test0001.ndjson"
```

**Same scenario at 11:30 PM EST (04:30 UTC):**
- UTC date: `2026-01-30`
- Filename: `2026-01-30-test0001.ndjson`
- Lambda sees: "File from today, wait for 10 files"
- Result: Normal batching behavior

## Best Practices

### 1. File Creation Scripts

Always use `date -u` for UTC time:

```bash
#!/bin/bash

# Get current UTC date and time
DATE=$(date -u +%Y-%m-%d)
TIMESTAMP=$(date -u +%H%M%S)
UUID=$(uuidgen)

# Create filename with UTC date prefix
FILENAME="${DATE}-file-${TIMESTAMP}-${UUID}.ndjson"
```

### 2. Production Data Pipelines

If your data source uses local time:

```bash
# Convert local time to UTC
UTC_DATE=$(TZ=UTC date +%Y-%m-%d)

# Or use Python for complex conversions
UTC_DATE=$(python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))
")
```

### 3. Testing

Our `create-test-files.sh` script uses UTC:

```bash
cd environments/dev/scripts
bash create-test-files.sh  # Creates files with UTC dates
```

### 4. Manual File Creation

When creating NDJSON files manually:

```bash
# Get UTC date first
UTC_DATE=$(date -u +%Y-%m-%d)

# Use it in your filename
echo '{"data": "test"}' > ${UTC_DATE}-myfile.ndjson
```

## Components Using UTC

### Lambda Function
- `datetime.now(timezone.utc)` everywhere
- Orphan detection compares against UTC today
- Fallback date uses UTC

### Step Functions
- Input payload includes UTC timestamp
- Glue job arguments use UTC date from manifest

### Glue Job
- Partitions by `date_prefix` from manifest (UTC)
- Output structure: `merged-parquet-YYYY-MM-DD/` (UTC date)

### DynamoDB
- `created_at`, `updated_at` timestamps in UTC ISO format
- `date_prefix` field matches filename date (should be UTC)
- TTL calculated from UTC timestamp

## Verifying Timezone Consistency

### Check Your Environment

```bash
# Show current local time
date

# Show current UTC time
date -u

# Calculate offset
echo "If these differ by 5 hours, you're in EST (UTC-5)"
```

### Check Files in S3

```bash
# List files and check date prefixes
aws s3 ls s3://ndjson-input-sqs-<ACCOUNT>-dev/pipeline/input/ --region us-east-1

# Verify all files have today's UTC date
UTC_TODAY=$(date -u +%Y-%m-%d)
echo "Today (UTC): $UTC_TODAY"
echo "Files should start with: ${UTC_TODAY}-"
```

### Check Lambda Logs

```bash
# Check what Lambda considers "today"
MSYS_NO_PATHCONV=1 aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-dev \
  --since 10m \
  --region us-east-1| grep "today:"
```

## Troubleshooting Timezone Issues

### Symptom: Files processed immediately instead of batching

**Cause**: File has yesterday's date (local time), but Lambda thinks it's today (UTC)

**Fix**:
```bash
# Check what date your files have
ls -1 *.ndjson | head -1

# Check what Lambda considers today
date -u +%Y-%m-%d

# If mismatch, recreate files with UTC date
DATE=$(date -u +%Y-%m-%d)
```

### Symptom: Orphan flush triggering unexpectedly

**Cause**: Date mismatch due to timezone

**Fix**: Ensure all file creation uses `date -u`

### Symptom: Files split across different dates

**Cause**: Created around midnight in different timezones

**Solution**: Always use UTC. Files created at 11:59 PM UTC and 12:01 AM UTC will have different dates, but this is correct behavior.

## Summary

✅ **DO:**
- Use `date -u` for all date operations
- Create files with UTC date prefix
- Document that pipeline uses UTC
- Test file creation around midnight UTC

❌ **DON'T:**
- Use `date` without `-u` flag
- Mix timezones
- Assume local time = UTC
- Create files with local date prefixes

## Reference: Lambda Date Handling Code

See [lambda_manifest_builder.py](../lambda/lambda_manifest_builder.py):
- Line 375-397: `extract_date_and_filename()` - extracts date from filename
- Line 466-470: Orphan detection using UTC
- Line 543: `flush_orphaned_dates()` - UTC comparison
- Line 757: Manifest timestamp in UTC
- Line 853: All timestamps use `datetime.now(timezone.utc)`
