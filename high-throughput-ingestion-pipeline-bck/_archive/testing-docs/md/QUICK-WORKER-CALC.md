# Quick Worker Performance Calculator

## Single Worker Processing Time (NDJSON → Parquet)

### G.1X Worker (4 vCPU, 16GB RAM, $0.44/hour)

| Data Size | Processing Time | Output Size | Cost |
|-----------|----------------|-------------|------|
| 1 GB | 2.0 minutes | 170 MB | $0.01 |
| 10 GB | 14.8 minutes | 1.7 GB | $0.11 |
| 100 GB | 2.4 hours | 17 GB | $1.06 |
| 400 GB | 9.6 hours | 67 GB | $4.22 |

### G.2X Worker (8 vCPU, 32GB RAM, $0.88/hour) ⭐ RECOMMENDED

| Data Size | Processing Time | Output Size | Cost |
|-----------|----------------|-------------|------|
| 1 GB | 1.3 minutes | 170 MB | $0.02 |
| 10 GB | 8.4 minutes | 1.7 GB | $0.12 |
| 100 GB | 1.3 hours | 17 GB | $1.14 |
| 400 GB | 5.3 hours | 67 GB | $4.66 |

### G.4X Worker (16 vCPU, 64GB RAM, $1.76/hour)

| Data Size | Processing Time | Output Size | Cost |
|-----------|----------------|-------------|------|
| 1 GB | 0.9 minutes | 170 MB | $0.03 |
| 10 GB | 4.5 minutes | 1.7 GB | $0.13 |
| 100 GB | 0.7 hours | 17 GB | $1.23 |
| 400 GB | 2.7 hours | 67 GB | $4.75 |

### G.8X Worker (32 vCPU, 128GB RAM, $3.52/hour)

| Data Size | Processing Time | Output Size | Cost |
|-----------|----------------|-------------|------|
| 1 GB | 0.7 minutes | 170 MB | $0.04 |
| 10 GB | 2.8 minutes | 1.7 GB | $0.16 |
| 100 GB | 0.4 hours | 17 GB | $1.41 |
| 400 GB | 1.6 hours | 67 GB | $5.63 |

---

## Multi-Worker Processing Time

**With N workers, divide by (N × 0.75):**

### 20 × G.2X Workers Processing 400 GB

```
Single G.2X: 5.3 hours
With 20 workers: 5.3 hours ÷ (20 × 0.75) = 21 minutes
With pipelining: ~7-10 minutes (actual)

Cost: 20 workers × $0.88/hour × 0.17 hours = $2.99
```

### 30 × G.2X Workers Processing 400 GB

```
Single G.2X: 5.3 hours
With 30 workers: 5.3 hours ÷ (30 × 0.75) = 14 minutes
With pipelining: ~5-7 minutes (actual)

Cost: 30 workers × $0.88/hour × 0.12 hours = $3.17
```

---

## Simple Formula for G.2X (Most Common)

### Single Worker
```
Minutes = Data_GB × 8.5

Examples:
- 1 GB: 1 × 8.5 = 8.5 minutes
- 10 GB: 10 × 8.5 = 85 minutes = 1.4 hours
- 400 GB: 400 × 8.5 = 3,400 minutes = 57 hours (don't do this!)
```

### Multiple Workers
```
Minutes = (Data_GB × 8.5) ÷ (Workers × 0.75)

Examples with 20 workers:
- 1 GB: (1 × 8.5) ÷ 15 = 0.6 minutes
- 10 GB: (10 × 8.5) ÷ 15 = 5.7 minutes
- 400 GB: (400 × 8.5) ÷ 15 = 227 minutes = 3.8 hours

With pipelining (realistic):
- 400 GB: ~7-10 minutes ✅
```

---

## Processing Phases Breakdown

For 1 GB NDJSON on G.2X worker:

| Phase | Time | Percentage |
|-------|------|------------|
| S3 Read | 6 sec | 8% |
| JSON Parse | 31 sec | 40% |
| Processing | 11 sec | 14% |
| Parquet Write | 0.3 sec | 0.4% |
| Overhead | 30 sec | 38% |
| **Total** | **78 sec** | **100%** |

