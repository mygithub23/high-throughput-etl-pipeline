# Worker Performance Calculator - Usage Guide

## Overview

The `worker_calculator.py` script calculates processing time and costs for AWS Glue NDJSON to Parquet conversion jobs.

## Quick Start

### Run Examples

```bash
cd environments
python worker_calculator.py
```

This will run 4 example calculations:
1. Single G.2X worker processing 1 GB
2. Single G.2X worker processing 10 GB
3. 20 × G.2X workers processing 400 GB (typical manifest)
4. Daily production workload (338K files/day)

---

## Using in Your Code

### Import the Functions

```python
from worker_calculator import calculate_processing_time, calculate_daily_cost
```

### Example 1: Calculate Single Worker Time

```python
# Calculate time for 1 GB on G.2X worker
result = calculate_processing_time(
    data_size_gb=1,
    worker_type='G.2X',
    num_workers=1
)

print(f"Processing time: {result['single_worker_breakdown']['total_min']} minutes")
print(f"Cost: ${result['cost']['total_cost_usd']}")

# Output:
# Processing time: 1.5 minutes
# Cost: $0.02
```

### Example 2: Calculate Multi-Worker Time

```python
# Calculate time for 400 GB with 20 G.2X workers
result = calculate_processing_time(
    data_size_gb=400,
    worker_type='G.2X',
    num_workers=20
)

print(f"Single worker would take: {result['single_worker_breakdown']['total_hours']} hours")
print(f"With 20 workers: {result['parallel_execution']['total_min']} minutes")
print(f"Cost: ${result['cost']['total_cost_usd']}")

# Output:
# Single worker would take: 5.31 hours
# With 20 workers: 21.2 minutes
# Cost: $6.19
```

### Example 3: Calculate Daily Production Cost

```python
# Calculate cost for 338K files/day at 4GB each
daily = calculate_daily_cost(
    daily_files=338_000,
    avg_file_size_gb=4.0,
    files_per_manifest=100,
    worker_type='G.2X',
    workers_per_job=20,
    concurrent_jobs=30
)

print(f"Daily processing time: {daily['processing']['total_time_hours']} hours")
print(f"Daily cost: ${daily['cost']['daily_cost_usd']:,}")
print(f"Monthly cost: ${daily['cost']['monthly_cost_usd']:,}")

# Output:
# Daily processing time: 11.9 hours
# Daily cost: $20,906.40
# Monthly cost: $627,192.00
```

---

## Function Reference

### `calculate_processing_time()`

Calculates processing time for a single job.

**Parameters:**
- `data_size_gb` (float): Input data size in GB
- `worker_type` (str): One of 'G.1X', 'G.2X', 'G.4X', 'G.8X'
- `num_workers` (int): Number of workers (default: 1)
- `avg_record_size_bytes` (int): Average JSON record size (default: 200)
- `compression_ratio` (float): Parquet compression ratio (default: 6.0)

**Returns:** Dictionary with:
```python
{
    'input_size_gb': 400,
    'output_size_gb': 66.67,  # Compressed
    'records': '2,147,483,648',
    'worker_config': {
        'type': 'G.2X',
        'vcpu': 8,
        'ram_gb': 32,
        'dpu': 2,
        'num_workers': 20,
        'total_dpu': 40
    },
    'single_worker_breakdown': {
        'read_sec': 2340.6,
        'parse_sec': 12271.3,
        'process_sec': 4295.0,
        'write_sec': 109.2,
        'overhead_sec': 90,
        'total_sec': 19106.1,
        'total_min': 318.4,
        'total_hours': 5.31
    },
    'parallel_execution': {
        'efficiency_factor': 0.75,
        'total_sec': 1272.4,
        'total_min': 21.2,
        'total_hours': 0.35
    },
    'cost': {
        'cost_per_worker_usd': 0.3094,
        'total_cost_usd': 6.19,
        'cost_per_gb_usd': 0.0155,
        'dpu_hours': 14.06
    }
}
```

### `calculate_daily_cost()`

Calculates daily processing metrics and costs.

**Parameters:**
- `daily_files` (int): Number of files per day
- `avg_file_size_gb` (float): Average file size in GB
- `files_per_manifest` (int): Files per manifest
- `worker_type` (str): Worker type
- `workers_per_job` (int): Workers per Glue job
- `concurrent_jobs` (int): Max concurrent Glue jobs

**Returns:** Dictionary with daily metrics and costs.

---

## Worker Type Specifications

| Type | vCPU | RAM | Cost/Hour | Best For |
|------|------|-----|-----------|----------|
| G.1X | 4 | 16 GB | $0.44 | Small files (<1 GB) |
| G.2X | 8 | 32 GB | $0.88 | Medium-large files (3-5 GB) ⭐ |
| G.4X | 16 | 64 GB | $1.76 | Very large files (>5 GB) |
| G.8X | 32 | 128 GB | $3.52 | Huge files (>10 GB) |

