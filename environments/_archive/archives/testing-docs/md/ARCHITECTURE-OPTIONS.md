# Architecture Options for Production Scale

## Your Scale
- **Files/day**: 150,000 - 338,000
- **File size**: 3.5 - 4.5 GB
- **Peak rate**: 7,000 files/hour
- **Daily volume**: 525 TB - 1.5 PB

## Current Architecture WILL WORK - Just Needs Configuration

The "470 days" problem is **only with current settings**. Here are proven solutions:

---

## Option 1: Parallel Glue Jobs (RECOMMENDED) ⭐

**How It Works:**
```
1. Lambda creates manifests with 100 files each
2. Launch 50 Glue jobs in parallel
3. Each job uses Spark to process its 100 files in parallel
4. Within each job, 20 workers divide the work
```

**Architecture:**
```
S3 Upload (7,000 files/hour peak)
    ↓
Lambda creates manifests
    ↓ (creates 70 manifests/hour)
50 Glue Jobs running in parallel
    ↓ (each job processes 100 files)
Parquet output
```

**Configuration Changes:**

### Lambda Changes (2 hours work):
```python
# In lambda_manifest_builder.py

# ADD new environment variable
MAX_FILES_PER_MANIFEST = int(os.environ.get('MAX_FILES_PER_MANIFEST', '100'))

# MODIFY _create_batches() function:
def _create_batches(self, files: List[Dict]) -> List[List[Dict]]:
    """Create batches by FILE COUNT instead of SIZE."""
    batches = []
    current_batch = []

    for file_info in files:
        current_batch.append(file_info)

        # Batch by file count
        if len(current_batch) >= MAX_FILES_PER_MANIFEST:
            batches.append(current_batch)
            current_batch = []

    # Add remaining files
    if current_batch:
        batches.append(current_batch)

    return batches
```

### Glue Job Configuration (5 minutes):
```bash
aws glue update-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update '{
    "MaxConcurrentRuns": 50,
    "WorkerType": "G.2X",
    "NumberOfWorkers": 20,
    "ExecutionProperty": {
      "MaxConcurrentRuns": 50
    }
  }' \
  --region us-east-1
```

### Lambda Environment Variables:
```bash
aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --environment "Variables={
    MAX_FILES_PER_MANIFEST=100,
    MAX_BATCH_SIZE_GB=500,
    ...other variables...
  }"
```

**Performance:**
```
Manifests created: 338,000 files ÷ 100 = 3,380 manifests/day
Concurrent jobs: 50
Processing time per job: 3-5 minutes
Total time: 3,380 ÷ 50 × 4 min = 270 minutes = 4.5 hours ✅
```

**Cost Calculation:**
```
Per hour:
- 50 jobs × 20 workers × 2 DPU × $0.44/DPU-hour = $880/hour

Per day:
- 4.5 hours × $880 = $3,960/day

Per month:
- $3,960 × 30 = $118,800/month

WAIT - This is too expensive! Let's optimize...
```

**Cost Optimization:**
```
Use auto-scaling instead of continuous 50 jobs:
- Average concurrent jobs: 15-20 (based on actual load)
- Scale up to 50 during peak hours only
- Cost: $1,200 - $1,800/day = $36,000 - $54,000/month ✅
```

**Pros:**
- ✅ Minimal code changes
- ✅ Uses existing architecture
- ✅ Leverages Spark's parallel processing
- ✅ Can scale to 500K+ files/day
- ✅ Can implement this week

**Cons:**
- ⚠️ Higher cost than alternatives
- ⚠️ Need to monitor concurrent runs carefully

---

## Option 2: Increase Workers Per Job (SIMPLEST) ⭐⭐

**How It Works:**
```
1. Keep manifests with 100 files
2. Use fewer concurrent jobs (20)
3. Use MORE workers per job (50)
4. Spark distributes files across workers
```

