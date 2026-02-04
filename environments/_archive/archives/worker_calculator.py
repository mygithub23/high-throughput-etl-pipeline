#!/usr/bin/env python3
"""
AWS Glue Worker Performance Calculator

Calculates processing time and cost for NDJSON to Parquet conversion
based on worker type, data size, and number of workers.

Usage:
    python worker_calculator.py

    Or import in your code:
    from worker_calculator import calculate_processing_time
"""

import json
from typing import Dict, Optional


def calculate_processing_time(
    data_size_gb: float,
    worker_type: str,
    num_workers: int = 1,
    avg_record_size_bytes: int = 200,
    compression_ratio: float = 6.0
) -> Dict:
    """
    Calculate processing time for NDJSON to Parquet conversion.

    Args:
        data_size_gb: Input data size in GB
        worker_type: 'G.1X', 'G.2X', 'G.4X', or 'G.8X'
        num_workers: Number of workers (default: 1 for single worker calculation)
        avg_record_size_bytes: Average size of each JSON record (default: 200)
        compression_ratio: Parquet compression ratio (default: 6.0)

    Returns:
        Dictionary with detailed time breakdown and cost

    Example:
        >>> result = calculate_processing_time(10, 'G.2X', num_workers=1)
        >>> print(f"Time: {result['parallel_execution']['total_min']} minutes")
        Time: 8.4 minutes
    """

    # Worker specifications
    specs = {
        'G.1X': {
            'read_speed_mbs': 100,
            'parse_speed_rps': 100_000,
            'process_speed_rps': 250_000,
            'write_speed_mbs': 350,
            'cost_per_hour': 0.44,
            'vcpu': 4,
            'ram_gb': 16,
            'dpu': 1
        },
        'G.2X': {
            'read_speed_mbs': 175,
            'parse_speed_rps': 175_000,
            'process_speed_rps': 500_000,
            'write_speed_mbs': 625,
            'cost_per_hour': 0.88,
            'vcpu': 8,
            'ram_gb': 32,
            'dpu': 2
        },
        'G.4X': {
            'read_speed_mbs': 350,
            'parse_speed_rps': 350_000,
            'process_speed_rps': 1_000_000,
            'write_speed_mbs': 1_250,
            'cost_per_hour': 1.76,
            'vcpu': 16,
            'ram_gb': 64,
            'dpu': 4
        },
        'G.8X': {
            'read_speed_mbs': 600,
            'parse_speed_rps': 600_000,
            'process_speed_rps': 1_750_000,
            'write_speed_mbs': 2_500,
            'cost_per_hour': 3.52,
            'vcpu': 32,
            'ram_gb': 128,
            'dpu': 8
        }
    }

    if worker_type not in specs:
        raise ValueError(f"Invalid worker type. Choose from: {list(specs.keys())}")

    spec = specs[worker_type]

    # Calculate record count
    data_size_bytes = data_size_gb * (1024 ** 3)
    record_count = int(data_size_bytes / avg_record_size_bytes)

    # Calculate each phase (single worker)
    data_size_mb = data_size_gb * 1024

    read_time_sec = data_size_mb / spec['read_speed_mbs']
    parse_time_sec = record_count / spec['parse_speed_rps']
    process_time_sec = record_count / spec['process_speed_rps']

    # Parquet compression
    compressed_size_mb = data_size_mb / compression_ratio
    write_time_sec = compressed_size_mb / spec['write_speed_mbs']

    # Overhead varies by data size
    if data_size_gb < 1:
        overhead_sec = 30
    elif data_size_gb < 10:
        overhead_sec = 45
    elif data_size_gb < 100:
        overhead_sec = 60
    else:
        overhead_sec = 90

    # Single worker total
    single_worker_total_sec = (
        read_time_sec + parse_time_sec +
        process_time_sec + write_time_sec + overhead_sec
    )

    # Multi-worker calculation
    if num_workers > 1:
        # Efficiency factor (0.75 = 75% efficiency due to coordination overhead)
        efficiency = 0.75
        parallel_total_sec = single_worker_total_sec / (num_workers * efficiency)
    else:
        parallel_total_sec = single_worker_total_sec

    # Calculate cost
    total_hours = parallel_total_sec / 3600
    cost_per_worker = spec['cost_per_hour'] * total_hours
    total_cost = cost_per_worker * num_workers

    # DPU-hours calculation
    dpu_hours = spec['dpu'] * num_workers * total_hours

    return {
        'input_size_gb': round(data_size_gb, 2),
        'output_size_gb': round(data_size_gb / compression_ratio, 2),
        'records': f"{record_count:,}",
        'worker_config': {
            'type': worker_type,
            'vcpu': spec['vcpu'],
            'ram_gb': spec['ram_gb'],
            'dpu': spec['dpu'],
            'num_workers': num_workers,
            'total_dpu': spec['dpu'] * num_workers
        },
        'single_worker_breakdown': {
            'read_sec': round(read_time_sec, 1),
            'parse_sec': round(parse_time_sec, 1),
            'process_sec': round(process_time_sec, 1),
            'write_sec': round(write_time_sec, 1),
            'overhead_sec': overhead_sec,
            'total_sec': round(single_worker_total_sec, 1),
            'total_min': round(single_worker_total_sec / 60, 1),
            'total_hours': round(single_worker_total_sec / 3600, 2)
        },
        'parallel_execution': {
            'efficiency_factor': 0.75 if num_workers > 1 else 1.0,
            'total_sec': round(parallel_total_sec, 1),
            'total_min': round(parallel_total_sec / 60, 1),
            'total_hours': round(parallel_total_sec / 3600, 2)
        },
        'cost': {
            'cost_per_worker_usd': round(cost_per_worker, 4),
            'total_cost_usd': round(total_cost, 2),
            'cost_per_gb_usd': round(total_cost / data_size_gb, 4),
            'dpu_hours': round(dpu_hours, 2)
        }
    }


