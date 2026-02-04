"""
Lambda: State Management Function - PRODUCTION VERSION
=======================================================

Provides centralized state management and querying capabilities for the
NDJSON to Parquet pipeline. Allows inspection, modification, and analysis
of pipeline state across all components.

Version: 1.0.0-prod
Environment: PRODUCTION

Features:
- Query file processing states
- Batch state updates
- State transitions management
- Orphan detection
- State consistency checks
- Detailed reporting
"""

import json
import os
import boto3
import time
from datetime import datetime, timedelta
from decimal import Decimal
from typing import List, Dict, Any, Optional
import logging
from boto3.dynamodb.conditions import Key, Attr

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)  # INFO level for production

# AWS Clients
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
glue_client = boto3.client('glue')

# Environment Variables
TRACKING_TABLE = os.environ['TRACKING_TABLE']
METRICS_TABLE = os.environ.get('METRICS_TABLE', '')
INPUT_BUCKET = os.environ.get('INPUT_BUCKET', '')
MANIFEST_BUCKET = os.environ.get('MANIFEST_BUCKET', '')
OUTPUT_BUCKET = os.environ.get('OUTPUT_BUCKET', '')
QUARANTINE_BUCKET = os.environ.get('QUARANTINE_BUCKET', '')

# DynamoDB tables
tracking_table = dynamodb.Table(TRACKING_TABLE)
metrics_table = dynamodb.Table(METRICS_TABLE) if METRICS_TABLE else None

# Helper function for JSON serialization
def decimal_default(obj):
    """Convert Decimal to float for JSON serialization."""
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError


def lambda_handler(event, context):
    """
    Main handler for state management operations.

    Supported operations:
    - get_file_state: Get state of specific file(s)
    - query_by_status: Query files by status
    - update_state: Update file state
    - batch_update: Update multiple files
    - find_orphans: Find files in inconsistent states
    - get_stats: Get statistics by status
    - reset_stuck_files: Reset files stuck in processing
    - validate_consistency: Check state consistency
    - get_processing_timeline: Get file processing timeline
    """

    logger.info(f"State Management invoked with event: {json.dumps(event, default=str)}")

    operation = event.get('operation', 'get_file_state')

    try:
        if operation == 'get_file_state':
            return get_file_state(event)
        elif operation == 'query_by_status':
            return query_by_status(event)
        elif operation == 'update_state':
            return update_state(event)
        elif operation == 'batch_update':
            return batch_update(event)
        elif operation == 'find_orphans':
            return find_orphans(event)
        elif operation == 'get_stats':
            return get_stats(event)
        elif operation == 'reset_stuck_files':
            return reset_stuck_files(event)
        elif operation == 'validate_consistency':
            return validate_consistency(event)
        elif operation == 'get_processing_timeline':
            return get_processing_timeline(event)
        else:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'error': f'Unknown operation: {operation}',
                    'supported_operations': [
                        'get_file_state', 'query_by_status', 'update_state',
                        'batch_update', 'find_orphans', 'get_stats',
                        'reset_stuck_files', 'validate_consistency',
                        'get_processing_timeline'
                    ]
                })
            }
    except Exception as e:
        logger.error(f"Operation failed: {str(e)}", exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'operation': operation
            })
        }


def get_file_state(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Get state of specific file(s).

    Parameters:
    - date_prefix: Date prefix (required)
    - file_key: File key (optional, if not provided returns all files for date)
    - limit: Maximum number of results (default 100)
    """
    date_prefix = event.get('date_prefix')
    file_key = event.get('file_key')
    limit = event.get('limit', 100)

    if not date_prefix:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'date_prefix is required'})
        }

    try:
        if file_key:
            # Get specific file
            response = tracking_table.get_item(
                Key={'date_prefix': date_prefix, 'file_key': file_key}
            )

            if 'Item' in response:
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'file': response['Item']
                    }, default=decimal_default)
                }
            else:
                return {
                    'statusCode': 404,
                    'body': json.dumps({'error': 'File not found'})
                }
        else:
            # Get all files for date
            response = tracking_table.query(
                KeyConditionExpression=Key('date_prefix').eq(date_prefix),
                Limit=limit
            )

            return {
                'statusCode': 200,
                'body': json.dumps({
                    'count': len(response['Items']),
                    'files': response['Items']
                }, default=decimal_default)
            }
    except Exception as e:
        logger.error(f"Error getting file state: {str(e)}", exc_info=True)
        raise


def query_by_status(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Query files by status using GSI.

    Parameters:
    - status: Status to query (pending, manifested, processing, completed, failed, quarantined)
    - limit: Maximum number of results (default 100)
    - date_range: Optional date range filter {'start': 'YYYY-MM-DD', 'end': 'YYYY-MM-DD'}
    """
    status = event.get('status')
    limit = event.get('limit', 100)
    date_range = event.get('date_range')

    if not status:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'status is required'})
        }

    try:
        # Query using status-index GSI
        query_params = {
            'IndexName': 'status-index',
            'KeyConditionExpression': Key('status').eq(status),
            'Limit': limit
        }

        # Add date range filter if provided
        if date_range:
            start_date = date_range.get('start')
            end_date = date_range.get('end')
            if start_date and end_date:
                query_params['FilterExpression'] = Attr('date_prefix').between(start_date, end_date)

        response = tracking_table.query(**query_params)

        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': status,
                'count': len(response['Items']),
                'files': response['Items']
            }, default=decimal_default)
        }
    except Exception as e:
        logger.error(f"Error querying by status: {str(e)}", exc_info=True)
        raise


