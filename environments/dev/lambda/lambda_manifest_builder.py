"""
Lambda #1: Manifest Builder - DEVELOPMENT VERSION
==================================================

Enhanced version with extensive logging, try-catch blocks, and debugging features.

Author: Data Engineering Team
Version: 1.3.0-dev
Environment: DEVELOPMENT

Features:
- Detailed logging for every operation
- Try-catch blocks with full stack traces
- Object introspection and dumps
- Debug mode for verbose output
- End-of-day flush: Processes orphaned files from previous days automatically
"""

import json
import os
import boto3
import hashlib
import time
import re
import traceback
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from typing import List, Dict, Tuple, Optional
import logging

# Configure detailed logging for development
logger = logging.getLogger()
logger.setLevel(logging.DEBUG)  # DEBUG level for dev

# AWS Clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
glue_client = boto3.client('glue')
sfn_client = boto3.client('stepfunctions')

# Environment Variables with validation
try:
    MANIFEST_BUCKET = os.environ['MANIFEST_BUCKET']
    TRACKING_TABLE = os.environ['TRACKING_TABLE']
    logger.info(f"✓ Environment loaded - Manifest bucket: {MANIFEST_BUCKET}, Tracking table: {TRACKING_TABLE}")
except KeyError as e:
    logger.error(f"✗ Missing required environment variable: {e}")
    raise

GLUE_JOB_NAME = os.environ.get('GLUE_JOB_NAME', '')
MAX_FILES_PER_MANIFEST = int(os.environ.get('MAX_FILES_PER_MANIFEST', '10'))
QUARANTINE_BUCKET = os.environ.get('QUARANTINE_BUCKET', '')
EXPECTED_FILE_SIZE_MB = float(os.environ.get('EXPECTED_FILE_SIZE_MB', '3.5'))
SIZE_TOLERANCE_PERCENT = float(os.environ.get('SIZE_TOLERANCE_PERCENT', '10'))
LOCK_TABLE = os.environ.get('LOCK_TABLE', TRACKING_TABLE)
LOCK_TTL_SECONDS = int(os.environ.get('LOCK_TTL_SECONDS', '300'))
STEP_FUNCTION_ARN = os.environ.get('STEP_FUNCTION_ARN', '')

# End-of-day flush configuration
# MIN_FILES_FOR_PARTIAL_BATCH: Minimum files needed to create a partial batch for previous days
# Set to 1 to process any orphaned files, or higher to require a minimum batch size
MIN_FILES_FOR_PARTIAL_BATCH = int(os.environ.get('MIN_FILES_FOR_PARTIAL_BATCH', '1'))

# TTL configuration for DynamoDB records
# Records will be automatically deleted after this many days
TTL_DAYS = int(os.environ.get('TTL_DAYS', '30'))

# Log all configuration
logger.info(f"Configuration: MAX_FILES_PER_MANIFEST={MAX_FILES_PER_MANIFEST}, EXPECTED_FILE_SIZE_MB={EXPECTED_FILE_SIZE_MB}")
logger.info(f"Configuration: SIZE_TOLERANCE_PERCENT={SIZE_TOLERANCE_PERCENT}, LOCK_TTL_SECONDS={LOCK_TTL_SECONDS}")
logger.info(f"Configuration: MIN_FILES_FOR_PARTIAL_BATCH={MIN_FILES_FOR_PARTIAL_BATCH}, TTL_DAYS={TTL_DAYS}")

# DynamoDB table
table = dynamodb.Table(TRACKING_TABLE)

# Module-level list to track manifests created during Lambda execution
# Reset in lambda_handler, populated in _create_manifest
_manifests_created_this_execution = []


