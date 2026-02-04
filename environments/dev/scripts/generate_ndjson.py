"""
Lambda Function: Test NDJSON File Generator
============================================

Generates test NDJSON files (3.5MB each) and uploads to S3 input bucket.
Useful for testing, load testing, and validating the pipeline.

Author: Data Engineering Team
Version: 1.0.0
"""

import json
import os
import boto3
import random
import string
from datetime import datetime, timedelta, timezone
from typing import Dict, List
import io
import uuid

# AWS Clients
s3_client = boto3.client('s3')

# Environment Variables ndjson-input-sqs-<ACCOUNT>
# INPUT_BUCKET = os.environ['INPUT_BUCKET']
# s3://ndjson-input-sqs-<ACCOUNT>-dev/pipeline/input/
INPUT_BUCKET = "ndjson-input-sqs-<ACCOUNT>-dev"
TARGET_FILE_SIZE_MB = float(os.environ.get('TARGET_FILE_SIZE_MB', '0.11'))
# FILES_PER_INVOCATION = int(os.environ.get('FILES_PER_INVOCATION', '100'))

file_count = 10

# FILES_PER_INVOCATION = 4
# DATE_PREFIX = "2025-12-21"

# (expected: 0.10-19.90MB)

# Constants
BYTES_PER_MB = 1024 * 1024
TARGET_FILE_SIZE_BYTES = int(TARGET_FILE_SIZE_MB * BYTES_PER_MB)


class TestDataGenerator:
    """Generates realistic test NDJSON files for pipeline testing."""
    
    def __init__(self, target_size_bytes: int):
        self.target_size_bytes = target_size_bytes
        
        # Sample data templates
        self.user_agents = [
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
            'Mozilla/5.0 (X11; Linux x86_64)',
            'Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X)',
            'Mozilla/5.0 (iPad; CPU OS 14_6 like Mac OS X)'
        ]
        
        self.event_types = [
            'page_view', 'click', 'scroll', 'form_submit', 
            'video_play', 'purchase', 'add_to_cart', 'search'
        ]
        
        self.countries = [
            'US', 'GB', 'CA', 'DE', 'FR', 'JP', 'AU', 'BR', 'IN', 'MX'
        ]
        
        self.cities = {
            'US': ['New York', 'Los Angeles', 'Chicago', 'Houston', 'Phoenix'],
            'GB': ['London', 'Manchester', 'Birmingham', 'Liverpool', 'Leeds'],
            'CA': ['Toronto', 'Montreal', 'Vancouver', 'Calgary', 'Ottawa'],
            'DE': ['Berlin', 'Hamburg', 'Munich', 'Cologne', 'Frankfurt'],
            'FR': ['Paris', 'Marseille', 'Lyon', 'Toulouse', 'Nice']
        }
    
    def generate_ndjson_content(self) -> str:
        """
        Generate NDJSON content to reach target file size.
        
        Returns:
            NDJSON string content
        """
        lines = []
        current_size = 0
        record_count = 0
        
        # Calculate approximate records needed
        # Average record size is ~700 bytes
        estimated_records = self.target_size_bytes // 700
        
        while current_size < self.target_size_bytes:
            record = self._generate_record(record_count)
            line = json.dumps(record) + '\n'
            line_size = len(line.encode('utf-8'))
            
            # Check if adding this record exceeds target by more than 5%
            if current_size + line_size > self.target_size_bytes * 1.05:
                break
            
            lines.append(line)
            current_size += line_size
            record_count += 1
        
        content = ''.join(lines)
        actual_size_mb = len(content.encode('utf-8')) / BYTES_PER_MB
        
        print(f"Generated {record_count} records, size: {actual_size_mb:.2f} MB")
        
        return content
    
    def _generate_record(self, sequence: int) -> Dict:
        """
        Generate a single realistic record.
        
        Args:
            sequence: Record sequence number
            
        Returns:
            Dictionary representing a log record
        """
        timestamp = datetime.now(timezone.utc) - timedelta(seconds=random.randint(0, 3600))
        country = random.choice(self.countries)
        city = random.choice(self.cities.get(country, ['Unknown']))
        
        record = {
            'id': f'evt_{timestamp.strftime("%Y%m%d%H%M%S")}_{sequence:06d}',
            'timestamp': timestamp.isoformat() + 'Z',
            'event_type': random.choice(self.event_types),
            'user_id': f'user_{random.randint(1000, 9999)}',
            'session_id': self._generate_random_string(32),
            'ip_address': f'{random.randint(1,255)}.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(0,255)}',
            'user_agent': random.choice(self.user_agents),
            'country': country,
            'city': city,
            'latitude': round(random.uniform(-90, 90), 6),
            'longitude': round(random.uniform(-180, 180), 6),
            'device_type': random.choice(['desktop', 'mobile', 'tablet']),
            'os': random.choice(['Windows', 'macOS', 'Linux', 'iOS', 'Android']),
            'browser': random.choice(['Chrome', 'Safari', 'Firefox', 'Edge']),
            'page_url': f'https://example.com/{self._generate_random_string(10)}',
            'referrer': f'https://referrer.com/{self._generate_random_string(8)}',
            'utm_source': random.choice(['google', 'facebook', 'email', 'direct', 'twitter']),
            'utm_medium': random.choice(['cpc', 'organic', 'social', 'email']),
            'utm_campaign': f'campaign_{random.randint(1, 100)}',
            'duration_seconds': random.randint(1, 3600),
            'bounce': random.choice([True, False]),
            'conversion': random.choice([True, False, False, False]),  # 25% conversion rate
            'revenue': round(random.uniform(0, 500), 2) if random.random() < 0.25 else 0,
            'items_viewed': random.randint(0, 20),
            'custom_data': {
                'experiment_id': f'exp_{random.randint(1, 50)}',
                'variant': random.choice(['A', 'B', 'control']),
                'feature_flags': {
                    f'feature_{i}': random.choice([True, False])
                    for i in range(random.randint(3, 8))
                }
            },
            # Add padding to reach target record size (~700 bytes)
            'padding': self._generate_random_string(100)
        }
        
        return record
    
    @staticmethod
    def _generate_random_string(length: int) -> str:
        """Generate random alphanumeric string."""
        return ''.join(random.choices(string.ascii_letters + string.digits, k=length))


