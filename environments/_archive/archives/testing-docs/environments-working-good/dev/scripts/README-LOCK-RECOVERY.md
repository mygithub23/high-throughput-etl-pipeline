# LOCK Recovery Guide

## Problem: Pipeline Stops Creating Manifests

### Symptoms
- Many files stuck in "pending" status (76+)
- Some files in "manifested" status waiting for Glue
- Pipeline appears to have stopped processing new files
- DynamoDB shows LOCK record that won't clear

### Root Cause

The Lambda function uses a distributed lock mechanism to prevent concurrent manifest creation:
- Before creating manifests, Lambda acquires a LOCK record in DynamoDB
- The LOCK has a TTL of 300 seconds (5 minutes)
- If Lambda crashes or takes too long, the LOCK can become "stuck"
- DynamoDB TTL deletion is not immediate (can take up to 48 hours)
- While a LOCK exists, no other Lambda can create manifests for that date

## Quick Diagnosis

### 1. Check for Stuck Locks
```bash
bash check-locks.sh
```

This will show:
- All active LOCK records
- Whether they are expired
- How long until they expire or how long they've been stuck

### 2. Check Pipeline Status
```bash
bash trace-pipeline.sh
```

This shows:
- DynamoDB status summary (pending, manifested, completed)
- Manifest files created
- Parquet files created
- Step Functions executions
- Correlation analysis

## Recovery Steps

### If LOCK is Expired (Stuck)

**Recommended**: Clear the expired lock immediately
```bash
bash check-locks.sh --clear-expired
```

This will:
- Delete all expired LOCK records
- Allow pipeline to resume processing
- Not affect active locks

### If LOCK is Active (Not Expired)

**Wait** for the lock to expire naturally (max 5 minutes from creation)
- Check TTL timestamp: `bash check-locks.sh`
- DynamoDB will auto-delete once TTL expires
- Or clear manually after it expires

### Force Manifest Creation After Clearing Lock

Once locks are cleared, trigger Lambda to process pending files:
```bash
bash force-manifest-creation.sh
```

This will:
- Find a sample pending file
- Invoke Lambda with a test S3 event
- Trigger the orphan flush mechanism
- Process all pending files from all dates
- Create manifests for any date with ≥10 pending files

## Understanding the Status Flow

### Individual File Records
```
pending → manifested → (stays manifested)
   ↓           ↓
 Lambda    Lambda creates manifest
creates   + marks files as "manifested"
record
```

Individual NDJSON files stay in "manifested" status forever. They are never updated to "completed".

### MANIFEST Meta-Records
```
Created by Lambda → Updated by Step Functions
    (pending)              (processing → completed/failed)
```

MANIFEST records track the batch processing:
- `file_key = 'MANIFEST'`
- Created when Lambda builds manifest file
- Updated by Step Functions as Glue processes the batch
- Final status: "completed" or "failed"

## Expected Record Counts

For 130 input files with threshold of 10 files/manifest:
- **130 individual records**: Most will be "manifested" (a few might be "pending")
- **13 MANIFEST records**: One per manifest created
- **13 Step Functions executions**: One per MANIFEST
- **13 Parquet outputs**: One per successful Glue job

If you see:
- Many "manifested" files ✓ Normal
- Few "completed" MANIFEST records ✗ Problem - Step Functions not updating
- Many "pending" files with no recent manifests ✗ Problem - LOCK stuck

## Prevention

The Lambda has been updated with:
1. **Retry loop**: Attempts manifest creation up to 3 times if lock is held
2. **Lock contention detection**: Checks if enough files are pending before retrying
3. **Orphan flush**: Processes files from previous dates automatically

These mechanisms should prevent most lock issues, but manual intervention may still be needed if:
- Lambda crashes while holding lock
- DynamoDB TTL is delayed
- High concurrency causes extended lock contention

## Monitoring Scripts

| Script | Purpose |
|--------|---------|
| `check-locks.sh` | Diagnose and clear stuck LOCK records |
| `trace-pipeline.sh` | Full pipeline health check and correlation |
| `force-manifest-creation.sh` | Manually trigger Lambda to process pending files |
| `debug-glue-output.sh` | Verify manifest files and Parquet outputs |
| `reprocess-failed.sh` | Retry failed Step Functions executions |

## Common Issues

### Issue: "No files processed" after force trigger
**Cause**: Files are from different dates, none reached the 10-file threshold
**Solution**: Check distribution by date:
```bash
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking-dev \
  --index-name status-index \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --projection-expression date_prefix \
  --region us-east-1 | jq -r '.Items[].date_prefix.S' | sort | uniq -c
```

### Issue: Manifests created but no Parquet files
**Cause**: Step Functions or Glue failing
**Solution**: Check executions:
```bash
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:us-east-1:$(aws sts get-caller-identity --query Account --output text):stateMachine:ndjson-parquet-processor-dev \
  --status-filter FAILED \
  --max-results 10
```

### Issue: Parquet files in wrong S3 location
**Cause**: OUTPUT_PREFIX not configured (fixed in latest version)
**Solution**: Verify Glue job arguments in Step Functions:
```bash
bash debug-glue-output.sh
```

## Support

If issues persist after following this guide:
1. Collect diagnostics: `bash trace-pipeline.sh > pipeline-state.txt`
2. Check Lambda logs: `aws logs tail /aws/lambda/ndjson-manifest-builder-dev --follow`
3. Check Glue logs in CloudWatch: `/aws-glue/jobs/output` and `/aws-glue/jobs/error`
4. Review Step Functions execution history in AWS Console