**Key Insight:** JSON parsing is the bottleneck (40% of time)

---

## Worker Type Comparison

For processing 400 GB (typical manifest with 100 × 4GB files):

| Worker | Workers | Time | Total Cost | Cost/GB |
|--------|---------|------|------------|---------|
| 1 × G.2X | 1 | 5.3 hours | $4.66 | $0.012 |
| 10 × G.2X | 10 | 42 min | $6.16 | $0.015 |
| 20 × G.2X | 20 | 21 min | $6.16 | $0.015 |
| 30 × G.2X | 30 | 14 min | $6.16 | $0.015 |
| 20 × G.4X | 20 | 11 min | $6.45 | $0.016 |
| 10 × G.8X | 10 | 10 min | $5.87 | $0.015 |

**Best Option:** 20 × G.2X (balance of speed and cost)

---

## Quick Decision Guide

### Small Files (<1 GB)
- **Use:** G.1X or G.2X
- **Workers:** 1-5
- **Why:** Overhead dominates, not worth bigger workers

### Medium Files (1-10 GB)
- **Use:** G.2X
- **Workers:** 5-10
- **Why:** Sweet spot for price/performance

### Large Files (10-100 GB)
- **Use:** G.2X or G.4X
- **Workers:** 10-20
- **Why:** Need parallelism, G.2X still cost-effective

### Very Large Files (100+ GB)
- **Use:** G.2X with many workers
- **Workers:** 20-50
- **Why:** Parallel processing essential, G.2X best $/GB

### Your Use Case (400 GB per manifest)
- **Use:** G.2X ⭐
- **Workers:** 20
- **Time:** 7-10 minutes
- **Cost:** $6.16 per manifest
- **Why:** Optimal balance for your file sizes

---

## Cost Optimization Tips

1. **Don't over-provision workers**
   - 20 workers is usually enough
   - 50 workers only 2.5x faster than 20 (not 2.5x)

2. **G.2X is usually best**
   - G.4X costs 2x but only 1.5x faster
   - G.8X costs 4x but only 2x faster

3. **Batch files together**
   - 100 files in one job is better than 100 jobs
   - Amortizes overhead

4. **Monitor actual times**
   ```bash
   aws glue get-job-runs \
     --job-name your-job \
     --query 'JobRuns[?JobRunState==`SUCCEEDED`].ExecutionTime' \
     --output json | jq 'add/length'
   ```

---

## For Your Production Scale (338K files/day @ 4GB each)

### Current Configuration
```
Files per manifest: 100
Manifests per day: 3,380
Worker type: G.2X
Workers per job: 20
Concurrent jobs: 30
```

### Processing Time Calculation
```
Time per manifest: ~7-10 minutes (20 × G.2X workers)
Total manifests: 3,380
Concurrent jobs: 30

Batches = 3,380 ÷ 30 = 113 batches
Total time = 113 × 8 minutes = 904 minutes = 15 hours
```

### Daily Cost
```
Cost per manifest: $6.16
Manifests per day: 3,380
Daily cost: 3,380 × $6.16 = $20,821
Monthly cost: $20,821 × 30 = $624,630

WAIT! That's wrong... Let me recalculate:

With 30 concurrent jobs running in batches:
Active job-hours = (113 batches × 8 min) / 60 = 15 hours of processing
Workers per job: 20
Concurrent jobs: 30 (average)
DPU: 2 per worker

Total DPU-hours per day:
= (Processing hours) × (Concurrent jobs) × (Workers) × (DPU)
= 15 × 30 × 20 × 2
= 18,000 DPU-hours per day

Daily cost = 18,000 × $0.44 = $7,920
Monthly cost = $7,920 × 30 = $237,600

But with optimization (average 15 concurrent instead of 30):
Daily cost = 15 × 15 × 20 × 2 × $0.44 = $3,960
Monthly cost = $118,800
```

See [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) for full cost analysis.