class TestFileUploader:
    """Handles uploading generated test files to S3."""
    
    def __init__(self, bucket: str, generator: TestDataGenerator):
        self.bucket = bucket
        self.generator = generator
    
    def generate_and_upload_files(
        self,
        count: int,
        date_prefix: str = None,
        ingestion_rate: str = 'immediate',
        delay_seconds: float = None
    ) -> List[Dict]:
        """
        Generate and upload multiple test files with variable ingestion rate.

        Args:
            count: Number of files to generate
            date_prefix: Optional date prefix (yyyy-mm-dd), defaults to today
            ingestion_rate: Rate type - 'immediate', 'slow', 'medium', 'fast', 'random'
            delay_seconds: Custom delay in seconds between uploads (overrides ingestion_rate)

        Returns:
            List of uploaded file information
        """
        import time

        if not date_prefix:
            date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')

        # Define ingestion rate delays (seconds between files)
        rate_delays = {
            'immediate': 0,      # No delay - upload all at once
            'fast': 1,           # 1 second between files (60 files/minute)
            'medium': 5,         # 5 seconds between files (12 files/minute)
            'slow': 10,          # 10 seconds between files (6 files/minute)
            'random': None       # Random delay between 1-10 seconds
        }

        # Use custom delay if provided, otherwise use rate type
        if delay_seconds is not None:
            delay = delay_seconds
        elif ingestion_rate == 'random':
            delay = None  # Will randomize per file
        else:
            delay = rate_delays.get(ingestion_rate, 0)

        uploaded_files = []

        for i in range(count):
            try:
                file_info = self._generate_and_upload_single_file(date_prefix, i)
                uploaded_files.append(file_info)
                print(f"Uploaded file {i+1}/{count}: {file_info['key']}")

                # Apply delay before next upload (except on last file)
                if i < count - 1:
                    if ingestion_rate == 'random':
                        wait_time = random.uniform(1, 10)
                        print(f"  ⏱️  Waiting {wait_time:.1f}s before next file (random rate)...")
                        time.sleep(wait_time)
                    elif delay > 0:
                        print(f"  ⏱️  Waiting {delay}s before next file ({ingestion_rate} rate)...")
                        time.sleep(delay)

            except Exception as e:
                print(f"Error uploading file {i+1}: {str(e)}")
                uploaded_files.append({
                    'status': 'error',
                    'error': str(e),
                    'index': i
                })

        return uploaded_files
    
    def _generate_and_upload_single_file(
        self,
        date_prefix: str,
        sequence: int
    ) -> Dict:
        """
        Generate and upload a single test file.
        
        Args:
            date_prefix: Date prefix (yyyy-mm-dd)
            sequence: File sequence number
            
        Returns:
            File information dictionary
        """

        

        # make a UUID based on the host ID and current time
        print(uuid.uuid1())

        # Generate filename
        timestamp = datetime.now(timezone.utc).strftime('%H%M%S')
        filename = f"{date_prefix}-test{sequence:04d}-{timestamp}-{uuid.uuid1()}.ndjson"
        # pipeline/input/
        key = f"pipeline/input/{filename}"
        
        # Generate content
        content = self.generator.generate_ndjson_content()
        record_count = content.count('\n')
        content_bytes = content.encode('utf-8')
        file_size_bytes = len(content_bytes)
        file_size_mb = file_size_bytes / BYTES_PER_MB

        # Upload to S3
        s3_client.put_object(
            Bucket=self.bucket,
            Key=key,
            Body=content_bytes,
            ContentType='application/x-ndjson',
            Metadata={
                'generator': 'test-data-lambda',
                'date_prefix': date_prefix,
                'record_count': str(record_count),
                'file_size_mb': f'{file_size_mb:.2f}'
            }
        )
        
        return {
            'status': 'success',
            'bucket': self.bucket,
            'key': key,
            'size_bytes': file_size_bytes,
            'size_mb': round(file_size_mb, 2),
            's3_uri': f's3://{self.bucket}/{key}'
        }