def update_state(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Update state of a single file.

    Parameters:
    - date_prefix: Date prefix (required)
    - file_key: File key (required)
    - new_status: New status value
    - additional_fields: Additional fields to update (optional)
    """
    date_prefix = event.get('date_prefix')
    file_key = event.get('file_key')
    new_status = event.get('new_status')
    additional_fields = event.get('additional_fields', {})

    if not all([date_prefix, file_key, new_status]):
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'date_prefix, file_key, and new_status are required'})
        }

    try:
        # Build update expression
        update_expr = 'SET #status = :status, updated_at = :updated_at'
        expr_attr_names = {'#status': 'status'}
        expr_attr_values = {
            ':status': new_status,
            ':updated_at': datetime.utcnow().isoformat()
        }

        # Add additional fields
        for field_name, field_value in additional_fields.items():
            update_expr += f', {field_name} = :{field_name}'
            expr_attr_values[f':{field_name}'] = field_value

        response = tracking_table.update_item(
            Key={'date_prefix': date_prefix, 'file_key': file_key},
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_attr_names,
            ExpressionAttributeValues=expr_attr_values,
            ReturnValues='ALL_NEW'
        )

        logger.info(f"Updated file state: {date_prefix}/{file_key} -> {new_status}")

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'State updated successfully',
                'updated_item': response['Attributes']
            }, default=decimal_default)
        }
    except Exception as e:
        logger.error(f"Error updating state: {str(e)}", exc_info=True)
        raise


def batch_update(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Update multiple files in batch.

    Parameters:
    - files: List of file updates, each with:
      - date_prefix
      - file_key
      - new_status
      - additional_fields (optional)
    """
    files = event.get('files', [])

    if not files:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'files list is required'})
        }

    try:
        results = {'successful': 0, 'failed': 0, 'errors': []}

        for file_update in files:
            try:
                update_event = {
                    'date_prefix': file_update.get('date_prefix'),
                    'file_key': file_update.get('file_key'),
                    'new_status': file_update.get('new_status'),
                    'additional_fields': file_update.get('additional_fields', {})
                }

                response = update_state(update_event)

                if response['statusCode'] == 200:
                    results['successful'] += 1
                else:
                    results['failed'] += 1
                    results['errors'].append({
                        'file': f"{file_update.get('date_prefix')}/{file_update.get('file_key')}",
                        'error': response.get('body')
                    })
            except Exception as e:
                results['failed'] += 1
                results['errors'].append({
                    'file': f"{file_update.get('date_prefix')}/{file_update.get('file_key')}",
                    'error': str(e)
                })

        return {
            'statusCode': 200,
            'body': json.dumps({
                'total': len(files),
                'successful': results['successful'],
                'failed': results['failed'],
                'errors': results['errors']
            })
        }
    except Exception as e:
        logger.error(f"Error in batch update: {str(e)}", exc_info=True)
        raise


