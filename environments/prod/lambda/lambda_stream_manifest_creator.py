"""
Lambda: Stream Manifest Creator
================================

Triggered by DynamoDB Streams when new file records are inserted into
the file tracking table. Groups files by date_prefix and creates manifests
when the batch threshold is reached.

This provides event-driven manifest creation as an alternative to the
polling-based approach in lambda_manifest_builder.py.

Author: Data Engineering Team
Version: 1.0.0
Environment: DEVELOPMENT
"""

import json
import os
import boto3
import hashlib
import time
import traceback
from datetime import datetime, timezone
from typing import List, Dict, Optional
import logging

# Configure logging
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')
logger = logging.getLogger()
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# AWS Clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
events_client = boto3.client('events')

# Environment Variables
try:
    MANIFEST_BUCKET = os.environ['MANIFEST_BUCKET']
    TRACKING_TABLE = os.environ['TRACKING_TABLE']
except KeyError as e:
    logger.error(f"Missing required environment variable: {e}")
    raise

MAX_FILES_PER_MANIFEST = int(os.environ.get('MAX_FILES_PER_MANIFEST', '10'))
MIN_FILES_FOR_PARTIAL_BATCH = int(os.environ.get('MIN_FILES_FOR_PARTIAL_BATCH', '1'))
EVENT_BUS_NAME = os.environ.get('EVENT_BUS_NAME', '')
STEP_FUNCTION_ARN = os.environ.get('STEP_FUNCTION_ARN', '')
TTL_DAYS = int(os.environ.get('TTL_DAYS', '30'))
NUM_STATUS_SHARDS = int(os.environ.get('NUM_STATUS_SHARDS', '10'))

table = dynamodb.Table(TRACKING_TABLE)

logger.info(f"Stream Manifest Creator initialized: MAX_FILES={MAX_FILES_PER_MANIFEST}, "
            f"EVENT_BUS={EVENT_BUS_NAME}, SHARDS={NUM_STATUS_SHARDS}")


def _compute_shard_id(file_name: str) -> int:
    """Compute a deterministic shard ID from a filename."""
    return int(hashlib.md5(file_name.encode()).hexdigest(), 16) % NUM_STATUS_SHARDS


def _sharded_status(base_status: str, shard_id: int) -> str:
    """Create a sharded status value like 'pending#3'."""
    return f"{base_status}#{shard_id}"


def lambda_handler(event, context):
    """Process DynamoDB Stream events for new file records.

    Groups INSERT events by date_prefix, then checks if enough files
    have accumulated to create a manifest batch.
    """
    logger.info(f"Stream event received: {len(event.get('Records', []))} records")

    # Group new files by date_prefix
    date_prefixes = set()

    for record in event.get('Records', []):
        try:
            # Only process INSERT events (new file records)
            if record['eventName'] != 'INSERT':
                continue

            new_image = record['dynamodb'].get('NewImage', {})
            date_prefix = new_image.get('date_prefix', {}).get('S', '')
            file_key = new_image.get('file_key', {}).get('S', '')
            status = new_image.get('status', {}).get('S', '')

            # Skip non-file records (LOCK#, MANIFEST# entries)
            if file_key.startswith('LOCK#') or file_key.startswith('MANIFEST#'):
                continue

            # Only process pending files
            if not status.startswith('pending'):
                continue

            if date_prefix:
                date_prefixes.add(date_prefix)
                logger.debug(f"New file detected: {date_prefix}/{file_key}")

        except Exception as e:
            logger.error(f"Error processing stream record: {e}")
            logger.error(traceback.format_exc())

    if not date_prefixes:
        logger.info("No new file records to process")
        return {'statusCode': 200}

    logger.info(f"Processing {len(date_prefixes)} date prefix(es): {sorted(date_prefixes)}")

    # Check each date_prefix for manifest creation
    total_manifests = 0
    for date_prefix in sorted(date_prefixes):
        try:
            manifests = _create_manifests_for_prefix(date_prefix)
            total_manifests += manifests
        except Exception as e:
            logger.error(f"Error creating manifests for {date_prefix}: {e}")
            logger.error(traceback.format_exc())

    logger.info(f"Stream processing complete: {total_manifests} manifest(s) created")
    return {'statusCode': 200, 'manifests_created': total_manifests}