def lambda_handler(event, context):
    """
    AWS Lambda handler function.

    Event parameters (all optional):
    - file_count: Number of files to generate (default: 7)
    - date_prefix: Date prefix for files in YYYY-MM-DD format (default: today's UTC date)
    - target_size_mb: Target file size in MB (default: 0.11 MB)
    - ingestion_rate: Upload rate - 'immediate', 'fast', 'medium', 'slow', 'random' (default: 'immediate')
    - delay_seconds: Custom delay in seconds between uploads (overrides ingestion_rate)

    Examples:

    1. Generate 7 files immediately with today's UTC date:
       {}

    2. Generate 20 files with fast ingestion (1s between files):
       {"file_count": 20, "ingestion_rate": "fast"}

    3. Generate files for specific date with medium rate (5s between files):
       {"file_count": 10, "date_prefix": "2026-01-30", "ingestion_rate": "medium"}

    4. Generate files with custom delay:
       {"file_count": 15, "delay_seconds": 3.5}

    5. Generate files with random delays (1-10s):
       {"file_count": 10, "ingestion_rate": "random"}
    """
    try:
        # Parse event parameters with dynamic UTC date default
        files_to_generate = event.get('file_count', 7)
        date_prefix = event.get('date_prefix')  # None = will use UTC today in uploader
        target_size_mb = event.get('target_size_mb', TARGET_FILE_SIZE_MB)
        ingestion_rate = event.get('ingestion_rate', 'immediate')
        delay_seconds = event.get('delay_seconds')

        # Use UTC today if no date_prefix provided
        if not date_prefix:
            date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')

        print(f"Starting test file generation:")
        print(f"  - Files: {files_to_generate}")
        print(f"  - Target size: {target_size_mb} MB")
        print(f"  - Date prefix: {date_prefix} (UTC)")
        print(f"  - Bucket: {INPUT_BUCKET}")
        print(f"  - Ingestion rate: {ingestion_rate}")
        if delay_seconds:
            print(f"  - Custom delay: {delay_seconds}s")

        # Initialize generator and uploader
        target_size_bytes = int(target_size_mb * BYTES_PER_MB)
        generator = TestDataGenerator(target_size_bytes)
        uploader = TestFileUploader(INPUT_BUCKET, generator)

        # Generate and upload files with variable rate
        uploaded_files = uploader.generate_and_upload_files(
            count=files_to_generate,
            date_prefix=date_prefix,
            ingestion_rate=ingestion_rate,
            delay_seconds=delay_seconds
        )

        # Calculate statistics
        successful = [f for f in uploaded_files if f.get('status') == 'success']
        failed = [f for f in uploaded_files if f.get('status') == 'error']

        total_size_mb = sum(f.get('size_mb', 0) for f in successful)
        avg_size_mb = total_size_mb / len(successful) if successful else 0

        result = {
            'status': 'completed',
            'total_files': files_to_generate,
            'successful': len(successful),
            'failed': len(failed),
            'total_size_mb': round(total_size_mb, 2),
            'average_size_mb': round(avg_size_mb, 2),
            'bucket': INPUT_BUCKET,
            'date_prefix': date_prefix,
            'ingestion_rate': ingestion_rate,
            'files': successful[:10]  # Return first 10 for reference
        }

        if failed:
            result['errors'] = failed

        print(f"\n✓ Generation complete: {len(successful)}/{files_to_generate} files uploaded")
        print(f"Total size: {total_size_mb:.2f} MB, Avg: {avg_size_mb:.2f} MB")

        return {
            'statusCode': 200,
            'body': json.dumps(result, indent=2)
        }

    except Exception as e:
        print(f"Error in lambda_handler: {str(e)}")
        import traceback
        traceback.print_exc()

        return {
            'statusCode': 500,
            'body': json.dumps({
                'status': 'error',
                'error': str(e)
            })
        }


# For local testing
if __name__ == '__main__':
    # Test locally with dynamic UTC date and variable ingestion rate
    os.environ['INPUT_BUCKET'] = 'test-bucket'
    os.environ['TARGET_FILE_SIZE_MB'] = '0.11'

    # Example 1: Immediate upload (all files at once)
    test_event_immediate = {
        'file_count': 5,
        'ingestion_rate': 'immediate'
    }

    # Example 2: Fast ingestion (1s between files)
    test_event_fast = {
        'file_count': 5,
        'ingestion_rate': 'fast'
    }

    # Example 3: Random ingestion (1-10s between files)
    test_event_random = {
        'file_count': 5,
        'ingestion_rate': 'random'
    }

    # Run test (choose one)
    result = lambda_handler(test_event_immediate, None)
    print(json.dumps(json.loads(result['body']), indent=2))
