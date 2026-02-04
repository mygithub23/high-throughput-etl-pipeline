"""
Lambda #1: Manifest Builder - PRODUCTION VERSION
=================================================

Optimized production version with minimal logging and maximum performance.

Author: Data Engineering Team
Version: 1.2.0-prod
Environment: PRODUCTION

Features:
- Minimal INFO-level logging
- Optimized error handling
- Production-grade performance
"""

import json
import os
import boto3
import time
import re
from datetime import datetime
from decimal import Decimal
from typing import List, Dict, Tuple, Optional
import logging

# Configure production logging (INFO level only)
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS Clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sfn_client = boto3.client('stepfunctions')

# Environment Variables
MANIFEST_BUCKET = os.environ['MANIFEST_BUCKET']
TRACKING_TABLE = os.environ['TRACKING_TABLE']
GLUE_JOB_NAME = os.environ.get('GLUE_JOB_NAME', '')
MAX_BATCH_SIZE_GB = float(os.environ.get('MAX_BATCH_SIZE_GB', '1.0'))
QUARANTINE_BUCKET = os.environ.get('QUARANTINE_BUCKET', '')
EXPECTED_FILE_SIZE_MB = float(os.environ.get('EXPECTED_FILE_SIZE_MB', '3.5'))
SIZE_TOLERANCE_PERCENT = float(os.environ.get('SIZE_TOLERANCE_PERCENT', '10'))
LOCK_TABLE = os.environ.get('LOCK_TABLE', TRACKING_TABLE)
LOCK_TTL_SECONDS = int(os.environ.get('LOCK_TTL_SECONDS', '300'))
STEP_FUNCTION_ARN = os.environ.get('STEP_FUNCTION_ARN', '')

table = dynamodb.Table(TRACKING_TABLE)


class DistributedLock:
    """Simple distributed lock using DynamoDB."""

    def __init__(self, lock_table: str, lock_key: str, ttl_seconds: int = 300):
        self.table = dynamodb.Table(lock_table)
        self.lock_key = lock_key
        self.ttl_seconds = ttl_seconds
        self.lock_id = f"{os.environ.get('AWS_LAMBDA_LOG_STREAM_NAME', 'local')}_{int(time.time() * 1000)}"
        self.acquired = False

    def acquire(self) -> bool:
        try:
            ttl = int(time.time()) + self.ttl_seconds
            self.table.put_item(
                Item={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_name': 'LOCK',
                    'lock_id': self.lock_id,
                    'ttl': ttl,
                    'created_at': datetime.utcnow().isoformat()
                },
                ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now',
                ExpressionAttributeNames={'#ttl': 'ttl'},
                ExpressionAttributeValues={':now': int(time.time())}
            )
            self.acquired = True
            return True
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            return False
        except Exception as e:
            logger.error(f"Error acquiring lock: {str(e)}")
            return False

    def release(self):
        if not self.acquired:
            return
        try:
            self.table.delete_item(
                Key={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_name': 'LOCK'
                },
                ConditionExpression='lock_id = :lock_id',
                ExpressionAttributeValues={':lock_id': self.lock_id}
            )
            self.acquired = False
        except Exception as e:
            logger.error(f"Error releasing lock: {str(e)}")


def lambda_handler(event, context):
    """Main Lambda handler."""
    try:
        records = event.get('Records', [])

        if not records:
            return {'statusCode': 200, 'body': 'No records'}

        logger.info(f"Processing {len(records)} records")

        files_processed = 0
        files_quarantined = 0

        for record in records:
            try:
                s3_event = json.loads(record['body'])

                for s3_record in s3_event.get('Records', []):
                    bucket = s3_record['s3']['bucket']['name']
                    key = s3_record['s3']['object']['key']
                    size = s3_record['s3']['object']['size']

                    result = process_file(bucket, key, size)

                    if result == 'processed':
                        files_processed += 1
                    elif result == 'quarantined':
                        files_quarantined += 1

            except Exception as e:
                logger.error(f"Error processing record: {str(e)}")

        logger.info(f"Summary - Processed: {files_processed}, Quarantined: {files_quarantined}")

        return {
            'statusCode': 200,
            'body': json.dumps({'processed': files_processed, 'quarantined': files_quarantined})
        }

    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}")
        raise