**Configuration:**
```yaml
MaxConcurrentRuns: 20          # Fewer jobs
WorkerType: G.2X               # 16GB RAM per worker
NumberOfWorkers: 50            # More workers per job
```

**Math:**
```
Each job:
- 50 workers process 100 files
- Each worker handles 2 files
- Time per job: 5-7 minutes (parallel processing)

Daily:
- 3,380 manifests ÷ 20 concurrent = 169 batches
- 169 × 6 min = 1,014 minutes = 17 hours

Hmm, that's slower. Let's adjust:

Better configuration:
- 30 concurrent jobs
- 30 workers each
- Each worker processes 3-4 files
- Time: 8-10 hours/day ✅
```

**Cost:**
```
30 jobs × 30 workers × 2 DPU × $0.44 = $792/hour
10 hours/day × $792 = $7,920/day
Monthly: $237,600/month ❌ Too expensive!
```

This shows **concurrent jobs is better than workers per job** for your scale.

---

## Option 3: EMR with Spark (BEST PRICE/PERFORMANCE) ⭐⭐⭐

**How It Works:**
```
1. Launch persistent EMR cluster
2. Process manifests continuously
3. Auto-scale based on queue depth
4. Use spot instances for 70% cost savings
```

**Architecture:**
```
S3 Upload
    ↓
Lambda tracks files + creates manifests
    ↓
Manifest queue (SQS)
    ↓
EMR Cluster polls queue
    ↓ (processes 100 files per manifest in parallel)
Parquet output
```

**EMR Cluster Configuration:**
```yaml
Master: 1 × m5.xlarge (on-demand) = $0.192/hour
Core: 20 × r5.4xlarge (spot) = $1.008/hour each
Total: $0.192 + (20 × $1.008) = $20.35/hour

Auto-scaling:
- Min: 10 nodes during low traffic
- Max: 50 nodes during peak
- Average: 20 nodes
```

**Processing:**
```python
# EMR Spark job (runs continuously):
while True:
    # Poll manifest queue
    manifests = sqs.receive_messages(MaxNumberOfMessages=10)

    for manifest in manifests:
        # Process in parallel
        df = spark.read.json(manifest.file_paths)
        df.write.parquet(output_path)

        # Delete message
        manifest.delete()
```

**Performance:**
```
20 core nodes processing:
- Each manifest: 3-5 minutes
- Can process 300+ manifests/hour
- 3,380 manifests ÷ 300 = 11.3 hours

With 50 nodes (peak):
- 750+ manifests/hour
- 3,380 manifests ÷ 750 = 4.5 hours ✅
```

**Cost:**
```
Average cluster (20 nodes, 12 hours/day):
- $20.35/hour × 12 hours = $244/day
- Monthly: $7,320/month ✅✅✅

Peak hours (50 nodes, 4 hours/day):
- $50/hour × 4 hours = $200/day
- Monthly: $6,000/month

Total: ~$13,000/month ✅✅✅
```

**Pros:**
- ✅ **Best cost/performance** ($13K vs $36K-$54K)
- ✅ Continuous processing (no cold starts)
- ✅ Better resource utilization
- ✅ Easier to monitor and debug
- ✅ Can use spot instances for 70% savings

**Cons:**
- ⚠️ More complex setup (2-3 days)
- ⚠️ Need to manage cluster
- ⚠️ Requires EMR expertise

---

## Option 4: Hybrid Approach (BALANCED) ⭐⭐

**How It Works:**
```
1. Use Glue for normal hours (cheaper)
2. Use EMR for peak hours (faster)
3. Switch based on queue depth
```

**Logic:**
```python
if manifest_queue_depth > 500:
    use_emr_cluster()  # Fast parallel processing
else:
    use_glue_jobs()    # Pay per job
```

