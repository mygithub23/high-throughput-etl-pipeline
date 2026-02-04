"""
Create DynamoDB table for metrics collection
Run this once to set up the metrics table
"""

import boto3

dynamodb = boto3.client('dynamodb')

def create_metrics_table():
    """
    Creates the metrics table with proper indexes for querying
    """
    
    try:
        response = dynamodb.create_table(
            TableName='s3-file-metrics',
            KeySchema=[
                {
                    'AttributeName': 'date_hour',
                    'KeyType': 'HASH'  # Partition key
                },
                {
                    'AttributeName': 'timestamp',
                    'KeyType': 'RANGE'  # Sort key
                }
            ],
            AttributeDefinitions=[
                {
                    'AttributeName': 'date_hour',
                    'AttributeType': 'S'  # String: YYYY-MM-DD-HH
                },
                {
                    'AttributeName': 'timestamp',
                    'AttributeType': 'N'  # Number: milliseconds since epoch
                }
            ],
            BillingMode='PAY_PER_REQUEST',  # On-demand pricing
            Tags=[
                {
                    'Key': 'Purpose',
                    'Value': 'S3FileMetrics'
                }
            ]
        )
        
        print("Table created successfully!")
        print(f"Table ARN: {response['TableDescription']['TableArn']}")
        print("Waiting for table to become active...")
        
        # Wait for table to be active
        waiter = dynamodb.get_waiter('table_exists')
        waiter.wait(TableName='s3-file-metrics')
        
        print("Table is now active and ready to use!")
        
    except dynamodb.exceptions.ResourceInUseException:
        print("Table already exists!")
    except Exception as e:
        print(f"Error creating table: {e}")

if __name__ == '__main__':
    create_metrics_table()