def _create_manifests_for_prefix(date_prefix: str) -> int:
    """Check pending file count and create manifests if threshold reached."""

    # Count pending files across all shards
    pending_files = _get_pending_files(date_prefix)
    logger.info(f"Date {date_prefix}: {len(pending_files)} pending files (threshold: {MAX_FILES_PER_MANIFEST})")

    if len(pending_files) < MAX_FILES_PER_MANIFEST:
        return 0

    # Create batches
    manifests_created = 0
    for batch_start in range(0, len(pending_files), MAX_FILES_PER_MANIFEST):
        batch = pending_files[batch_start:batch_start + MAX_FILES_PER_MANIFEST]
        if len(batch) < MAX_FILES_PER_MANIFEST:
            break # Don't create partial batches for current day

        batch_idx = (batch_start // MAX_FILES_PER_MANIFEST) + 1
        manifest_path = _create_manifest(date_prefix, batch_idx, batch)

        if not manifest_path:
            continue

        # Atomically claim files
        claimed = _claim_files(batch, manifest_path)
        if len(claimed) < MIN_FILES_FOR_PARTIAL_BATCH:
            logger.info(f"Only claimed {len(claimed)} files, releasing")
            if claimed:
                _release_files(claimed)
            _delete_manifest(manifest_path)
            continue

        # Publish event
        success = _publish_event(manifest_path, date_prefix, len(claimed))
        if success:
            manifests_created += 1
        else:
            logger.warning(f"Event publish failed, rolling back")
            _release_files(claimed)

    return manifests_created


def _get_pending_files(date_prefix: str) -> List[Dict]:
    """Get pending files for a date prefix using begins_with for sharded status."""
    files = []
    last_key = None

    while True:
        params = {
            'KeyConditionExpression': 'date_prefix = :prefix',
            'FilterExpression': 'begins_with(#status, :status_prefix)',
            'ExpressionAttributeNames': {'#status': 'status'},
            'ExpressionAttributeValues': {
                ':prefix': date_prefix,
                ':status_prefix': 'pending'
            },
            'Limit': MAX_FILES_PER_MANIFEST * 2
        }
        if last_key:
            params['ExclusiveStartKey'] = last_key

        response = table.query(**params)

        for item in response.get('Items', []):
            if 'file_path' not in item:
                continue
            files.append({
                'date_prefix': item['date_prefix'],
                'filename': item['file_key'],
                'status': item.get('status', 'pending'),
                'shard_id': item.get('shard_id', 0),
                's3_path': item['file_path'],
                'size_bytes': int(float(item.get('file_size_mb', 0)) * 1024 * 1024)
            })

        if len(files) >= MAX_FILES_PER_MANIFEST * 2:
            break
        last_key = response.get('LastEvaluatedKey')
        if not last_key:
            break

    return files


def _create_manifest(date_prefix: str, batch_idx: int, files: List[Dict]) -> Optional[str]:
    """Create manifest file in S3."""
    try:
        timestamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
        manifest_key = f'manifests/{date_prefix}/stream-batch-{batch_idx:04d}-{timestamp}.json'

        manifest = {
            'fileLocations': [{
                'URIPrefixes': [f['s3_path'] for f in files]
            }]
        }

        s3_client.put_object(
            Bucket=MANIFEST_BUCKET,
            Key=manifest_key,
            Body=json.dumps(manifest),
            ContentType='application/json'
        )

        manifest_path = f's3://{MANIFEST_BUCKET}/{manifest_key}'
        logger.info(f"Manifest created: {manifest_path}")
        return manifest_path

    except Exception as e:
        logger.error(f"Error creating manifest: {e}")
        return None


def _claim_files(files: List[Dict], manifest_path: str) -> List[Dict]:
    """Atomically claim files using conditional writes."""
    claimed = []
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

    for f in files:
        try:
            shard_id = f.get('shard_id', _compute_shard_id(f['filename']))
            expected = f.get('status', _sharded_status('pending', shard_id))
            new_status = _sharded_status('manifested', shard_id)

            table.update_item(
                Key={'date_prefix': f['date_prefix'], 'file_key': f['filename']},
                UpdateExpression='SET #s = :new, manifest_path = :mp, updated_at = :ua, #t = :ttl',
                ConditionExpression='#s = :expected',
                ExpressionAttributeNames={'#s': 'status', '#t': 'ttl'},
                ExpressionAttributeValues={
                    ':new': new_status,
                    ':expected': expected,
                    ':mp': manifest_path,
                    ':ua': datetime.now(timezone.utc).isoformat(),
                    ':ttl': ttl_timestamp
                }
            )
            claimed.append(f)
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            logger.debug(f"File {f['filename']} already claimed")
        except Exception as e:
            logger.error(f"Error claiming {f['filename']}: {e}")

    logger.info(f"Claimed {len(claimed)}/{len(files)} files")
    return claimed


def _release_files(files: List[Dict]):
    """Release claimed files back to pending status."""
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
    for f in files:
        try:
            shard_id = f.get('shard_id', _compute_shard_id(f['filename']))
            table.update_item(
                Key={'date_prefix': f['date_prefix'], 'file_key': f['filename']},
                UpdateExpression='SET #s = :s, updated_at = :ua, #t = :ttl REMOVE manifest_path',
                ExpressionAttributeNames={'#s': 'status', '#t': 'ttl'},
                ExpressionAttributeValues={
                    ':s': _sharded_status('pending', shard_id),
                    ':ua': datetime.now(timezone.utc).isoformat(),
                    ':ttl': ttl_timestamp
                }
            )
        except Exception as e:
            logger.error(f"Error releasing {f['filename']}: {e}")


def _delete_manifest(manifest_path: str):
    """Delete a manifest file from S3."""
    try:
        parts = manifest_path.replace('s3://', '').split('/', 1)
        s3_client.delete_object(Bucket=parts[0], Key=parts[1])
        logger.info(f"Deleted unused manifest: {manifest_path}")
    except Exception as e:
        logger.error(f"Error deleting manifest: {e}")


def _publish_event(manifest_path: str, date_prefix: str, file_count: int) -> bool:
    """Publish ManifestReady event via EventBridge."""
    if not EVENT_BUS_NAME:
        logger.warning("EVENT_BUS_NAME not set, skipping event publish")
        return True

    try:
        manifest_filename = manifest_path.split('/')[-1]
        ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)

        event_detail = {
            'manifest_path': manifest_path,
            'date_prefix': date_prefix,
            'file_count': file_count,
            'file_key': f'MANIFEST#{manifest_filename}',
            'timestamp': datetime.now(timezone.utc).isoformat()
        }

        response = events_client.put_events(
            Entries=[{
                'Source': 'etl.pipeline',
                'DetailType': 'ManifestReady',
                'Detail': json.dumps(event_detail),
                'EventBusName': EVENT_BUS_NAME
            }]
        )

        if response.get('FailedEntryCount', 0) > 0:
            logger.error(f"EventBridge put_events failed: {response['Entries']}")
            return False

        # Write MANIFEST tracking record
        table.put_item(Item={
            'date_prefix': date_prefix,
            'file_key': f'MANIFEST#{manifest_filename}',
            'status': 'pending',
            'file_count': file_count,
            'manifest_path': manifest_path,
            'trigger_type': 'stream',
            'created_at': datetime.now(timezone.utc).isoformat(),
            'ttl': ttl_timestamp
        })

        logger.info(f"Published ManifestReady event: {manifest_path}")
        return True

    except Exception as e:
        logger.error(f"EventBridge publish failed: {e}")
        logger.error(traceback.format_exc())
        return False