class DistributedLock:
    """Distributed lock with enhanced logging for development."""

    def __init__(self, lock_table: str, lock_key: str, ttl_seconds: int = 300):
        self.table = dynamodb.Table(lock_table)
        self.lock_key = lock_key
        self.ttl_seconds = ttl_seconds
        self.lock_id = f"{os.environ.get('AWS_LAMBDA_LOG_STREAM_NAME', 'local')}_{int(time.time() * 1000)}"
        self.acquired = False
        logger.debug(f"🔒 Lock object created - Key: {lock_key}, ID: {self.lock_id}, TTL: {ttl_seconds}s")

    def acquire(self) -> bool:
        logger.info("---------- acquire -------------")
        """Attempt to acquire the lock with detailed logging."""
        try:
            ttl = int(time.time()) + self.ttl_seconds
            logger.debug(f"🔒 Attempting to acquire lock: {self.lock_key}")

            self.table.put_item(
                Item={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_key': 'LOCK',  # Range key in DynamoDB
                    'lock_id': self.lock_id,
                    'ttl': ttl,
                    'created_at': datetime.now(timezone.utc).isoformat()
                },
                ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now',
                ExpressionAttributeNames={'#ttl': 'ttl'},
                ExpressionAttributeValues={':now': int(time.time())}
            )
            self.acquired = True
            logger.info(f"✓ Lock acquired successfully: {self.lock_key}")
            return True
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException as e:
            logger.warning(f"✗ Lock already held by another process: {self.lock_key}")
            logger.debug(f"Lock conflict details: {str(e)}")
            return False
        except Exception as e:
            logger.error(f"✗ Unexpected error acquiring lock: {str(e)}")
            logger.error(f"Traceback: {traceback.format_exc()}")
            return False

    def release(self):
        """Release the lock with logging."""
        logger.info("---------- release -------------")
        if not self.acquired:
            logger.debug(f"🔒 No lock to release for: {self.lock_key}")
            return

        try:
            logger.debug(f"🔒 Releasing lock: {self.lock_key}")
            self.table.delete_item(
                Key={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_key': 'LOCK'  # Range key in DynamoDB
                },
                ConditionExpression='lock_id = :lock_id',
                ExpressionAttributeValues={':lock_id': self.lock_id}
            )
            self.acquired = False
            logger.info(f"✓ Lock released: {self.lock_key}")
        except Exception as e:
            logger.error(f"✗ Error releasing lock: {str(e)}")
            logger.error(f"Traceback: {traceback.format_exc()}")


def upload_lambda_metadata_report(
    context,
    files_processed: int,
    files_quarantined: int,
    manifests_created: List[str],
    errors: List[str],
    execution_start_time: float
) -> None:
    """
    Generate and upload Lambda execution metadata report to S3.

    Args:
        context: AWS Lambda context object
        files_processed: Number of files successfully processed
        files_quarantined: Number of files quarantined
        manifests_created: List of manifest S3 URIs created
        errors: List of error messages
        execution_start_time: Timestamp when Lambda started (from time.time())
    """
    try:
        import uuid

        # Verify bucket is configured
        if not MANIFEST_BUCKET:
            logger.error("⚠️  MANIFEST_BUCKET not configured, skipping metadata upload")
            return

        execution_time = time.time() - execution_start_time
        timestamp = datetime.now(timezone.utc)

        # Generate unique filename: YYYY-mm-dd-Ttime-uuid-sequence.json
        date_str = timestamp.strftime('%Y-%m-%d')
        time_str = timestamp.strftime('%H%M%S')
        unique_id = str(uuid.uuid4())[:8]  # Short UUID
        sequence = '0001'  # Could be enhanced to track multiple reports per execution

        filename = f"{date_str}-T{time_str}-{unique_id}-{sequence}.json"
        s3_key = f"logs/lambda/{filename}"

        logger.info(f"📝 Preparing metadata upload to s3://{MANIFEST_BUCKET}/{s3_key}")

        # Build metadata report
        metadata = {
            'execution_info': {
                'request_id': context.aws_request_id,
                'function_name': context.function_name,
                'function_version': context.function_version,
                'memory_limit_mb': context.memory_limit_in_mb,
                'log_group': context.log_group_name,
                'log_stream': context.log_stream_name
            },
            'execution_metrics': {
                'start_time': datetime.fromtimestamp(execution_start_time, tz=timezone.utc).isoformat(),
                'end_time': timestamp.isoformat(),
                'duration_seconds': round(execution_time, 3),
                'remaining_time_ms': context.get_remaining_time_in_millis()
            },
            'processing_summary': {
                'files_processed': files_processed,
                'files_quarantined': files_quarantined,
                'manifests_created': len(manifests_created),
                'errors_count': len(errors),
                'status': 'success' if not errors else 'partial_success' if files_processed > 0 else 'failed'
            },
            'manifests': manifests_created,
            'errors': errors if errors else [],
            'configuration': {
                'max_files_per_manifest': MAX_FILES_PER_MANIFEST,
                'expected_file_size_mb': EXPECTED_FILE_SIZE_MB,
                'size_tolerance_percent': SIZE_TOLERANCE_PERCENT,
                'min_files_for_partial_batch': MIN_FILES_FOR_PARTIAL_BATCH
            },
            'report_metadata': {
                'generated_at': timestamp.isoformat(),
                'report_version': '1.0.0',
                'environment': 'dev'
            }
        }

        # Upload to S3
        report_json = json.dumps(metadata, indent=2, default=str)
        logger.debug(f"Metadata report size: {len(report_json)} bytes")

        logger.info(f"🔄 Uploading to S3: Bucket={MANIFEST_BUCKET}, Key={s3_key}")

        response = s3_client.put_object(
            Bucket=MANIFEST_BUCKET,
            Key=s3_key,
            Body=report_json.encode('utf-8'),
            ContentType='application/json',
            Metadata={
                'lambda_request_id': context.aws_request_id,
                'execution_status': metadata['processing_summary']['status'],
                'files_processed': str(files_processed),
                'manifests_created': str(len(manifests_created))
            }
        )

        logger.info(f"✅ S3 PutObject response: {response['ResponseMetadata']['HTTPStatusCode']}")
        logger.info(f"📊 Metadata report uploaded: s3://{MANIFEST_BUCKET}/{s3_key}")
        logger.debug(f"Report summary: {files_processed} files, {len(manifests_created)} manifests, {len(errors)} errors")

    except Exception as e:
        # Don't fail the Lambda if metadata upload fails
        logger.error(f"⚠️  Failed to upload metadata report: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")