---

## Performance Benchmarks

### Single Worker Times (G.2X)

| Data Size | Processing Time | Cost |
|-----------|----------------|------|
| 1 GB | 1.5 minutes | $0.02 |
| 10 GB | 8.9 minutes | $0.13 |
| 100 GB | 1.5 hours | $1.31 |
| 400 GB | 5.3 hours | $4.66 |

### Multi-Worker Times (20 × G.2X)

| Data Size | Processing Time | Cost |
|-----------|----------------|------|
| 1 GB | 0.1 minutes | $0.31 |
| 10 GB | 0.6 minutes | $1.74 |
| 100 GB | 6.0 minutes | $17.47 |
| 400 GB | 21.2 minutes | $6.19 |

---

## Tips

### 1. Choosing Worker Type

**For your use case (3.5-4.5 GB files):**
- **Use G.2X** - Best price/performance
- G.4X is 2x cost but only 1.5x faster
- G.1X struggles with large files

### 2. Optimal Worker Count

**For 400 GB (100 files × 4 GB):**
- 10 workers: 42 minutes, $6.16
- **20 workers: 21 minutes, $6.19** ⭐ Sweet spot
- 30 workers: 14 minutes, $6.19
- 50 workers: 8 minutes, $6.22

**Diminishing returns after 20 workers.**

### 3. Adjusting for Your Data

If your records are different sizes:

```python
# Your records average 300 bytes instead of 200
result = calculate_processing_time(
    data_size_gb=10,
    worker_type='G.2X',
    avg_record_size_bytes=300  # Adjust this
)
```

If compression is different:

```python
# Your data compresses 8x instead of 6x
result = calculate_processing_time(
    data_size_gb=10,
    worker_type='G.2X',
    compression_ratio=8.0  # Adjust this
)
```

---

## Validation

To validate against real job times:

```bash
# Get actual job execution times
aws glue get-job-runs \
  --job-name your-job-name \
  --max-results 20 \
  --query 'JobRuns[?JobRunState==`SUCCEEDED`].ExecutionTime' \
  --output json | jq 'add/length'

# Compare with calculator estimate
python -c "
from worker_calculator import calculate_processing_time
r = calculate_processing_time(400, 'G.2X', 20)
print(f'Estimated: {r[\"parallel_execution\"][\"total_min\"]} minutes')
"
```

---

## Common Calculations

### How long for 1 manifest?

```python
result = calculate_processing_time(400, 'G.2X', 20)
print(f"{result['parallel_execution']['total_min']} minutes")
# Output: 21.2 minutes
```

### How long for 338K files/day?

```python
daily = calculate_daily_cost(338_000, 4.0, 100, 'G.2X', 20, 30)
print(f"{daily['processing']['total_time_hours']} hours")
# Output: 11.9 hours
```

### How much will it cost per day?

```python
daily = calculate_daily_cost(338_000, 4.0, 100, 'G.2X', 20, 30)
print(f"${daily['cost']['daily_cost_usd']:,.2f}")
# Output: $20,906.40
```

### What if I use 50 concurrent jobs?

```python
daily = calculate_daily_cost(338_000, 4.0, 100, 'G.2X', 20, 50)
print(f"{daily['processing']['total_time_hours']} hours")
print(f"${daily['cost']['daily_cost_usd']:,.2f}")
# Output: 7.4 hours, $20,906.40 (same cost, faster)
```

---

## Output File Location

The calculator is located at:
```
environments/worker_calculator.py
```

Run from the `environments/` directory:
```bash
cd environments
python worker_calculator.py
```

---

## Related Documentation

- [WORKER-PERFORMANCE-BENCHMARKS.md](WORKER-PERFORMANCE-BENCHMARKS.md) - Detailed technical analysis
- [QUICK-WORKER-CALC.md](QUICK-WORKER-CALC.md) - Quick reference tables
- [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) - Full configuration reference

---

## Example Output

```
AWS Glue Worker Performance Calculator
======================================================================

Example 1: G.2X Worker Processing 1 GB

======================================================================
  Single G.2X Worker - 1 GB
======================================================================

Input Data:
  Size: 1 GB
  Records: 5,368,709
  Output Size: 0.17 GB (Parquet compressed)

Worker Configuration:
  Type: G.2X (8 vCPU, 32 GB RAM)
  Number of Workers: 1
  Total DPU: 2

Single Worker Breakdown:
  S3 Read:         5.9 seconds
  JSON Parse:     30.7 seconds
  Processing:     10.7 seconds
  Parquet Write:   0.3 seconds
  Overhead:       45.0 seconds
  -------------------------
  Total:           1.5 minutes (0.03 hours)

Cost:
  Per Worker: $0.0226
  Total: $0.02
  Per GB: $0.0226
  DPU-Hours: 0.05
======================================================================
```