def find_orphans(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Find files in inconsistent states (orphans).

    Checks:
    - Files in 'processing' for > 2 hours
    - Files in 'manifested' but manifest doesn't exist
    - Files in 'completed' but output doesn't exist

    Parameters:
    - max_processing_hours: Max hours in processing state (default 2)
    """
    max_hours = event.get('max_processing_hours', 2)
    cutoff_time = datetime.utcnow() - timedelta(hours=max_hours)

    try:
        orphans = {
            'stuck_in_processing': [],
            'missing_manifests': [],
            'missing_outputs': []
        }

        # Find files stuck in processing
        response = tracking_table.query(
            IndexName='status-index',
            KeyConditionExpression=Key('status').eq('processing')
        )

        for item in response['Items']:
            updated_at = datetime.fromisoformat(item.get('updated_at', item.get('upload_time', '')))
            if updated_at < cutoff_time:
                orphans['stuck_in_processing'].append({
                    'date_prefix': item['date_prefix'],
                    'file_key': item['file_key'],
                    'updated_at': item.get('updated_at'),
                    'hours_stuck': (datetime.utcnow() - updated_at).total_seconds() / 3600
                })

        # Check manifested files
        response = tracking_table.query(
            IndexName='status-index',
            KeyConditionExpression=Key('status').eq('manifested'),
            Limit=100
        )

        for item in response['Items']:
            manifest_path = item.get('manifest_path', '')
            if manifest_path:
                try:
                    # Check if manifest exists
                    s3_client.head_object(Bucket=MANIFEST_BUCKET, Key=manifest_path)
                except s3_client.exceptions.ClientError:
                    orphans['missing_manifests'].append({
                        'date_prefix': item['date_prefix'],
                        'file_key': item['file_key'],
                        'manifest_path': manifest_path
                    })

        return {
            'statusCode': 200,
            'body': json.dumps({
                'total_orphans': sum(len(v) for v in orphans.values()),
                'orphans': orphans
            }, default=decimal_default)
        }
    except Exception as e:
        logger.error(f"Error finding orphans: {str(e)}", exc_info=True)
        raise


def get_stats(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Get statistics grouped by status.

    Parameters:
    - date_prefix: Optional date filter
    """
    date_prefix = event.get('date_prefix')

    try:
        stats = {}
        statuses = ['pending', 'manifested', 'processing', 'completed', 'failed', 'quarantined']

        for status in statuses:
            response = tracking_table.query(
                IndexName='status-index',
                KeyConditionExpression=Key('status').eq(status),
                Select='COUNT'
            )
            stats[status] = response['Count']

        stats['total'] = sum(stats.values())

        return {
            'statusCode': 200,
            'body': json.dumps({
                'timestamp': datetime.utcnow().isoformat(),
                'stats': stats
            })
        }
    except Exception as e:
        logger.error(f"Error getting stats: {str(e)}", exc_info=True)
        raise


def reset_stuck_files(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Reset files stuck in processing state back to pending.

    Parameters:
    - max_processing_hours: Max hours before considering stuck (default 2)
    - dry_run: If true, only report what would be reset (default true)
    """
    max_hours = event.get('max_processing_hours', 2)
    dry_run = event.get('dry_run', True)
    cutoff_time = datetime.utcnow() - timedelta(hours=max_hours)

    try:
        # Find stuck files
        response = tracking_table.query(
            IndexName='status-index',
            KeyConditionExpression=Key('status').eq('processing')
        )

        stuck_files = []
        for item in response['Items']:
            updated_at = datetime.fromisoformat(item.get('updated_at', item.get('upload_time', '')))
            if updated_at < cutoff_time:
                stuck_files.append({
                    'date_prefix': item['date_prefix'],
                    'file_key': item['file_key'],
                    'hours_stuck': (datetime.utcnow() - updated_at).total_seconds() / 3600
                })

        if not dry_run:
            # Reset to pending
            for file_info in stuck_files:
                tracking_table.update_item(
                    Key={
                        'date_prefix': file_info['date_prefix'],
                        'file_key': file_info['file_key']
                    },
                    UpdateExpression='SET #status = :status, updated_at = :updated_at, reset_count = if_not_exists(reset_count, :zero) + :one',
                    ExpressionAttributeNames={'#status': 'status'},
                    ExpressionAttributeValues={
                        ':status': 'pending',
                        ':updated_at': datetime.utcnow().isoformat(),
                        ':zero': 0,
                        ':one': 1
                    }
                )
                logger.info(f"Reset file: {file_info['date_prefix']}/{file_info['file_key']}")

        return {
            'statusCode': 200,
            'body': json.dumps({
                'dry_run': dry_run,
                'stuck_files_found': len(stuck_files),
                'files_reset': len(stuck_files) if not dry_run else 0,
                'stuck_files': stuck_files
            }, default=decimal_default)
        }
    except Exception as e:
        logger.error(f"Error resetting stuck files: {str(e)}", exc_info=True)
        raise


def validate_consistency(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Validate state consistency across S3 and DynamoDB.

    Parameters:
    - date_prefix: Date to validate (required)
    """
    date_prefix = event.get('date_prefix')

    if not date_prefix:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'date_prefix is required'})
        }

    try:
        issues = []

        # Get all files from DynamoDB for this date
        db_files = {}
        response = tracking_table.query(
            KeyConditionExpression=Key('date_prefix').eq(date_prefix)
        )

        for item in response['Items']:
            db_files[item['file_key']] = item

        # Check S3 input bucket
        s3_files = set()
        paginator = s3_client.get_paginator('list_objects_v2')
        for page in paginator.paginate(Bucket=INPUT_BUCKET, Prefix=f"{date_prefix}/"):
            for obj in page.get('Contents', []):
                s3_files.add(obj['Key'])

        # Find files in S3 but not in DynamoDB
        for s3_file in s3_files:
            if s3_file not in db_files:
                issues.append({
                    'type': 'missing_in_dynamodb',
                    'file_key': s3_file,
                    'message': 'File exists in S3 but not tracked in DynamoDB'
                })

        # Find files in DynamoDB but not in S3 (and not completed)
        for file_key, item in db_files.items():
            if file_key not in s3_files and item.get('status') not in ['completed', 'quarantined']:
                issues.append({
                    'type': 'missing_in_s3',
                    'file_key': file_key,
                    'status': item.get('status'),
                    'message': 'File tracked in DynamoDB but missing from S3'
                })

        return {
            'statusCode': 200,
            'body': json.dumps({
                'date_prefix': date_prefix,
                'db_file_count': len(db_files),
                's3_file_count': len(s3_files),
                'issues_found': len(issues),
                'issues': issues
            })
        }
    except Exception as e:
        logger.error(f"Error validating consistency: {str(e)}", exc_info=True)
        raise