def lambda_handler(event, context):
    logger.info("---------- lambda_handler -------------")
    """
    Main Lambda handler with comprehensive error handling and logging.
    """
    global _manifests_created_this_execution
    _manifests_created_this_execution = []  # Reset for this execution

    execution_start_time = time.time()  # Track execution time for metadata

    logger.info("=" * 80)
    logger.info("🚀 Lambda invocation started")
    logger.info(f"Request ID: {context.aws_request_id}")
    logger.info(f"Function: {context.function_name}")
    logger.info(f"Memory: {context.memory_limit_in_mb}MB")
    logger.info(f"Time remaining: {context.get_remaining_time_in_millis()}ms")
    logger.info("=" * 80)

    try:
        # Log full event for debugging
        logger.debug(f"📥 Event received: {json.dumps(event, indent=2, default=str)}")

        # Extract SQS records
        records = event.get('Records', [])
        logger.info(f"📨 Processing {len(records)} SQS records")

        if not records:
            logger.warning("⚠️  No records in event")
            # Upload metadata even for empty invocations
            upload_lambda_metadata_report(context, 0, 0, [], [], execution_start_time)
            return {'statusCode': 200, 'body': json.dumps('No records to process')}

        files_processed = 0
        files_quarantined = 0
        manifests_created = []  # Track manifest S3 URIs
        errors = []

        for idx, record in enumerate(records, 1):
            try:
                logger.info(f"📄 Processing record {idx}/{len(records)}")
                logger.debug(f"Record details: {json.dumps(record, indent=2, default=str)}")

                # Parse S3 event from SQS message
                s3_event = json.loads(record['body'])
                logger.debug(f"S3 event: {json.dumps(s3_event, indent=2)}")

                s3_records = s3_event.get('Records', [])
                logger.info(f"   Contains {len(s3_records)} S3 event(s)")

                for s3_record in s3_records:
                    try:
                        bucket = s3_record['s3']['bucket']['name']
                        key = s3_record['s3']['object']['key']
                        size = s3_record['s3']['object']['size']

                        logger.info(f"   📁 File: s3://{bucket}/{key}")
                        logger.info(f"      Size: {size} bytes ({size / (1024**2):.2f} MB)")

                        # Validate and process file
                        result = process_file(bucket, key, size)

                        if result == 'processed':
                            files_processed += 1
                            logger.info(f"   ✓ File processed successfully")
                        elif result == 'quarantined':
                            files_quarantined += 1
                            logger.warning(f"   ⚠️  File quarantined")

                    except Exception as e:
                        error_msg = f"Error processing S3 record: {str(e)}"
                        logger.error(f"   ✗ {error_msg}")
                        logger.error(f"   Traceback: {traceback.format_exc()}")
                        errors.append(error_msg)

            except Exception as e:
                error_msg = f"Error processing SQS record {idx}: {str(e)}"
                logger.error(f"✗ {error_msg}")
                logger.error(f"Traceback: {traceback.format_exc()}")
                errors.append(error_msg)

        # Summary
        logger.info("=" * 80)
        logger.info(f"📊 Processing Summary:")
        logger.info(f"   ✓ Files processed: {files_processed}")
        logger.info(f"   ⚠️  Files quarantined: {files_quarantined}")
        logger.info(f"   📋 Manifests created: {len(_manifests_created_this_execution)}")
        logger.info(f"   ✗ Errors: {len(errors)}")
        if errors:
            logger.error(f"   Error details: {json.dumps(errors, indent=2)}")
        logger.info("=" * 80)

        # Upload metadata report before returning
        upload_lambda_metadata_report(
            context,
            files_processed,
            files_quarantined,
            _manifests_created_this_execution,
            errors,
            execution_start_time
        )

        return {
            'statusCode': 200 if not errors else 207,
            'body': json.dumps({
                'processed': files_processed,
                'quarantined': files_quarantined,
                'manifests': len(_manifests_created_this_execution),
                'errors': len(errors),
                'errorDetails': errors if errors else None
            }, default=str)
        }

    except Exception as e:
        logger.error("=" * 80)
        logger.error(f"💥 FATAL ERROR in lambda_handler")
        logger.error(f"Error: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        logger.error("=" * 80)

        # Try to upload metadata even on fatal error
        try:
            upload_lambda_metadata_report(
                context,
                0,  # files_processed unknown
                0,  # files_quarantined unknown
                _manifests_created_this_execution,
                [f"FATAL ERROR: {str(e)}"],
                execution_start_time
            )
        except Exception as meta_error:
            logger.error(f"Failed to upload metadata on error: {meta_error}")

        raise


def process_file(bucket: str, key: str, size: int) -> str:
    logger.info("---------- process_file -------------")
    """Process a single file with detailed logging."""
    try:
        logger.debug(f"🔍 Validating file: {key}")

        # Validate file
        is_valid, reason = validate_file(key, size)

        if not is_valid:
            logger.warning(f"⚠️  Validation failed: {reason}")
            quarantine_file(bucket, key, reason)
            return 'quarantined'

        logger.debug(f"✓ File validation passed")

        # Track in DynamoDB
        date_prefix, file_name = extract_date_and_filename(key)
        logger.debug(f"📅 Date prefix: {date_prefix}, File name: {file_name}")

        track_file(bucket, key, date_prefix, file_name, size)
        logger.debug(f"✓ File tracked in DynamoDB")

        # Keep creating manifests until all pending files are processed
        # This handles the case where multiple Lambdas run in parallel
        total_manifests = 0
        max_iterations = 50  # Safety limit to prevent infinite loops
        consecutive_failures = 0
        max_consecutive_failures = 3  # Retry up to 3 times if lock is held

        for iteration in range(1, max_iterations + 1):
            logger.debug(f"🔍 Manifest creation iteration {iteration} for {date_prefix}")

            manifests_created = create_manifests_if_ready(date_prefix)

            if manifests_created > 0:
                total_manifests += manifests_created
                consecutive_failures = 0  # Reset failure counter on success
                logger.info(f"✓ Iteration {iteration}: Created {manifests_created} manifest(s) for {date_prefix}")
                # Small delay to allow other Lambdas to finish their DynamoDB writes
                time.sleep(0.1)
            else:
                # Check if there are still enough pending files (lock contention case)
                pending_count = _count_pending_files(date_prefix)
                logger.debug(f"ℹ️  Iteration {iteration}: No manifests created, {pending_count} files still pending")

                if pending_count >= MAX_FILES_PER_MANIFEST:
                    # Files are pending but we couldn't create manifest (likely lock contention)
                    consecutive_failures += 1
                    if consecutive_failures < max_consecutive_failures:
                        logger.info(f"⏳ Lock contention detected, waiting and retrying ({consecutive_failures}/{max_consecutive_failures})")
                        time.sleep(0.5)  # Wait 500ms before retrying
                        continue
                    else:
                        logger.info(f"ℹ️  Max retries reached, another Lambda will handle remaining files")
                        break
                else:
                    # Not enough files to create a manifest
                    logger.debug(f"ℹ️  Not enough pending files ({pending_count} < {MAX_FILES_PER_MANIFEST})")
                    break

        if total_manifests > 0:
            logger.info(f"✓ Total: Created {total_manifests} manifest(s) for {date_prefix}")

        # Also check for orphaned files from previous days and flush them
        orphan_manifests = flush_orphaned_dates()
        if orphan_manifests > 0:
            logger.info(f"✓ Flushed {orphan_manifests} manifest(s) from orphaned dates")

        return 'processed'

    except Exception as e:
        logger.error(f"✗ Error in process_file: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        raise


def validate_file(key: str, size: int) -> Tuple[bool, str]:
    logger.info("---------- validate_file -------------")
    """Validate file with logging."""
    try:
        logger.debug(f"Validating: key={key}, size={size}")

        # Check file extension
        if not key.endswith('.ndjson'):
            return False, f"Invalid extension (expected .ndjson)"

        # Check file size
        size_mb = size / (1024 * 1024)
        min_size = EXPECTED_FILE_SIZE_MB * (1 - SIZE_TOLERANCE_PERCENT / 100)
        max_size = EXPECTED_FILE_SIZE_MB * (1 + SIZE_TOLERANCE_PERCENT / 100)

        logger.debug(f"Size check: {size_mb:.2f}MB (expected: {min_size:.2f}-{max_size:.2f}MB)")

        if size_mb < min_size or size_mb > max_size:
            return False, f"Size {size_mb:.2f}MB outside expected range {min_size:.2f}-{max_size:.2f}MB"

        return True, "OK"

    except Exception as e:
        logger.error(f"Error in validate_file: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return False, f"Validation error: {str(e)}"


def quarantine_file(bucket: str, key: str, reason: str):
    logger.info("---------- quarantine_file -------------")
    """Quarantine invalid file with logging."""
    try:
        if not QUARANTINE_BUCKET:
            logger.warning(f"⚠️  QUARANTINE_BUCKET not set, skipping quarantine")
            return

        logger.info(f"🗑️  Quarantining file to s3://{QUARANTINE_BUCKET}/{key}")
        logger.info(f"   Reason: {reason}")

        s3_client.copy_object(
            Bucket=QUARANTINE_BUCKET,
            Key=key,
            CopySource={'Bucket': bucket, 'Key': key},
            Metadata={'quarantine_reason': reason, 'original_bucket': bucket}
        )

        logger.info(f"✓ File quarantined successfully")

    except Exception as e:
        logger.error(f"✗ Error quarantining file: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        raise


def extract_date_and_filename(key: str) -> Tuple[str, str]:
    """Extract date and filename from S3 key."""
    logger.info("---------- extract_date_and_filename -------------")
    try:
        parts = key.split('/')
        filename = parts[-1]

        # Try to find YYYY-MM-DD pattern in key
        match = re.search(r'(\d{4}-\d{2}-\d{2})', key)
        if match:
            date_prefix = match.group(1)
        else:
            # Fallback to current date
            date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')
            logger.warning(f"⚠️ No date found in key, using current date: {date_prefix}")

        logger.debug(f"Extracted: date={date_prefix}, filename={filename}")
        return date_prefix, filename

    except Exception as e:
        logger.error(f"Error extracting date/filename: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        raise


def track_file(bucket: str, key: str, date_prefix: str, file_name: str, size: int):
    """Track file in DynamoDB with logging and TTL."""
    logger.info("---------- track_file -------------")
    try:
        # Calculate TTL (Unix timestamp when record should expire)
        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

        # Note: DynamoDB table uses 'file_key' as the range key (not 'file_name')
        item = {
            'date_prefix': date_prefix,
            'file_key': file_name,  # Range key in DynamoDB
            'file_path': f's3://{bucket}/{key}',
            'file_size_mb': Decimal(str(size / (1024 * 1024))),
            'status': 'pending',
            'created_at': datetime.now(timezone.utc).isoformat(),
            'ttl': ttl_timestamp  # TTL attribute for automatic expiration
        }

        logger.debug(f"📝 Writing to DynamoDB: {json.dumps(item, indent=2, default=str)}")

        table.put_item(Item=item)

        logger.debug(f"✓ Item written to DynamoDB (TTL: {TTL_DAYS} days)")

    except Exception as e:
        logger.error(f"✗ Error tracking file: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        raise


def create_manifests_if_ready(date_prefix: str) -> int:
    """
    Check if ready to create manifests based on file count threshold.

    For current day: Requires MAX_FILES_PER_MANIFEST files to create a batch.
    For previous days: Creates partial batch with any remaining files (orphan flush).

    This prevents files from being stranded when the day changes before
    reaching the full batch threshold.
    """
    logger.info("---------- create_manifests_if_ready -------------")
    lock = DistributedLock(LOCK_TABLE, f'manifest-{date_prefix}', LOCK_TTL_SECONDS)

    try:
        # Try to acquire lock
        if not lock.acquire():
            logger.info(f"ℹ️  Another process is handling manifests for {date_prefix}")
            return 0

        logger.debug(f"🔍 Getting pending files for {date_prefix}")

        # Get pending files
        all_files = _get_pending_files(date_prefix)
        logger.info(f"📦 Found {len(all_files)} pending files (threshold: {MAX_FILES_PER_MANIFEST})")

        if not all_files:
            logger.debug(f"No pending files for {date_prefix}")
            return 0

        # Log file details in dev
        for i, file_info in enumerate(all_files[:5], 1):  # Log first 5
            logger.debug(f"   File {i}: {file_info['filename']} ({file_info['size_mb']:.2f}MB)")
        if len(all_files) > 5:
            logger.debug(f"   ... and {len(all_files) - 5} more files")

        # Determine if this is a previous day (orphan flush scenario)
        today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        is_previous_day = date_prefix < today

        if is_previous_day:
            logger.info(f"📅 Date {date_prefix} is from a previous day (today: {today})")
            logger.info(f"🔄 Triggering end-of-day flush for orphaned files")

        # Determine the threshold for creating a manifest
        # For previous days: use MIN_FILES_FOR_PARTIAL_BATCH (flush orphans)
        # For current day: use MAX_FILES_PER_MANIFEST (normal batching)
        effective_threshold = MIN_FILES_FOR_PARTIAL_BATCH if is_previous_day else MAX_FILES_PER_MANIFEST

        # Check if we have enough files to create a manifest
        if len(all_files) < effective_threshold:
            logger.info(f"ℹ️  Not enough files yet: {len(all_files)} < {effective_threshold}")
            return 0

        if is_previous_day:
            logger.info(f"✓ Processing {len(all_files)} orphaned files from {date_prefix}")
        else:
            logger.info(f"✓ File threshold reached! Creating manifests...")

        # Create batches
        # For previous days: include partial batches (flush all remaining)
        # For current day: only full batches
        batches = _create_batches(all_files, allow_partial=is_previous_day)
        logger.info(f"📦 Created {len(batches)} batch(es)")

        for i, batch in enumerate(batches, 1):
            batch_size_mb = sum(f['size_bytes'] for f in batch) / (1024**2)
            logger.debug(f"   Batch {i}: {len(batch)} files, {batch_size_mb:.2f}MB")

        # Create manifests
        manifests_created = 0
        for batch_idx, batch_files in enumerate(batches, 1):
            try:
                logger.debug(f"📝 Creating manifest {batch_idx}/{len(batches)}")
                manifest_path = _create_manifest(date_prefix, batch_idx, batch_files)

                if manifest_path:
                    manifests_created += 1
                    logger.info(f"✓ Manifest created: {manifest_path}")

                    # Update file status
                    _update_file_status(batch_files, 'manifested', manifest_path)
                    logger.debug(f"✓ Updated {len(batch_files)} file statuses")

                    # Trigger Step Functions workflow
                    start_step_function(manifest_path, date_prefix, len(batch_files))

            except Exception as e:
                logger.error(f"✗ Error creating manifest {batch_idx}: {str(e)}")
                logger.error(f"Traceback: {traceback.format_exc()}")

        return manifests_created

    except Exception as e:
        logger.error(f"✗ Error in create_manifests_if_ready: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return 0

    finally:
        lock.release()


def flush_orphaned_dates() -> int:
    """
    Find and flush all orphaned files from previous days.

    This function queries for ALL distinct date_prefixes with pending files,
    then triggers manifest creation for any dates before today.

    Returns:
        Total number of manifests created across all orphaned dates.
    """
    logger.info("---------- flush_orphaned_dates -------------")

    try:
        today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        logger.debug(f"🔍 Checking for orphaned dates (today: {today})")

        # Query the status-index GSI to find all pending files
        # Then extract unique date_prefixes that are before today
        orphaned_dates = _get_orphaned_date_prefixes(today)

        if not orphaned_dates:
            logger.debug("No orphaned dates found")
            return 0

        logger.info(f"📅 Found {len(orphaned_dates)} orphaned date(s): {orphaned_dates}")

        total_manifests = 0
        for date_prefix in orphaned_dates:
            logger.info(f"🔄 Flushing orphaned files for {date_prefix}")
            manifests = create_manifests_if_ready(date_prefix)
            total_manifests += manifests
            if manifests > 0:
                logger.info(f"✓ Created {manifests} manifest(s) for orphaned date {date_prefix}")

        return total_manifests

    except Exception as e:
        logger.error(f"✗ Error in flush_orphaned_dates: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return 0


def _get_orphaned_date_prefixes(today: str) -> List[str]:
    logger.info("---------- _get_orphaned_date_prefixes -------------")
    """
    Get all unique date_prefixes with pending files that are before today.

    Uses the status-index GSI to efficiently query by status.
    """
    try:
        orphaned_dates = set()
        last_evaluated_key = None

        while True:
            # Query the GSI for pending files
            query_params = {
                'IndexName': 'status-index',
                'KeyConditionExpression': '#status = :status',
                'ExpressionAttributeNames': {'#status': 'status'},
                'ExpressionAttributeValues': {':status': 'pending'},
                'ProjectionExpression': 'date_prefix'  # Only get date_prefix to minimize data transfer
            }

            if last_evaluated_key:
                query_params['ExclusiveStartKey'] = last_evaluated_key

            response = table.query(**query_params)

            # Extract unique date_prefixes that are before today
            for item in response.get('Items', []):
                date_prefix = item.get('date_prefix')
                if date_prefix and date_prefix < today:
                    orphaned_dates.add(date_prefix)

            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break

        # Return sorted list of orphaned dates
        return sorted(list(orphaned_dates))

    except Exception as e:
        logger.error(f"✗ Error getting orphaned date prefixes: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return []


def _count_pending_files(date_prefix: str) -> int:
    logger.info("---------- _count_pending_files -------------")
    """Count pending files for a date_prefix without retrieving all data."""
    try:
        count = 0
        last_evaluated_key = None

        while True:
            query_params = {
                'KeyConditionExpression': 'date_prefix = :prefix',
                'FilterExpression': '#status = :status',
                'ExpressionAttributeNames': {'#status': 'status'},
                'ExpressionAttributeValues': {
                    ':prefix': date_prefix,
                    ':status': 'pending'
                },
                'Select': 'COUNT'
            }

            if last_evaluated_key:
                query_params['ExclusiveStartKey'] = last_evaluated_key

            response = table.query(**query_params)
            count += response.get('Count', 0)

            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break

        return count

    except Exception as e:
        logger.error(f"✗ Error counting pending files: {str(e)}")
        return 0


def _get_pending_files(date_prefix: str) -> List[Dict]:
    logger.info("---------- _get_pending_files -------------")
    """Get all pending files with pagination and logging."""
    try:
        files = []
        last_evaluated_key = None
        page = 0

        while True:
            page += 1
            logger.debug(f"📄 Querying DynamoDB page {page}")

            query_params = {
                'KeyConditionExpression': 'date_prefix = :prefix',
                'FilterExpression': '#status = :status',
                'ExpressionAttributeNames': {'#status': 'status'},
                'ExpressionAttributeValues': {
                    ':prefix': date_prefix,
                    ':status': 'pending'
                }
            }

            if last_evaluated_key:
                query_params['ExclusiveStartKey'] = last_evaluated_key

            response = table.query(**query_params)

            logger.debug(f"   Retrieved {len(response.get('Items', []))} items")

            for item in response.get('Items', []):
                # Skip records without file_path (e.g., old records or invalid data)
                if 'file_path' not in item:
                    logger.warning(f"⚠️  Skipping record without file_path: {item.get('file_key', 'unknown')}")
                    continue

                files.append({
                    'bucket': item['file_path'].split('/')[2],
                    'key': '/'.join(item['file_path'].split('/')[3:]),
                    'filename': item['file_key'],  # Range key in DynamoDB (not 'file_name')
                    'size_bytes': int(float(item['file_size_mb']) * 1024 * 1024),
                    'size_mb': float(item['file_size_mb']),
                    'date_prefix': item['date_prefix'],
                    's3_path': item['file_path']
                })

            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break

            logger.debug(f"   More pages available, continuing...")

        logger.info(f"✓ Retrieved {len(files)} total files from {page} page(s)")
        return files

    except Exception as e:
        logger.error(f"✗ Error querying pending files: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return []


def _create_batches(files: List[Dict], allow_partial: bool = False) -> List[List[Dict]]:
    logger.info("---------- _create_batches -------------")
    """
    Create batches based on MAX_FILES_PER_MANIFEST.

    Args:
        files: List of file dictionaries to batch
        allow_partial: If True, include the last partial batch (for orphan flush).
                      If False, only create full batches.

    Returns:
        List of batches, where each batch is a list of file dictionaries.
    """
    try:
        logger.debug(f"📦 Creating batches from {len(files)} files (max {MAX_FILES_PER_MANIFEST} per batch, allow_partial={allow_partial})")

        batches = []

        # Split files into batches of MAX_FILES_PER_MANIFEST
        for i in range(0, len(files), MAX_FILES_PER_MANIFEST):
            batch = files[i:i + MAX_FILES_PER_MANIFEST]

            if len(batch) == MAX_FILES_PER_MANIFEST:
                # Full batch - always include
                batches.append(batch)
                batch_size_mb = sum(f['size_bytes'] for f in batch) / (1024**2)
                logger.debug(f"   Batch {len(batches)}: {len(batch)} files (full), {batch_size_mb:.2f}MB")
            elif allow_partial and len(batch) >= MIN_FILES_FOR_PARTIAL_BATCH:
                # Partial batch - only include if allow_partial is True (orphan flush)
                batches.append(batch)
                batch_size_mb = sum(f['size_bytes'] for f in batch) / (1024**2)
                logger.debug(f"   Batch {len(batches)}: {len(batch)} files (partial/orphan flush), {batch_size_mb:.2f}MB")
            else:
                logger.debug(f"   Holding partial batch: {len(batch)} files (need {MAX_FILES_PER_MANIFEST})")

        logger.info(f"✓ Created {len(batches)} batch(es)")
        return batches

    except Exception as e:
        logger.error(f"✗ Error creating batches: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return []


def _create_manifest(date_prefix: str, batch_idx: int, files: List[Dict]) -> Optional[str]:
    logger.info("---------- _create_manifest -------------")
    """Create manifest file with logging."""
    global _manifests_created_this_execution

    try:
        timestamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
        manifest_key = f'manifests/{date_prefix}/batch-{batch_idx:04d}-{timestamp}.json'

        logger.debug(f"📝 Creating manifest: {manifest_key}")
        logger.debug(f"   Files in manifest: {len(files)}")

        # Build manifest
        manifest = {
            'fileLocations': [
                {
                    'URIPrefixes': [f['s3_path'] for f in files]
                }
            ]
        }

        logger.debug(f"   Manifest content: {json.dumps(manifest, indent=2)}")

        # Upload to S3
        s3_client.put_object(
            Bucket=MANIFEST_BUCKET,
            Key=manifest_key,
            Body=json.dumps(manifest),
            ContentType='application/json'
        )

        manifest_path = f's3://{MANIFEST_BUCKET}/{manifest_key}'
        logger.info(f"✓ Manifest uploaded: {manifest_path}")

        # Track manifest for metadata reporting
        _manifests_created_this_execution.append(manifest_path)

        return manifest_path

    except Exception as e:
        logger.error(f"✗ Error creating manifest: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return None


def _update_file_status(files: List[Dict], status: str, manifest_path: str):
    logger.info("---------- _update_file_status -------------")
    """Update file status with logging and refresh TTL."""
    try:
        logger.debug(f"📝 Updating status for {len(files)} files to '{status}'")

        # Refresh TTL on status update to ensure records don't expire during processing
        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

        updated = 0
        for file_info in files:
            try:
                table.update_item(
                    Key={
                        'date_prefix': file_info['date_prefix'],
                        'file_key': file_info['filename']  # Range key in DynamoDB
                    },
                    UpdateExpression='SET #status = :status, manifest_path = :manifest, updated_at = :updated, #ttl = :ttl',
                    ExpressionAttributeNames={
                        '#status': 'status',
                        '#ttl': 'ttl'
                    },
                    ExpressionAttributeValues={
                        ':status': status,
                        ':manifest': manifest_path,
                        ':updated': datetime.now(timezone.utc).isoformat(),
                        ':ttl': ttl_timestamp
                    }
                )
                updated += 1
            except Exception as e:
                logger.error(f"✗ Error updating {file_info['filename']}: {str(e)}")

        logger.info(f"✓ Updated {updated}/{len(files)} file statuses")

    except Exception as e:
        logger.error(f"✗ Error in _update_file_status: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")


def start_step_function(manifest_path: str, date_prefix: str, file_count: int) -> Optional[str]:
    logger.info("---------- start_step_function -------------")
    """Start Step Functions workflow to process manifest."""
    if not STEP_FUNCTION_ARN:
        logger.warning("⚠️  STEP_FUNCTION_ARN not set, skipping Step Function trigger")
        return None

    try:
        # CRITICAL: Create MANIFEST meta-record in DynamoDB BEFORE starting Step Functions
        # This record tracks the batch processing status (pending → processing → completed/failed)
        # Step Functions will update this record as the Glue job progresses
        logger.info(f"📝 Creating MANIFEST tracking record for {date_prefix}")

        # Extract manifest filename to create unique file_key
        # manifest_path format: "manifests/2026-01-30/batch-0001-20260130-051111.json"
        manifest_filename = manifest_path.split('/')[-1]

        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
        manifest_record = {
            'date_prefix': date_prefix,
            'file_key': f'MANIFEST#{manifest_filename}',  # Unique key per manifest to prevent overwrites
            'status': 'pending',
            'file_count': file_count,
            'manifest_path': manifest_path,
            'created_at': datetime.now(timezone.utc).isoformat(),
            'ttl': ttl_timestamp
        }

        table.put_item(Item=manifest_record)
        logger.info(f"✓ MANIFEST record created: {date_prefix}/MANIFEST#{manifest_filename}")

        # Now start Step Functions execution
        logger.info(f"🚀 Starting Step Function execution for manifest: {manifest_path}")

        response = sfn_client.start_execution(
            stateMachineArn=STEP_FUNCTION_ARN,
            input=json.dumps({
                'manifest_path': manifest_path,
                'date_prefix': date_prefix,
                'file_count': file_count,
                'file_key': f'MANIFEST#{manifest_filename}',  # Pass file_key for DynamoDB updates
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
        )

        execution_arn = response['executionArn']
        logger.info(f"✓ Started Step Function execution: {execution_arn}")
        return execution_arn

    except Exception as e:
        logger.error(f"✗ Failed to start Step Function: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return None