def calculate_daily_cost(
    daily_files: int,
    avg_file_size_gb: float,
    files_per_manifest: int,
    worker_type: str,
    workers_per_job: int,
    concurrent_jobs: int
) -> Dict:
    """
    Calculate daily processing time and cost for production workload.

    Args:
        daily_files: Number of files per day (e.g., 338,000)
        avg_file_size_gb: Average file size in GB (e.g., 4.0)
        files_per_manifest: Files per manifest (e.g., 100)
        worker_type: Worker type (e.g., 'G.2X')
        workers_per_job: Workers per Glue job (e.g., 20)
        concurrent_jobs: Max concurrent Glue jobs (e.g., 30)

    Returns:
        Dictionary with daily metrics and costs
    """

    # Calculate number of manifests
    num_manifests = int(daily_files / files_per_manifest)

    # Calculate data per manifest
    data_per_manifest_gb = files_per_manifest * avg_file_size_gb

    # Get time for one manifest
    manifest_result = calculate_processing_time(
        data_per_manifest_gb,
        worker_type,
        workers_per_job
    )

    time_per_manifest_min = manifest_result['parallel_execution']['total_min']

    # Calculate batches (how many rounds of concurrent jobs)
    num_batches = int((num_manifests + concurrent_jobs - 1) / concurrent_jobs)

    # Total processing time
    total_time_min = num_batches * time_per_manifest_min
    total_time_hours = total_time_min / 60

    # Calculate cost
    cost_per_manifest = manifest_result['cost']['total_cost_usd']
    daily_cost = cost_per_manifest * num_manifests
    monthly_cost = daily_cost * 30

    # DPU calculations
    dpu_per_manifest = manifest_result['cost']['dpu_hours']
    daily_dpu_hours = dpu_per_manifest * num_manifests

    return {
        'daily_files': daily_files,
        'avg_file_size_gb': avg_file_size_gb,
        'total_daily_data_tb': round(daily_files * avg_file_size_gb / 1024, 2),
        'manifests': {
            'files_per_manifest': files_per_manifest,
            'total_manifests': num_manifests,
            'data_per_manifest_gb': round(data_per_manifest_gb, 1)
        },
        'processing': {
            'worker_type': worker_type,
            'workers_per_job': workers_per_job,
            'concurrent_jobs': concurrent_jobs,
            'time_per_manifest_min': round(time_per_manifest_min, 1),
            'num_batches': num_batches,
            'total_time_hours': round(total_time_hours, 1),
            'parallel_capacity': concurrent_jobs * files_per_manifest
        },
        'cost': {
            'cost_per_manifest_usd': round(cost_per_manifest, 2),
            'daily_cost_usd': round(daily_cost, 2),
            'monthly_cost_usd': round(monthly_cost, 2),
            'cost_per_file_usd': round(daily_cost / daily_files, 4),
            'daily_dpu_hours': round(daily_dpu_hours, 1)
        }
    }


def print_result(result: Dict, title: str = "Processing Time Calculation"):
    """Pretty print calculation results."""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)

    print(f"\nInput Data:")
    print(f"  Size: {result['input_size_gb']} GB")
    print(f"  Records: {result['records']}")
    print(f"  Output Size: {result['output_size_gb']} GB (Parquet compressed)")

    print(f"\nWorker Configuration:")
    wc = result['worker_config']
    print(f"  Type: {wc['type']} ({wc['vcpu']} vCPU, {wc['ram_gb']} GB RAM)")
    print(f"  Number of Workers: {wc['num_workers']}")
    print(f"  Total DPU: {wc['total_dpu']}")

    print(f"\nSingle Worker Breakdown:")
    sw = result['single_worker_breakdown']
    print(f"  S3 Read:      {sw['read_sec']:>6.1f} seconds")
    print(f"  JSON Parse:   {sw['parse_sec']:>6.1f} seconds")
    print(f"  Processing:   {sw['process_sec']:>6.1f} seconds")
    print(f"  Parquet Write:{sw['write_sec']:>6.1f} seconds")
    print(f"  Overhead:     {sw['overhead_sec']:>6.1f} seconds")
    print(f"  -------------------------")
    print(f"  Total:        {sw['total_min']:>6.1f} minutes ({sw['total_hours']:.2f} hours)")

    if wc['num_workers'] > 1:
        print(f"\nParallel Execution ({wc['num_workers']} workers):")
        pe = result['parallel_execution']
        print(f"  Efficiency: {pe['efficiency_factor']*100:.0f}%")
        print(f"  Total Time: {pe['total_min']:.1f} minutes ({pe['total_hours']:.2f} hours)")

    print(f"\nCost:")
    cost = result['cost']
    print(f"  Per Worker: ${cost['cost_per_worker_usd']:.4f}")
    print(f"  Total: ${cost['total_cost_usd']:.2f}")
    print(f"  Per GB: ${cost['cost_per_gb_usd']:.4f}")
    print(f"  DPU-Hours: {cost['dpu_hours']:.2f}")
    print("=" * 70 + "\n")