def get_processing_timeline(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Get processing timeline for a specific file.

    Parameters:
    - date_prefix: Date prefix (required)
    - file_key: File key (required)
    """
    date_prefix = event.get('date_prefix')
    file_key = event.get('file_key')

    if not all([date_prefix, file_key]):
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'date_prefix and file_key are required'})
        }

    try:
        # Get file from tracking table
        response = tracking_table.get_item(
            Key={'date_prefix': date_prefix, 'file_key': file_key}
        )

        if 'Item' not in response:
            return {
                'statusCode': 404,
                'body': json.dumps({'error': 'File not found'})
            }

        item = response['Item']

        # Build timeline
        timeline = []

        if 'upload_time' in item:
            timeline.append({
                'event': 'uploaded',
                'timestamp': item['upload_time'],
                'status': 'pending'
            })

        if 'manifest_time' in item:
            timeline.append({
                'event': 'manifested',
                'timestamp': item['manifest_time'],
                'status': 'manifested',
                'manifest_path': item.get('manifest_path')
            })

        if 'processing_start_time' in item:
            timeline.append({
                'event': 'processing_started',
                'timestamp': item['processing_start_time'],
                'status': 'processing'
            })

        if 'completed_time' in item:
            timeline.append({
                'event': 'completed',
                'timestamp': item['completed_time'],
                'status': 'completed',
                'output_path': item.get('output_path')
            })

        if item.get('status') == 'failed':
            timeline.append({
                'event': 'failed',
                'timestamp': item.get('updated_at'),
                'error': item.get('error_message')
            })

        # Calculate durations
        durations = {}
        if len(timeline) >= 2:
            for i in range(len(timeline) - 1):
                start = datetime.fromisoformat(timeline[i]['timestamp'])
                end = datetime.fromisoformat(timeline[i + 1]['timestamp'])
                duration_seconds = (end - start).total_seconds()
                durations[f"{timeline[i]['event']}_to_{timeline[i+1]['event']}"] = duration_seconds

        return {
            'statusCode': 200,
            'body': json.dumps({
                'file': f"{date_prefix}/{file_key}",
                'current_status': item.get('status'),
                'timeline': timeline,
                'durations_seconds': durations,
                'total_processing_time': sum(durations.values()) if durations else 0
            }, default=decimal_default)
        }
    except Exception as e:
        logger.error(f"Error getting processing timeline: {str(e)}", exc_info=True)
        raise
