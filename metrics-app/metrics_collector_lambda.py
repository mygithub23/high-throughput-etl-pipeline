"""
S3 File Metrics Collector Lambda
Deploys as S3 Event trigger to collect real production metrics
Stores data in DynamoDB for analysis
"""

import json
import boto3
import time
from datetime import datetime
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
s3_client = boto3.client('s3')

# Create this table first: 
# Table name: s3-file-metrics
# Partition key: date_hour (String) - format: YYYY-MM-DD-HH
# Sort key: timestamp (Number)
METRICS_TABLE = 's3-file-metrics'

def lambda_handler(event, context):
    """
    Lightweight metrics collector - NO processing, just metrics
    Triggered by S3 event notification
    """
    
    table = dynamodb.Table(METRICS_TABLE)
    
    for record in event['Records']:
        # Extract S3 event details
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        size_bytes = record['s3']['object']['size']
        event_time = record['eventTime']
        
        # Get additional metadata
        try:
            response = s3_client.head_object(Bucket=bucket, Key=key)
            content_type = response.get('ContentType', 'unknown')
            last_modified = response['LastModified'].isoformat()
        except Exception as e:
            content_type = 'error'
            last_modified = event_time
        
        # Parse timestamp
        dt = datetime.fromisoformat(event_time.replace('Z', '+00:00'))
        date_hour = dt.strftime('%Y-%m-%d-%H')
        timestamp_ms = int(dt.timestamp() * 1000)
        
        # Calculate size in different units
        size_mb = Decimal(str(size_bytes / (1024 * 1024)))
        size_gb = Decimal(str(size_bytes / (1024 * 1024 * 1024)))
        
        # Store metrics
        item = {
            'date_hour': date_hour,
            'timestamp': timestamp_ms,
            'bucket': bucket,
            'key': key,
            'size_bytes': size_bytes,
            'size_mb': size_mb,
            'size_gb': size_gb,
            'content_type': content_type,
            'event_time': event_time,
            'last_modified': last_modified,
            'year': dt.year,
            'month': dt.month,
            'day': dt.day,
            'hour': dt.hour,
            'minute': dt.minute
        }
        
        try:
            table.put_item(Item=item)
            print(f"Recorded: {key} - {size_gb:.2f} GB")
        except Exception as e:
            print(f"Error storing metrics: {e}")
            # Don't fail - this is just metrics collection
    
    return {
        'statusCode': 200,
        'body': json.dumps(f'Processed {len(event["Records"])} file metrics')
    }