def process_file(bucket: str, key: str, size: int) -> str:
    """Process a single file."""
    try:
        # Validate
        is_valid, reason = validate_file(key, size)

        if not is_valid:
            quarantine_file(bucket, key, reason)
            return 'quarantined'

        # Track
        date_prefix, file_name = extract_date_and_filename(key)
        track_file(bucket, key, date_prefix, file_name, size)

        # Create manifests if ready
        create_manifests_if_ready(date_prefix)

        return 'processed'

    except Exception as e:
        logger.error(f"Error processing file {key}: {str(e)}")
        raise


def validate_file(key: str, size: int) -> Tuple[bool, str]:
    """Validate file."""
    if not key.endswith('.ndjson'):
        return False, "Invalid extension"

    size_mb = size / (1024 * 1024)
    min_size = EXPECTED_FILE_SIZE_MB * (1 - SIZE_TOLERANCE_PERCENT / 100)
    max_size = EXPECTED_FILE_SIZE_MB * (1 + SIZE_TOLERANCE_PERCENT / 100)

    if size_mb < min_size or size_mb > max_size:
        return False, f"Size {size_mb:.2f}MB out of range"

    return True, "OK"


def quarantine_file(bucket: str, key: str, reason: str):
    """Quarantine invalid file."""
    if not QUARANTINE_BUCKET:
        return

    try:
        s3_client.copy_object(
            Bucket=QUARANTINE_BUCKET,
            Key=key,
            CopySource={'Bucket': bucket, 'Key': key},
            Metadata={'quarantine_reason': reason}
        )
    except Exception as e:
        logger.error(f"Error quarantining {key}: {str(e)}")


def extract_date_and_filename(key: str) -> Tuple[str, str]:
    """Extract date and filename."""
    parts = key.split('/')
    filename = parts[-1]

    match = re.search(r'(\d{4}-\d{2}-\d{2})', key)
    date_prefix = match.group(1) if match else datetime.utcnow().strftime('%Y-%m-%d')

    return date_prefix, filename


def track_file(bucket: str, key: str, date_prefix: str, file_name: str, size: int):
    """Track file in DynamoDB."""
    table.put_item(
        Item={
            'date_prefix': date_prefix,
            'file_name': file_name,
            'file_path': f's3://{bucket}/{key}',
            'file_size_mb': Decimal(str(size / (1024 * 1024))),
            'status': 'pending',
            'created_at': datetime.utcnow().isoformat()
        }
    )


def create_manifests_if_ready(date_prefix: str) -> int:
    """Create manifests if threshold reached."""
    lock = DistributedLock(LOCK_TABLE, f'manifest-{date_prefix}', LOCK_TTL_SECONDS)

    try:
        if not lock.acquire():
            return 0

        all_files = _get_pending_files(date_prefix)

        if not all_files:
            return 0

        total_size_bytes = sum(f['size_bytes'] for f in all_files)

        if total_size_bytes < MAX_BATCH_SIZE_GB * (1024**3):
            return 0

        batches = _create_batches(all_files)
        manifests_created = 0

        for batch_idx, batch_files in enumerate(batches, 1):
            manifest_path = _create_manifest(date_prefix, batch_idx, batch_files)

            if manifest_path:
                manifests_created += 1
                _update_file_status(batch_files, 'manifested', manifest_path)
                # Trigger Step Functions workflow
                start_step_function(manifest_path, date_prefix, len(batch_files))

        if manifests_created > 0:
            logger.info(f"Created {manifests_created} manifests for {date_prefix}")

        return manifests_created

    finally:
        lock.release()


