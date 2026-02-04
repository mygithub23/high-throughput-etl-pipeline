"""
Analyze collected metrics from DynamoDB
Run this after collecting metrics for at least 24 hours
"""

import boto3
from boto3.dynamodb.conditions import Key
from datetime import datetime, timedelta
from collections import defaultdict
import statistics

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('s3-file-metrics')

def analyze_metrics(hours_to_analyze=24):
    """
    Analyze metrics for the specified number of hours
    """
    
    print(f"\n{'='*80}")
    print(f"S3 FILE METRICS ANALYSIS - Last {hours_to_analyze} Hours")
    print(f"{'='*80}\n")
    
    # Calculate time range
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(hours=hours_to_analyze)
    
    # Generate list of date_hour partitions to query
    current = start_time
    hourly_data = defaultdict(list)
    all_files = []
    
    while current <= end_time:
        date_hour = current.strftime('%Y-%m-%d-%H')
        
        try:
            # Query this hour's partition
            response = table.query(
                KeyConditionExpression=Key('date_hour').eq(date_hour)
            )
            
            items = response.get('Items', [])
            
            for item in items:
                size_gb = float(item['size_gb'])
                timestamp = int(item['timestamp'])
                
                hourly_data[date_hour].append({
                    'size_gb': size_gb,
                    'timestamp': timestamp,
                    'key': item['key']
                })
                all_files.append(size_gb)
            
            # Handle pagination
            while 'LastEvaluatedKey' in response:
                response = table.query(
                    KeyConditionExpression=Key('date_hour').eq(date_hour),
                    ExclusiveStartKey=response['LastEvaluatedKey']
                )
                items = response.get('Items', [])
                for item in items:
                    size_gb = float(item['size_gb'])
                    timestamp = int(item['timestamp'])
                    hourly_data[date_hour].append({
                        'size_gb': size_gb,
                        'timestamp': timestamp,
                        'key': item['key']
                    })
                    all_files.append(size_gb)
        
        except Exception as e:
            print(f"Error querying {date_hour}: {e}")
        
        current += timedelta(hours=1)
    
    if not all_files:
        print("❌ No data collected yet. Run the metrics collector Lambda first.")
        return
    
    # Calculate overall statistics
    total_files = len(all_files)
    total_volume_gb = sum(all_files)
    total_volume_tb = total_volume_gb / 1024
    
    avg_file_size_gb = statistics.mean(all_files)
    median_file_size_gb = statistics.median(all_files)
    min_file_size_gb = min(all_files)
    max_file_size_gb = max(all_files)
    
    if len(all_files) > 1:
        stdev_file_size_gb = statistics.stdev(all_files)
    else:
        stdev_file_size_gb = 0
    
    # Calculate percentiles
    sorted_sizes = sorted(all_files)
    p50 = sorted_sizes[int(len(sorted_sizes) * 0.50)]
    p95 = sorted_sizes[int(len(sorted_sizes) * 0.95)]
    p99 = sorted_sizes[int(len(sorted_sizes) * 0.99)]
    
    # Calculate velocity metrics
    files_per_hour = total_files / hours_to_analyze
    files_per_second = files_per_hour / 3600
    gb_per_hour = total_volume_gb / hours_to_analyze
    tb_per_day = (total_volume_tb / hours_to_analyze) * 24
    
    # Find peak hour
    hourly_counts = {hour: len(files) for hour, files in hourly_data.items()}
    peak_hour = max(hourly_counts.items(), key=lambda x: x[1]) if hourly_counts else (None, 0)
    
    # Print results
    print("📊 OVERALL STATISTICS")
    print(f"   Total Files Processed: {total_files:,}")
    print(f"   Time Period: {hours_to_analyze} hours")
    print(f"   Total Volume: {total_volume_gb:,.2f} GB ({total_volume_tb:,.2f} TB)")
    print()
    
    print("📏 FILE SIZE STATISTICS")
    print(f"   Average File Size: {avg_file_size_gb:.3f} GB ({avg_file_size_gb*1024:.2f} MB)")
    print(f"   Median File Size: {median_file_size_gb:.3f} GB ({median_file_size_gb*1024:.2f} MB)")
    print(f"   Min File Size: {min_file_size_gb:.3f} GB ({min_file_size_gb*1024:.2f} MB)")
    print(f"   Max File Size: {max_file_size_gb:.3f} GB ({max_file_size_gb*1024:.2f} MB)")
    print(f"   Std Deviation: {stdev_file_size_gb:.3f} GB")
    print()
    
    print("📈 PERCENTILES")
    print(f"   P50 (Median): {p50:.3f} GB")
    print(f"   P95: {p95:.3f} GB")
    print(f"   P99: {p99:.3f} GB")
    print()
    
    print("⚡ VELOCITY METRICS")
    print(f"   Files/Hour (Average): {files_per_hour:.2f}")
    print(f"   Files/Second (Average): {files_per_second:.3f}")
    print(f"   GB/Hour: {gb_per_hour:,.2f}")
    print(f"   TB/Day (Projected): {tb_per_day:,.2f}")
    print(f"   TB/Month (Projected): {tb_per_day * 30:,.2f}")
    print()
    
    print("🔥 PEAK METRICS")
    if peak_hour[0]:
        peak_files = peak_hour[1]
        peak_volume = sum(f['size_gb'] for f in hourly_data[peak_hour[0]])
        print(f"   Peak Hour: {peak_hour[0]}")
        print(f"   Peak Files/Hour: {peak_files:,}")
        print(f"   Peak GB/Hour: {peak_volume:,.2f}")
        print(f"   Peak Files/Second: {peak_files/3600:.3f}")
    print()
    
    print("📅 HOURLY BREAKDOWN")
    print(f"   {'Hour':<20} {'Files':<10} {'Volume (GB)':<15} {'Files/Sec':<12}")
    print(f"   {'-'*60}")
    
    for hour in sorted(hourly_data.keys()):
        files = hourly_data[hour]
        count = len(files)
        volume = sum(f['size_gb'] for f in files)
        rate = count / 3600
        print(f"   {hour:<20} {count:<10} {volume:<15.2f} {rate:<12.3f}")
    
    print()
    print(f"{'='*80}\n")
    
    # Return key metrics for programmatic use
    return {
        'total_files': total_files,
        'avg_file_size_gb': avg_file_size_gb,
        'median_file_size_gb': median_file_size_gb,
        'max_file_size_gb': max_file_size_gb,
        'files_per_second': files_per_second,
        'files_per_hour': files_per_hour,
        'tb_per_day': tb_per_day,
        'peak_files_per_hour': peak_hour[1] if peak_hour[0] else 0
    }

if __name__ == '__main__':
    # Analyze last 24 hours by default
    # Change this value to analyze different time periods
    metrics = analyze_metrics(hours_to_analyze=24)
    
    if metrics:
        print("\n💡 KEY FINDINGS:")
        print(f"   Your ACTUAL file size: {metrics['avg_file_size_gb']:.3f} GB (not 3.5 GB assumed)")
        print(f"   Your ACTUAL ingestion rate: {metrics['files_per_hour']:.0f} files/hour")
        print(f"   Your ACTUAL daily volume: {metrics['tb_per_day']:.2f} TB/day")
