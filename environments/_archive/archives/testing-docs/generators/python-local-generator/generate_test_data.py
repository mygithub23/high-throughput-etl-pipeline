#!/usr/bin/env python3
"""
Generate sample NDJSON test data for the pipeline.

This script creates realistic test NDJSON files that can be used to
validate the data processing pipeline.

Usage:
    python generate_test_data.py --records 10000 --output test-data.ndjson
    python generate_test_data.py --records 10000 --output test-data.ndjson
    python generate_test_data.py --records 100 --output test-data.ndjson
"""

import json
import random
import argparse
from datetime import datetime, timedelta, timezone
from typing import Dict, Any


def generate_record() -> Dict[str, Any]:
    """
    Generate a single test NDJSON record.
    
    Returns:
        Dictionary representing one record
    """
    record_id = f"rec_{random.randint(100000, 999999)}"
    
    # Generate random timestamp within last 24 hours
    timestamp = (
        datetime.now(timezone.utc) - timedelta(hours=random.randint(0, 24))
    ).isoformat()
    
    # Sample event types
    event_types = ['purchase', 'view', 'click', 'search', 'add_to_cart']
    
    # Sample categories
    categories = ['electronics', 'clothing', 'books', 'home', 'sports']
    
    # Generate record with various data types
    record = {
        'id': record_id,
        'timestamp': timestamp,
        'event_type': random.choice(event_types),
        'user_id': f"user_{random.randint(1000, 9999)}",
        'session_id': f"sess_{random.randint(100000, 999999)}",
        'category': random.choice(categories),
        'product_id': f"prod_{random.randint(1000, 9999)}",
        'price': round(random.uniform(9.99, 999.99), 2),
        'quantity': random.randint(1, 5),
        'device': random.choice(['mobile', 'desktop', 'tablet']),
        'country': random.choice(['US', 'UK', 'CA', 'DE', 'FR', 'JP']),
        'metadata': {
            'source': random.choice(['web', 'mobile_app', 'api']),
            'version': f"{random.randint(1, 3)}.{random.randint(0, 9)}.{random.randint(0, 9)}",
            'experiment_id': f"exp_{random.randint(100, 999)}"
        }
    }
    
    return record


def generate_ndjson_file(
    output_file: str,
    num_records: int,
    date_prefix: str = None
) -> None:
    """
    Generate NDJSON file with specified number of records.
    
    Args:
        output_file: Output file path
        num_records: Number of records to generate
        date_prefix: Optional date prefix for filename (yyyy-mm-dd)
    """
    if date_prefix is None:
        date_prefix = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    
    # Add date prefix to filename if not present
    if not output_file.startswith(date_prefix):
        filename_parts = output_file.rsplit('/', 1)
        if len(filename_parts) == 2:
            output_file = f"{filename_parts[0]}/{date_prefix}-{filename_parts[1]}"
        else:
            output_file = f"{date_prefix}-{output_file}"
    
    print(f"Generating {num_records:,} records...")
    print(f"Output file: {output_file}")
    
    with open(output_file, 'w') as f:
        for i in range(num_records):
            record = generate_record()
            f.write(json.dumps(record) + '\n')
            
            # Progress indicator
            if (i + 1) % 10000 == 0:
                print(f"  Generated {i + 1:,} records...")
    
    print(f"✓ Complete! Generated {num_records:,} records")
    
    # Print file size
    import os
    file_size_mb = os.path.getsize(output_file) / (1024 * 1024)
    print(f"  File size: {file_size_mb:.2f} MB")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Generate sample NDJSON test data'
    )
    parser.add_argument(
        '--records',
        type=int,
        default=10000,
        help='Number of records to generate (default: 10000)'
    )
    parser.add_argument(
        '--output',
        type=str,
        default='test-data.ndjson',
        help='Output file path (default: test-data.ndjson)'
    )
    parser.add_argument(
        '--date',
        type=str,
        default=None,
        help='Date prefix for filename (default: today, format: yyyy-mm-dd)'
    )
    parser.add_argument(
        '--multiple',
        type=int,
        default=1,
        help='Generate multiple files (default: 1)'
    )
    
    args = parser.parse_args()
    
    if args.multiple > 1:
        print(f"Generating {args.multiple} files with {args.records:,} records each...")
        for i in range(args.multiple):
            output_file = args.output.replace('.ndjson', f'-{i+1:03d}.ndjson')
            generate_ndjson_file(output_file, args.records, args.date)
            print()
    else:
        generate_ndjson_file(args.output, args.records, args.date)


if __name__ == '__main__':
    main()