def print_daily_result(result: Dict):
    """Pretty print daily calculation results."""
    print("\n" + "=" * 70)
    print("  Daily Production Workload Analysis")
    print("=" * 70)

    print(f"\nDaily Ingestion:")
    print(f"  Files: {result['daily_files']:,}")
    print(f"  Avg File Size: {result['avg_file_size_gb']} GB")
    print(f"  Total Data: {result['total_daily_data_tb']:.2f} TB/day")

    print(f"\nManifest Configuration:")
    m = result['manifests']
    print(f"  Files per Manifest: {m['files_per_manifest']}")
    print(f"  Total Manifests: {m['total_manifests']:,}")
    print(f"  Data per Manifest: {m['data_per_manifest_gb']:.1f} GB")

    print(f"\nProcessing Configuration:")
    p = result['processing']
    print(f"  Worker Type: {p['worker_type']}")
    print(f"  Workers per Job: {p['workers_per_job']}")
    print(f"  Concurrent Jobs: {p['concurrent_jobs']}")
    print(f"  Parallel Capacity: {p['parallel_capacity']:,} files at once")

    print(f"\nProcessing Time:")
    print(f"  Time per Manifest: {p['time_per_manifest_min']:.1f} minutes")
    print(f"  Number of Batches: {p['num_batches']}")
    print(f"  Total Daily Processing: {p['total_time_hours']:.1f} hours")

    print(f"\nCost Analysis:")
    c = result['cost']
    print(f"  Cost per Manifest: ${c['cost_per_manifest_usd']:.2f}")
    print(f"  Cost per File: ${c['cost_per_file_usd']:.4f}")
    print(f"  Daily Cost: ${c['daily_cost_usd']:,.2f}")
    print(f"  Monthly Cost: ${c['monthly_cost_usd']:,.2f}")
    print(f"  DPU-Hours/Day: {c['daily_dpu_hours']:,.1f}")
    print("=" * 70 + "\n")


def main():
    """Run example calculations."""

    print("\nAWS Glue Worker Performance Calculator")
    print("=" * 70)

    # Example 1: Single worker processing 1 GB
    print("\nExample 1: G.2X Worker Processing 1 GB")
    result1 = calculate_processing_time(1, 'G.2X', num_workers=1)
    print_result(result1, "Single G.2X Worker - 1 GB")

    # Example 2: Single worker processing 10 GB
    print("\nExample 2: G.2X Worker Processing 10 GB")
    result2 = calculate_processing_time(10, 'G.2X', num_workers=1)
    print_result(result2, "Single G.2X Worker - 10 GB")

    # Example 3: 20 workers processing 400 GB (typical manifest)
    print("\nExample 3: 20 x G.2X Workers Processing 400 GB")
    result3 = calculate_processing_time(400, 'G.2X', num_workers=20)
    print_result(result3, "20 x G.2X Workers - 400 GB (Typical Manifest)")

    # Example 4: Daily production workload
    print("\nExample 4: Daily Production Workload (338K files/day)")
    daily_result = calculate_daily_cost(
        daily_files=338_000,
        avg_file_size_gb=4.0,
        files_per_manifest=100,
        worker_type='G.2X',
        workers_per_job=20,
        concurrent_jobs=30
    )
    print_daily_result(daily_result)

    # Comparison table
    print("\nWorker Type Comparison (Processing 400 GB)")
    print("=" * 70)
    print(f"{'Worker':<8} {'Workers':<8} {'Time':<12} {'Cost':<10} {'$/GB':<10}")
    print("-" * 70)

    for worker_type in ['G.1X', 'G.2X', 'G.4X', 'G.8X']:
        r = calculate_processing_time(400, worker_type, num_workers=20)
        time_str = f"{r['parallel_execution']['total_min']:.1f} min"
        cost_str = f"${r['cost']['total_cost_usd']:.2f}"
        cost_per_gb = f"${r['cost']['cost_per_gb_usd']:.4f}"
        print(f"{worker_type:<8} {'20':<8} {time_str:<12} {cost_str:<10} {cost_per_gb:<10}")

    print("=" * 70)
    print("\nRecommendation: G.2X offers best price/performance for 3-5 GB files\n")


if __name__ == "__main__":
    main()
