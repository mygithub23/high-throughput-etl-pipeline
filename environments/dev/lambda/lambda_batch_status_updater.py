"""
Lambda: Batch Status Updater
=============================

Called by Step Functions after Glue job completes (success or failure).
Updates individual file records in DynamoDB that belong to a manifest.

The Step Functions state machine updates the MANIFEST meta-record directly
via native DynamoDB integration. This Lambda handles the batch update of
individual file records, which cannot be done natively in Step Functions
(no loop construct for batch DynamoDB writes).

Flow:
  Step Functions → UpdateStatusCompleted (MANIFEST record) → this Lambda (file records)
  Step Functions → UpdateStatusFailed (MANIFEST record) → this Lambda (file records) → SNS alert

Author: Data Engineering Team
Version: 1.0.0
Environment: DEVELOPMENT
"""

import json
import os
import boto3
import time
import traceback
from datetime import datetime, timezone
from typing import List, Dict
import logging

# Configure logging
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')
logger = logging.getLogger()
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# AWS Clients
dynamodb = boto3.resource('dynamodb')

# Environment Variables
try:
    TRACKING_TABLE = os.environ['TRACKING_TABLE']
except KeyError as e:
    logger.error(f"Missing required environment variable: {e}")
    raise

TTL_DAYS = int(os.environ.get('TTL_DAYS', '30'))

table = dynamodb.Table(TRACKING_TABLE)

logger.info(f"Batch Status Updater initialized: TABLE={TRACKING_TABLE}, TTL_DAYS={TTL_DAYS}")


def lambda_handler(event, context):
    """Update individual file statuses based on Glue job result.

    Input event (from Step Functions):
    {
        "manifest_path": "s3://bucket/manifests/2026-02-01/batch-001.json",
        "date_prefix": "2026-02-01",
        "new_status": "completed" | "failed",
        "glue_job_run_id": "jr_xxx" (optional, on success),
        "error_message": "..." (optional, on failure)
    }

    Returns:
    {
        "statusCode": 200,
        "files_updated": N,
        "files_failed": N,
        "manifest_path": "...",
        "date_prefix": "..."
    }
    """
    manifest_path = event['manifest_path']
    date_prefix = event['date_prefix']
    new_status = event['new_status']
    glue_job_run_id = event.get('glue_job_run_id', '')
    error_message = event.get('error_message', '')

    logger.info(f"Batch status update: date_prefix={date_prefix}, "
                f"new_status={new_status}, manifest={manifest_path}")

    # Find all individual file records belonging to this manifest
    files = _get_files_for_manifest(date_prefix, manifest_path)
    logger.info(f"Found {len(files)} individual file records for manifest")

    if not files:
        logger.warning(f"No individual file records found for manifest {manifest_path}")
        return {
            'statusCode': 200,
            'files_updated': 0,
            'files_failed': 0,
            'manifest_path': manifest_path,
            'date_prefix': date_prefix
        }

    # Update each file record
    updated = 0
    failed = 0
    for file_info in files:
        try:
            _update_file_status(file_info, new_status, glue_job_run_id, error_message)
            updated += 1
        except Exception as e:
            failed += 1
            logger.error(f"Failed to update {file_info['file_key']}: {e}")
            logger.error(traceback.format_exc())

    logger.info(f"Batch update complete: {updated} updated, {failed} failed out of {len(files)} files")

    return {
        'statusCode': 200,
        'files_updated': updated,
        'files_failed': failed,
        'manifest_path': manifest_path,
        'date_prefix': date_prefix
    }


def _get_files_for_manifest(date_prefix: str, manifest_path: str) -> List[Dict]:
    """Query DynamoDB for individual file records belonging to a specific manifest.

    Filters out MANIFEST# and LOCK# meta-records — only returns actual file records.
    """
    files = []
    last_key = None

    while True:
        # Note: file_key is the sort key (primary key attribute) so it CANNOT
        # be used in FilterExpression. We filter out MANIFEST#/LOCK# meta-records
        # in Python after the query returns.
        params = {
            'KeyConditionExpression': 'date_prefix = :dp',
            'FilterExpression': 'manifest_path = :mp',
            'ExpressionAttributeValues': {
                ':dp': date_prefix,
                ':mp': manifest_path
            }
        }
        if last_key:
            params['ExclusiveStartKey'] = last_key

        response = table.query(**params)

        for item in response.get('Items', []):
            fk = item['file_key']
            if fk.startswith('MANIFEST#') or fk.startswith('LOCK#'):
                continue
            files.append({
                'date_prefix': item['date_prefix'],
                'file_key': fk,
                'status': item.get('status', '')
            })

        last_key = response.get('LastEvaluatedKey')
        if not last_key:
            break

    return files


def _update_file_status(file_info: Dict, new_status: str,
                        glue_job_run_id: str, error_message: str):
    """Update a single file record's status, preserving shard suffix."""
    current_status = file_info['status']

    # Preserve shard suffix if present (e.g., manifested#3 → completed#3)
    shard_suffix = ''
    if '#' in current_status:
        parts = current_status.split('#', 1)
        shard_suffix = f'#{parts[1]}'

    target_status = f'{new_status}{shard_suffix}'
    ttl_timestamp = int(time.time()) + (TTL_DAYS * 24 * 60 * 60)
    now = datetime.now(timezone.utc).isoformat()

    update_expr = 'SET #s = :new_status, updated_at = :ua, #t = :ttl'
    expr_names = {'#s': 'status', '#t': 'ttl'}
    expr_values = {
        ':new_status': target_status,
        ':ua': now,
        ':ttl': ttl_timestamp
    }

    if new_status == 'completed' and glue_job_run_id:
        update_expr += ', completed_time = :ct, glue_job_run_id = :jid'
        expr_values[':ct'] = now
        expr_values[':jid'] = glue_job_run_id
    elif new_status == 'failed' and error_message:
        update_expr += ', failed_time = :ft, error_message = :err'
        expr_values[':ft'] = now
        expr_values[':err'] = str(error_message)[:1000]  # Truncate long errors

    table.update_item(
        Key={
            'date_prefix': file_info['date_prefix'],
            'file_key': file_info['file_key']
        },
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values
    )

    logger.debug(f"Updated {file_info['file_key']}: {current_status} → {target_status}")