def _get_pending_files(date_prefix: str) -> List[Dict]:
    """Get pending files."""
    files = []
    last_evaluated_key = None

    while True:
        query_params = {
            'KeyConditionExpression': 'date_prefix = :prefix',
            'FilterExpression': '#status = :status',
            'ExpressionAttributeNames': {'#status': 'status'},
            'ExpressionAttributeValues': {':prefix': date_prefix, ':status': 'pending'}
        }

        if last_evaluated_key:
            query_params['ExclusiveStartKey'] = last_evaluated_key

        response = table.query(**query_params)

        for item in response.get('Items', []):
            files.append({
                'bucket': item['file_path'].split('/')[2],
                'key': '/'.join(item['file_path'].split('/')[3:]),
                'filename': item['file_name'],
                'size_bytes': int(float(item['file_size_mb']) * 1024 * 1024),
                'size_mb': float(item['file_size_mb']),
                'date_prefix': item['date_prefix'],
                's3_path': item['file_path']
            })

        last_evaluated_key = response.get('LastEvaluatedKey')
        if not last_evaluated_key:
            break

    return files


def _create_batches(files: List[Dict]) -> List[List[Dict]]:
    """Create batches."""
    batches = []
    current_batch = []
    current_size = 0
    max_size = int(MAX_BATCH_SIZE_GB * (1024**3))

    for file_info in files:
        if current_size + file_info['size_bytes'] > max_size and current_batch:
            batches.append(current_batch)
            current_batch = [file_info]
            current_size = file_info['size_bytes']
        else:
            current_batch.append(file_info)
            current_size += file_info['size_bytes']

    if current_batch:
        if current_size >= max_size * 0.5 or len(batches) == 0:
            batches.append(current_batch)

    return batches


def _create_manifest(date_prefix: str, batch_idx: int, files: List[Dict]) -> Optional[str]:
    """Create manifest file."""
    try:
        timestamp = datetime.utcnow().strftime('%Y%m%d-%H%M%S')
        manifest_key = f'manifests/{date_prefix}/batch-{batch_idx:04d}-{timestamp}.json'

        manifest = {
            'fileLocations': [{'URIPrefixes': [f['s3_path'] for f in files]}]
        }

        s3_client.put_object(
            Bucket=MANIFEST_BUCKET,
            Key=manifest_key,
            Body=json.dumps(manifest),
            ContentType='application/json'
        )

        return f's3://{MANIFEST_BUCKET}/{manifest_key}'

    except Exception as e:
        logger.error(f"Error creating manifest: {str(e)}")
        return None


def _update_file_status(files: List[Dict], status: str, manifest_path: str):
    """Update file status."""
    for file_info in files:
        try:
            table.update_item(
                Key={'date_prefix': file_info['date_prefix'], 'file_name': file_info['filename']},
                UpdateExpression='SET #status = :status, manifest_path = :manifest, updated_at = :updated',
                ExpressionAttributeNames={'#status': 'status'},
                ExpressionAttributeValues={
                    ':status': status,
                    ':manifest': manifest_path,
                    ':updated': datetime.utcnow().isoformat()
                }
            )
        except Exception as e:
            logger.error(f"Error updating {file_info['filename']}: {str(e)}")


def start_step_function(manifest_path: str, date_prefix: str, file_count: int) -> Optional[str]:
    """Start Step Functions workflow to process manifest."""
    if not STEP_FUNCTION_ARN:
        logger.warning("STEP_FUNCTION_ARN not set, skipping Step Function trigger")
        return None

    try:
        response = sfn_client.start_execution(
            stateMachineArn=STEP_FUNCTION_ARN,
            input=json.dumps({
                'manifest_path': manifest_path,
                'date_prefix': date_prefix,
                'file_count': file_count,
                'timestamp': datetime.utcnow().isoformat()
            })
        )

        logger.info(f"Started Step Function execution: {response['executionArn']}")
        return response['executionArn']

    except Exception as e:
        logger.error(f"Failed to start Step Function: {str(e)}")
        return None