**Cost:**
```
Glue (20 hours/day, low traffic):
- 10 concurrent jobs × 20 workers × 2 DPU × $0.44
- $176/hour × 20 hours = $3,520/day

EMR (4 hours/day, peak traffic):
- 50 nodes × $1.01/hour (spot)
- $50/hour × 4 hours = $200/day

Daily: $3,720
Monthly: $111,600/month ❌ Still expensive

Better hybrid:
- Use EMR for most processing ($13K/month)
- Use Glue for overflow only ($5K/month)
- Total: ~$18K/month ✅
```

---

## Comparison Table

| Option | Complexity | Setup Time | Monthly Cost | Processing Time | Scalability |
|--------|-----------|------------|--------------|-----------------|-------------|
| **Parallel Glue** | Low | 1 day | $36K-$54K | 4.5 hours | ✅✅ |
| **More Workers** | Very Low | 1 hour | $237K | 10 hours | ⚠️ |
| **EMR** | Medium | 3 days | **$13K** | 4.5 hours | ✅✅✅ |
| **Hybrid** | High | 5 days | $18K | 3-5 hours | ✅✅✅ |

---

## My Recommendation: Start with Option 1, Move to EMR

### Phase 1: This Week (Quick Fix)
**Use Parallel Glue Jobs:**
1. Modify Lambda to batch by file count (2 hours)
2. Update Glue configuration (30 minutes)
3. Test with 1,000 files
4. Deploy to production
5. Monitor for 1 week

**Cost:** $36K-$54K/month
**Timeline:** 2-3 days to implement

### Phase 2: Next Month (Optimize)
**Migrate to EMR:**
1. Set up EMR cluster (1 day)
2. Port Glue PySpark code to EMR (1 day)
3. Set up auto-scaling (1 day)
4. Parallel testing (2 days)
5. Gradual migration

**Cost:** $13K/month (62% savings!)
**Timeline:** 1 week to implement, 1 week parallel testing

### Phase 3: Long-term (Scale)
**Optimize further:**
1. Fine-tune worker counts
2. Implement spot instance strategies
3. Add intelligent queueing
4. Cost monitoring and optimization

**Target:** $10K-$15K/month

---

## Detailed Implementation: Option 1 (Parallel Glue)

### Step 1: Update Lambda Code

```python
# environments/prod/lambda/lambda_manifest_builder.py

# Add at top:
MAX_FILES_PER_MANIFEST = int(os.environ.get('MAX_FILES_PER_MANIFEST', '100'))
MAX_BATCH_SIZE_GB = float(os.environ.get('MAX_BATCH_SIZE_GB', '500'))  # Safety limit

# Replace _create_batches():
def _create_batches(self, files: List[Dict]) -> List[List[Dict]]:
    """
    Create batches by FILE COUNT for better parallelization.

    For large files (3.5-4.5GB), batching by count is more efficient
    than batching by size.
    """
    batches = []
    current_batch = []
    current_size = 0

    for file_info in files:
        current_batch.append(file_info)
        current_size += file_info['size_bytes']

        # Batch when we hit file count OR size limit (safety)
        if len(current_batch) >= MAX_FILES_PER_MANIFEST or \
           current_size >= MAX_BATCH_SIZE_GB * (1024**3):
            batches.append(current_batch)
            logger.info(f"Batch created: {len(current_batch)} files, "
                       f"{current_size / (1024**3):.2f}GB")
            current_batch = []
            current_size = 0

    # Add remaining files
    if current_batch:
        batches.append(current_batch)
        logger.info(f"Final batch: {len(current_batch)} files, "
                   f"{current_size / (1024**3):.2f}GB")

    return batches
```

### Step 2: Deploy Lambda

