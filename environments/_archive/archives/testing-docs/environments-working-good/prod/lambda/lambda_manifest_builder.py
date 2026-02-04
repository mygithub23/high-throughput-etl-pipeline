"""
Lambda #1: Manifest Builder - PRODUCTION VERSION
=================================================

Production-optimized version with INFO-level logging.

Author: Data Engineering Team
Version: 1.3.0
Environment: PRODUCTION

Features:
- INFO-level logging for production monitoring
- Full error handling with stack traces on errors only
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

# Configure INFO-level logging for production
logger = logging.getLogger()
logger.setLevel(logging.INFO)  # INFO level for production

# AWS Clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
glue_client = boto3.client('glue')
sfn_client = boto3.client('stepfunctions')

# Environment Variables with validation
try:
    MANIFEST_BUCKET = os.environ['MANIFEST_BUCKET']
    TRACKING_TABLE = os.environ['TRACKING_TABLE']
    logger.info(f"Environment loaded - Manifest bucket: {MANIFEST_BUCKET}, Tracking table: {TRACKING_TABLE}")
except KeyError as e:
    logger.error(f"Missing required environment variable: {e}")
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
TTL_DAYS = int(os.environ.get('TTL_DAYS', '90'))  # Production: 90 days default

# Log configuration at startup
logger.info(f"Configuration: MAX_FILES_PER_MANIFEST={MAX_FILES_PER_MANIFEST}, MIN_FILES_FOR_PARTIAL_BATCH={MIN_FILES_FOR_PARTIAL_BATCH}, TTL_DAYS={TTL_DAYS}")

# DynamoDB table
table = dynamodb.Table(TRACKING_TABLE)


class DistributedLock:
    """Distributed lock using DynamoDB for coordination."""

    def __init__(self, lock_table: str, lock_key: str, ttl_seconds: int = 300):
        self.table = dynamodb.Table(lock_table)
        self.lock_key = lock_key
        self.ttl_seconds = ttl_seconds
        self.lock_id = f"{os.environ.get('AWS_LAMBDA_LOG_STREAM_NAME', 'local')}_{int(time.time() * 1000)}"
        self.acquired = False

    def acquire(self) -> bool:
        """Attempt to acquire the lock."""
        try:
            ttl = int(time.time()) + self.ttl_seconds

            self.table.put_item(
                Item={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_key': 'LOCK',
                    'lock_id': self.lock_id,
                    'ttl': ttl,
                    'created_at': datetime.now(timezone.utc).isoformat()
                },
                ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now',
                ExpressionAttributeNames={'#ttl': 'ttl'},
                ExpressionAttributeValues={':now': int(time.time())}
            )
            self.acquired = True
            logger.info(f"Lock acquired: {self.lock_key}")
            return True
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            logger.info(f"Lock already held by another process: {self.lock_key}")
            return False
        except Exception as e:
            logger.error(f"Error acquiring lock: {str(e)}")
            return False

    def release(self):
        """Release the lock."""
        if not self.acquired:
            return

        try:
            self.table.delete_item(
                Key={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_key': 'LOCK'
                },
                ConditionExpression='lock_id = :lock_id',
                ExpressionAttributeValues={':lock_id': self.lock_id}
            )
            self.acquired = False
            logger.info(f"Lock released: {self.lock_key}")
        except Exception as e:
            logger.error(f"Error releasing lock: {str(e)}")


def lambda_handler(event, context):
    """Main Lambda handler."""
    logger.info(f"Lambda invocation started - Request ID: {context.aws_request_id}")

    try:
        records = event.get('Records', [])
        logger.info(f"Processing {len(records)} SQS records")

        if not records:
            return {'statusCode': 200, 'body': json.dumps('No records to process')}

        files_processed = 0
        files_quarantined = 0
        errors = []

        for idx, record in enumerate(records, 1):
            try:
                s3_event = json.loads(record['body'])
                s3_records = s3_event.get('Records', [])

                for s3_record in s3_records:
                    try:
                        bucket = s3_record['s3']['bucket']['name']
                        key = s3_record['s3']['object']['key']
                        size = s3_record['s3']['object']['size']

                        logger.info(f"Processing file: s3://{bucket}/{key} ({size / (1024**2):.2f} MB)")

                        result = process_file(bucket, key, size)

                        if result == 'processed':
                            files_processed += 1
                        elif result == 'quarantined':
                            files_quarantined += 1

                    except Exception as e:
                        error_msg = f"Error processing S3 record: {str(e)}"
                        logger.error(f"{error_msg}\n{traceback.format_exc()}")
                        errors.append(error_msg)

            except Exception as e:
                error_msg = f"Error processing SQS record {idx}: {str(e)}"
                logger.error(f"{error_msg}\n{traceback.format_exc()}")
                errors.append(error_msg)

        logger.info(f"Processing complete - Processed: {files_processed}, Quarantined: {files_quarantined}, Errors: {len(errors)}")

        return {
            'statusCode': 200 if not errors else 207,
            'body': json.dumps({
                'processed': files_processed,
                'quarantined': files_quarantined,
                'errors': len(errors)
            }, default=str)
        }

    except Exception as e:
        logger.error(f"FATAL ERROR: {str(e)}\n{traceback.format_exc()}")
        raise


def process_file(bucket: str, key: str, size: int) -> str:
    """Process a single file."""
    try:
        is_valid, reason = validate_file(key, size)

        if not is_valid:
            logger.warning(f"Validation failed for {key}: {reason}")
            quarantine_file(bucket, key, reason)
            return 'quarantined'

        date_prefix, file_name = extract_date_and_filename(key)
        track_file(bucket, key, date_prefix, file_name, size)

        # Keep creating manifests until all pending files are processed
        # This handles the case where multiple Lambdas run in parallel
        total_manifests = 0
        max_iterations = 50  # Safety limit
        consecutive_failures = 0
        max_consecutive_failures = 3  # Retry up to 3 times if lock is held

        for iteration in range(1, max_iterations + 1):
            manifests_created = create_manifests_if_ready(date_prefix)

            if manifests_created > 0:
                total_manifests += manifests_created
                consecutive_failures = 0
                logger.info(f"Iteration {iteration}: Created {manifests_created} manifest(s) for {date_prefix}")
                time.sleep(0.1)
            else:
                # Check if there are still enough pending files (lock contention case)
                pending_count = _count_pending_files(date_prefix)

                if pending_count >= MAX_FILES_PER_MANIFEST:
                    consecutive_failures += 1
                    if consecutive_failures < max_consecutive_failures:
                        logger.info(f"Lock contention detected, retrying ({consecutive_failures}/{max_consecutive_failures})")
                        time.sleep(0.5)
                        continue
                    else:
                        logger.info(f"Max retries reached, another Lambda will handle remaining files")
                        break
                else:
                    break

        if total_manifests > 0:
            logger.info(f"Total: Created {total_manifests} manifest(s) for {date_prefix}")

        # Also check for orphaned files from previous days and flush them
        orphan_manifests = flush_orphaned_dates()
        if orphan_manifests > 0:
            logger.info(f"Flushed {orphan_manifests} manifest(s) from orphaned dates")

        return 'processed'

    except Exception as e:
        logger.error(f"Error in process_file: {str(e)}\n{traceback.format_exc()}")
        raise


def validate_file(key: str, size: int) -> Tuple[bool, str]:
    """Validate file extension and size."""
    if not key.endswith('.ndjson'):
        return False, "Invalid extension (expected .ndjson)"

    size_mb = size / (1024 * 1024)
    min_size = EXPECTED_FILE_SIZE_MB * (1 - SIZE_TOLERANCE_PERCENT / 100)
    max_size = EXPECTED_FILE_SIZE_MB * (1 + SIZE_TOLERANCE_PERCENT / 100)

    if size_mb < min_size or size_mb > max_size:
        return False, f"Size {size_mb:.2f}MB outside expected range {min_size:.2f}-{max_size:.2f}MB"

    return True, "OK"


def quarantine_file(bucket: str, key: str, reason: str):
    """Quarantine invalid file."""
    if not QUARANTINE_BUCKET:
        logger.warning("QUARANTINE_BUCKET not set, skipping quarantine")
        return

    try:
        logger.info(f"Quarantining file to s3://{QUARANTINE_BUCKET}/{key} - Reason: {reason}")
        s3_client.copy_object(
            Bucket=QUARANTINE_BUCKET,
            Key=key,
            CopySource={'Bucket': bucket, 'Key': key},
            Metadata={'quarantine_reason': reason, 'original_bucket': bucket}
        )
    except Exception as e:
        logger.error(f"Error quarantining file: {str(e)}")
        raise


def extract_date_and_filename(key: str) -> Tuple[str, str]:
    """Extract date and filename from S3 key."""
    parts = key.split('/')
    filename = parts[-1]

    match = re.search(r'(\d{4}-\d{2}-\d{2})', key)
    if match:
        date_prefix = match.group(1)
    else:
        date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        logger.warning(f"No date found in key, using current date: {date_prefix}")

    return date_prefix, filename


def track_file(bucket: str, key: str, date_prefix: str, file_name: str, size: int):
    """Track file in DynamoDB with TTL."""
    # Calculate TTL (Unix timestamp when record should expire)
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

    item = {
        'date_prefix': date_prefix,
        'file_key': file_name,
        'file_path': f's3://{bucket}/{key}',
        'file_size_mb': Decimal(str(size / (1024 * 1024))),
        'status': 'pending',
        'created_at': datetime.now(timezone.utc).isoformat(),
        'ttl': ttl_timestamp  # TTL attribute for automatic expiration
    }
    table.put_item(Item=item)


def create_manifests_if_ready(date_prefix: str) -> int:
    """
    Check if ready to create manifests based on file count threshold.

    For current day: Requires MAX_FILES_PER_MANIFEST files to create a batch.
    For previous days: Creates partial batch with any remaining files (orphan flush).

    This prevents files from being stranded when the day changes before
    reaching the full batch threshold.
    """
    lock = DistributedLock(LOCK_TABLE, f'manifest-{date_prefix}', LOCK_TTL_SECONDS)

    try:
        if not lock.acquire():
            return 0

        all_files = _get_pending_files(date_prefix)
        logger.info(f"Found {len(all_files)} pending files for {date_prefix} (threshold: {MAX_FILES_PER_MANIFEST})")

        if not all_files:
            return 0

        # Determine if this is a previous day (orphan flush scenario)
        today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        is_previous_day = date_prefix < today

        if is_previous_day:
            logger.info(f"Date {date_prefix} is from a previous day (today: {today}) - triggering orphan flush")

        # Determine the threshold for creating a manifest
        effective_threshold = MIN_FILES_FOR_PARTIAL_BATCH if is_previous_day else MAX_FILES_PER_MANIFEST

        if len(all_files) < effective_threshold:
            logger.info(f"Not enough files yet: {len(all_files)} < {effective_threshold}")
            return 0

        if is_previous_day:
            logger.info(f"Processing {len(all_files)} orphaned files from {date_prefix}")
        else:
            logger.info(f"File threshold reached for {date_prefix}")

        # Create batches - allow partial for previous days
        batches = _create_batches(all_files, allow_partial=is_previous_day)
        logger.info(f"Created {len(batches)} batch(es)")

        manifests_created = 0
        for batch_idx, batch_files in enumerate(batches, 1):
            try:
                manifest_path = _create_manifest(date_prefix, batch_idx, batch_files)

                if manifest_path:
                    manifests_created += 1
                    _update_file_status(batch_files, 'manifested', manifest_path)
                    start_step_function(manifest_path, date_prefix, len(batch_files))

            except Exception as e:
                logger.error(f"Error creating manifest {batch_idx}: {str(e)}")

        return manifests_created

    except Exception as e:
        logger.error(f"Error in create_manifests_if_ready: {str(e)}")
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
    try:
        today = datetime.now(timezone.utc).strftime('%Y-%m-%d')

        # Query the status-index GSI to find all pending files from previous days
        orphaned_dates = _get_orphaned_date_prefixes(today)

        if not orphaned_dates:
            return 0

        logger.info(f"Found {len(orphaned_dates)} orphaned date(s): {orphaned_dates}")

        total_manifests = 0
        for date_prefix in orphaned_dates:
            logger.info(f"Flushing orphaned files for {date_prefix}")
            manifests = create_manifests_if_ready(date_prefix)
            total_manifests += manifests

        return total_manifests

    except Exception as e:
        logger.error(f"Error in flush_orphaned_dates: {str(e)}")
        return 0


def _get_orphaned_date_prefixes(today: str) -> List[str]:
    """
    Get all unique date_prefixes with pending files that are before today.

    Uses the status-index GSI to efficiently query by status.
    """
    try:
        orphaned_dates = set()
        last_evaluated_key = None

        while True:
            query_params = {
                'IndexName': 'status-index',
                'KeyConditionExpression': '#status = :status',
                'ExpressionAttributeNames': {'#status': 'status'},
                'ExpressionAttributeValues': {':status': 'pending'},
                'ProjectionExpression': 'date_prefix'
            }

            if last_evaluated_key:
                query_params['ExclusiveStartKey'] = last_evaluated_key

            response = table.query(**query_params)

            for item in response.get('Items', []):
                date_prefix = item.get('date_prefix')
                if date_prefix and date_prefix < today:
                    orphaned_dates.add(date_prefix)

            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break

        return sorted(list(orphaned_dates))

    except Exception as e:
        logger.error(f"Error getting orphaned date prefixes: {str(e)}")
        return []


def _count_pending_files(date_prefix: str) -> int:
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
        logger.error(f"Error counting pending files: {str(e)}")
        return 0


def _get_pending_files(date_prefix: str) -> List[Dict]:
    """Get all pending files with pagination."""
    files = []
    last_evaluated_key = None

    while True:
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

        for item in response.get('Items', []):
            files.append({
                'bucket': item['file_path'].split('/')[2],
                'key': '/'.join(item['file_path'].split('/')[3:]),
                'filename': item['file_key'],
                'size_bytes': int(float(item['file_size_mb']) * 1024 * 1024),
                'size_mb': float(item['file_size_mb']),
                'date_prefix': item['date_prefix'],
                's3_path': item['file_path']
            })

        last_evaluated_key = response.get('LastEvaluatedKey')
        if not last_evaluated_key:
            break

    return files


def _create_batches(files: List[Dict], allow_partial: bool = False) -> List[List[Dict]]:
    """
    Create batches based on MAX_FILES_PER_MANIFEST.

    Args:
        files: List of file dictionaries to batch
        allow_partial: If True, include the last partial batch (for orphan flush).
                      If False, only create full batches.

    Returns:
        List of batches, where each batch is a list of file dictionaries.
    """
    batches = []

    for i in range(0, len(files), MAX_FILES_PER_MANIFEST):
        batch = files[i:i + MAX_FILES_PER_MANIFEST]

        if len(batch) == MAX_FILES_PER_MANIFEST:
            batches.append(batch)
        elif allow_partial and len(batch) >= MIN_FILES_FOR_PARTIAL_BATCH:
            batches.append(batch)
            logger.info(f"Including partial batch with {len(batch)} files (orphan flush)")

    return batches


def _create_manifest(date_prefix: str, batch_idx: int, files: List[Dict]) -> Optional[str]:
    """Create manifest file."""
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    manifest_key = f'manifests/{date_prefix}/batch-{batch_idx:04d}-{timestamp}.json'

    manifest = {
        'fileLocations': [
            {
                'URIPrefixes': [f['s3_path'] for f in files]
            }
        ]
    }

    s3_client.put_object(
        Bucket=MANIFEST_BUCKET,
        Key=manifest_key,
        Body=json.dumps(manifest),
        ContentType='application/json'
    )

    manifest_path = f's3://{MANIFEST_BUCKET}/{manifest_key}'
    logger.info(f"Manifest created: {manifest_path} ({len(files)} files)")

    return manifest_path


def _update_file_status(files: List[Dict], status: str, manifest_path: str):
    """Update file status in DynamoDB and refresh TTL."""
    # Refresh TTL on status update to ensure records don't expire during processing
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

    updated = 0
    for file_info in files:
        try:
            table.update_item(
                Key={
                    'date_prefix': file_info['date_prefix'],
                    'file_key': file_info['filename']
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
            logger.error(f"Error updating {file_info['filename']}: {str(e)}")

    logger.info(f"Updated {updated}/{len(files)} file statuses to '{status}'")


def start_step_function(manifest_path: str, date_prefix: str, file_count: int) -> Optional[str]:
    """Start Step Functions workflow to process manifest."""
    if not STEP_FUNCTION_ARN:
        logger.warning("STEP_FUNCTION_ARN not set, skipping Step Function trigger")
        return None

    try:
        # CRITICAL: Create MANIFEST meta-record in DynamoDB BEFORE starting Step Functions
        # This record tracks the batch processing status (pending → processing → completed/failed)
        # Step Functions will update this record as the Glue job progresses
        logger.info(f"Creating MANIFEST tracking record for {date_prefix}")

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
        logger.info(f"MANIFEST record created: {date_prefix}/MANIFEST#{manifest_filename}")

        # Now start Step Functions execution
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
        logger.info(f"Started Step Function execution: {execution_arn}")
        return execution_arn

    except Exception as e:
        logger.error(f"Failed to start Step Function: {str(e)}")
        return None