```bash
cd environments/prod/lambda
zip -r lambda.zip lambda_manifest_builder.py

aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://lambda.zip \
  --region us-east-1

aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --environment "Variables={
    TRACKING_TABLE=ndjson-parquet-sqs-file-tracking,
    METRICS_TABLE=ndjson-parquet-sqs-metrics,
    MANIFEST_BUCKET=ndjson-manifests-<ACCOUNT>,
    GLUE_JOB_NAME=ndjson-parquet-sqs-streaming-processor,
    MAX_FILES_PER_MANIFEST=100,
    MAX_BATCH_SIZE_GB=500,
    QUARANTINE_BUCKET=ndjson-quarantine-<ACCOUNT>,
    EXPECTED_FILE_SIZE_MB=3500,
    SIZE_TOLERANCE_PERCENT=20,
    LOCK_TABLE=ndjson-parquet-sqs-file-tracking,
    LOCK_TTL_SECONDS=300
  }" \
  --memory-size 1024 \
  --timeout 300 \
  --region us-east-1
```

### Step 3: Update Glue Job

```bash
aws glue update-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update '{
    "MaxConcurrentRuns": 50,
    "WorkerType": "G.2X",
    "NumberOfWorkers": 20,
    "ExecutionProperty": {
      "MaxConcurrentRuns": 50
    },
    "DefaultArguments": {
      "--enable-metrics": "true",
      "--enable-spark-ui": "true",
      "--enable-job-insights": "true",
      "--enable-auto-scaling": "true"
    }
  }' \
  --region us-east-1
```

### Step 4: Create Glue Job Trigger

```bash
# Create Lambda to trigger Glue jobs from manifest queue
# This ensures manifests are processed automatically

# Or use EventBridge to trigger on manifest creation:
aws events put-rule \
  --name trigger-glue-on-manifest \
  --event-pattern '{
    "source": ["aws.s3"],
    "detail-type": ["Object Created"],
    "detail": {
      "bucket": {"name": ["ndjson-manifests-<ACCOUNT>"]},
      "object": {"key": [{"prefix": "manifests/"}]}
    }
  }'
```

### Step 5: Monitor

```bash
# Watch Glue jobs
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --query 'JobRuns[*].{Started:StartedOn,State:JobRunState,Duration:ExecutionTime}' \
  --output table

# Watch costs
aws ce get-cost-and-usage \
  --time-period Start=2025-12-01,End=2025-12-31 \
  --granularity DAILY \
  --metrics BlendedCost \
  --filter file://glue-cost-filter.json
```

---

## Testing Plan

### Week 1: Small Scale Test
```bash
# Test with 1,000 files (3.5GB each = 3.5TB total)
# Expected: 10 manifests, ~20 minutes to process
# Cost: ~$10

1. Generate or upload 1,000 test files
2. Monitor Lambda manifest creation
3. Watch Glue jobs process
4. Verify Parquet output
5. Check costs
```

### Week 2: Medium Scale Test
```bash
# Test with 10,000 files (35TB total)
# Expected: 100 manifests, ~3 hours to process
# Cost: ~$200

1. Upload 10,000 test files over 2 hours
2. Monitor system behavior
3. Check for bottlenecks
4. Verify no errors
5. Validate Parquet data
```

### Week 3: Full Scale Test
```bash
# Test with 50,000 files (175TB total)
# Expected: 500 manifests, ~7 hours to process
# Cost: ~$1,500

1. Simulate production load
2. Monitor all metrics
3. Check auto-scaling
4. Verify cost projections
5. Load test with peak rates
```

### Week 4: Production Deployment
```bash
# Gradual rollout
Day 1: 10% of traffic
Day 2: 25% of traffic
Day 3: 50% of traffic
Day 4: 75% of traffic
Day 5: 100% of traffic
```

---

## Summary

**Your current architecture IS fine** - it just needs the right configuration!

**Quickest solution**: Option 1 (Parallel Glue) - 2-3 days to implement
**Best long-term**: Option 3 (EMR) - 62% cost savings

**My recommendation**:
1. Start with Parallel Glue (this week) → Proves it works
2. Optimize costs with EMR (next month) → Sustainable long-term
3. Fine-tune based on real data → Get to $10-15K/month

The key insight: **Spark already does parallel processing** - you just need to:
1. Batch by file count (not size)
2. Run multiple jobs concurrently
3. Use enough workers per job

You can definitely handle 338K files/day!
