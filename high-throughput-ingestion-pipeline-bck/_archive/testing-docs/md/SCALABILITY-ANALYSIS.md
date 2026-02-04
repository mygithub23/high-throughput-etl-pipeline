# Scalability Analysis - NDJSON to Parquet Pipeline

## Production Metrics

### Current Scale
- **Daily Files**: 150,000 - 338,000 files
- **File Size**: 3.5 - 4.5 GB per file
- **Hourly Rate**: 1,000 - 7,000 files/hour
- **Peak Rate**: ~2 files/second
- **Daily Data Volume**: 525 TB - 1,520 TB (1.5 PB)
- **Monthly Data Volume**: 15.75 PB - 45.6 PB

## Architecture Assessment

### ✅ Components That Will Scale

#### 1. **S3 Input/Output**
- **Capacity**: Unlimited storage
- **Throughput**: 5,500 GET/PUT per second per prefix
- **Assessment**: ✅ **EXCELLENT** - S3 can handle this easily
- **Recommendation**: Use date-based prefixes (already implemented)
- **Cost**: ~$0.023/GB/month = $12,000 - $35,000/month storage

#### 2. **SQS Queue**
- **Throughput**: 3,000 messages/second (standard queue)
- **Your Peak**: ~2 messages/second
- **Assessment**: ✅ **EXCELLENT** - Only 0.07% of capacity
- **Buffering**: Can handle spikes up to 1,500x current peak
- **Cost**: Negligible (~$0.40/million messages)

#### 3. **DynamoDB File Tracking**
- **Capacity**: Auto-scaling (pay per use)
- **Write Rate**: 40,000 WCU on-demand
- **Your Peak**: ~2 writes/second
- **Assessment**: ✅ **EXCELLENT**
- **Query Performance**: GSI on date_prefix allows efficient batch queries
- **Cost**: ~$1.25 per million writes = $150-$450/month

### ⚠️ Components That Need Optimization

#### 4. **Lambda Manifest Builder**
- **Current Timeout**: 180 seconds
- **Concurrency**: Default 1,000 concurrent executions
- **Your Peak**: 2-7 invocations/second
- **Assessment**: ✅ **GOOD** but needs tuning
- **Issues**:
  - Current batch size (0.001 GB) creates 1.4M+ manifests/day
  - DynamoDB query pagination with 300K+ files will be slow
  - Lock contention at scale
- **Recommendations**:
  1. Increase batch size to 1.0 GB (production default)
  2. Add caching for recent queries
  3. Implement time-based batching (hourly manifests)
  4. Increase memory to 1024 MB for faster processing
- **Estimated Cost**: $200-$600/month (with optimization)

#### 5. **Glue Job Processing** ⚠️ **CRITICAL BOTTLENECK**
- **Current Setup**: 2 workers, batch mode
- **Throughput**: ~1 manifest per 2-3 minutes
- **Your Requirement**: Process 150,000-338,000 files/day
- **Assessment**: ❌ **WILL NOT SCALE**

**Current Bottleneck Math:**
```
With 1.0 GB batches:
- Files per batch: 1 file (3.5-4.5 GB each won't batch)
- Manifests per day: 150,000 - 338,000
- Processing time: 2 min/manifest × 338,000 = 676,000 minutes
- Required time: 11,267 hours = 470 DAYS!
```

**CRITICAL ISSUE**: Your files are too large to batch efficiently!

### 🔴 Critical Architectural Problem

**The Issue**:
- Your batch size threshold is 1 GB
- Your files are 3.5 - 4.5 GB each
- **Each file gets its own manifest** (no batching benefit)
- Glue job processes 1 manifest at a time

**Impact**:
- You're processing 150K-338K individual Glue jobs per day
- At 2 min/job, you need 470 days to process 1 day of data!

## Recommended Architecture Changes

### Option 1: Parallel Glue Jobs (Recommended)

**Change manifest batching strategy:**

```python
# Instead of batching by size, batch by FILE COUNT
MAX_FILES_PER_MANIFEST = 100  # Process 100 files in parallel

# This creates:
- 1,500 - 3,380 manifests per day (instead of 150K-338K)
- Each manifest has 100 files
- Glue processes all 100 files in parallel
- Total processing time: 3-7 hours/day
```

**Glue Configuration:**
```yaml
WorkerType: G.2X  # 2 DPU per worker (more memory for large files)
NumberOfWorkers: 10-50  # Auto-scale based on manifest queue
MaxConcurrentRuns: 50  # Process 50 manifests simultaneously
```

**Benefits:**
- ✅ Processes 1 day of data in 3-7 hours
- ✅ Scales with concurrent runs
- ✅ Handles file size variations
- ✅ Cost-effective parallelization

**Cost Estimate:**
```
50 concurrent jobs × 10 workers × $0.44/DPU-hour = $220/hour
3-7 hours per day = $660 - $1,540/day
Monthly: $20,000 - $46,000
```

### Option 2: Streaming Architecture (Long-term)

**Use Kinesis Data Firehose + Glue Streaming:**

```
S3 Upload → Lambda → Kinesis Firehose → Glue Streaming → Parquet
          ↓
     Track in DynamoDB (optional)
```

**Benefits:**
- ✅ Continuous processing (no batching delays)
- ✅ Built-in buffering (size or time-based)
- ✅ Automatic scaling
- ✅ Lower complexity

**Cost Estimate:**
```
Firehose: $0.029/GB = $15,000 - $44,000/month
Glue Streaming: $0.44/DPU-hour, continuous = $10,000 - $15,000/month
Total: $25,000 - $59,000/month
```

### Option 3: EMR Cluster (Best for High Volume)

**Use EMR with Spark for massive parallelization:**

```yaml
Cluster:
  MasterNodes: 1 × m5.xlarge
  CoreNodes: 20 × r5.4xlarge (auto-scaling 10-50)
  Processing: Spark batch jobs from manifest queue
```

**Benefits:**
- ✅ Best price/performance for large data
- ✅ Handles any scale
- ✅ Flexible resource allocation
- ✅ Spot instances available

**Cost Estimate:**
```
Core nodes: 20 × $1.008/hour (spot) = $20/hour
Processing 24/7 = $480/day = $14,400/month
With auto-scaling (10 hours/day): $6,000/month
```

## Updated Architecture Recommendations

### Immediate Changes (This Week)

1. **Increase Lambda Memory**
   ```bash
   aws lambda update-function-configuration \
     --function-name ndjson-parquet-sqs-manifest-builder \
     --memory-size 1024 \
     --timeout 300 \
     --region us-east-1
   ```

2. **Change Batching Strategy**
   Update Lambda to batch by FILE COUNT instead of SIZE:
   ```python
   MAX_FILES_PER_MANIFEST = 100
   MAX_BATCH_SIZE_GB = 500  # 100 files × 4.5 GB
   ```

3. **Enable Glue Concurrent Runs**
   ```bash
   aws glue update-job \
     --job-name ndjson-parquet-sqs-streaming-processor \
     --job-update '{
       "MaxConcurrentRuns": 50,
       "WorkerType": "G.2X",
       "NumberOfWorkers": 10
     }'
   ```

4. **Add Manifest Queue Processing**
   - Create SQS queue for manifests
   - Lambda triggers Glue job for each manifest
   - Multiple Glue jobs run in parallel

### Short-term (This Month)

1. **Implement Auto-scaling**
   - Monitor manifest backlog
   - Auto-scale Glue concurrent runs
   - CloudWatch alarms for queue depth

2. **Add Retry Logic**
   - DLQ for failed Glue jobs
   - Exponential backoff
   - Manual retry process

3. **Optimize Glue Job**
   - Partition output by hour (not just date)
   - Use dynamic frames for better memory
   - Implement checkpointing

### Long-term (3-6 Months)

1. **Migrate to EMR** (if cost-effective)
2. **Implement Streaming** (if real-time needed)
3. **Add Data Quality Checks**
4. **Set up Athena for querying**

## Cost Projections

### Current Architecture (Won't Scale)
- **Lambda**: $600/month
- **Glue**: Would take 470 days to process 1 day!
- **Total**: ❌ Not viable

### Recommended Architecture (File-count Batching)
- **S3**: $12,000 - $35,000/month
- **Lambda**: $600/month
- **DynamoDB**: $450/month
- **SQS**: $50/month
- **Glue (50 concurrent jobs)**: $20,000 - $46,000/month
- **Total**: $33,000 - $82,000/month

### EMR Alternative
- **S3**: $12,000 - $35,000/month
- **Lambda**: $600/month
- **DynamoDB**: $450/month
- **EMR (spot instances)**: $6,000 - $14,000/month
- **Total**: $19,000 - $50,000/month

## Performance Benchmarks

### Target Performance
- **Latency**: < 30 minutes from upload to Parquet
- **Throughput**: 7,000 files/hour sustained
- **Availability**: 99.9%
- **Data Loss**: Zero tolerance

### Expected Performance with Recommendations

**Option 1: File-count Batching + Parallel Glue**
```
Processing Time: 3-7 hours per day
Latency: 30 min - 2 hours
Throughput: 7,000 files/hour (peak)
Cost: $33K - $82K/month
```

**Option 2: EMR**
```
Processing Time: Continuous
Latency: < 30 minutes
Throughput: 10,000+ files/hour
Cost: $19K - $50K/month
```

## Monitoring Requirements

### Critical Metrics
1. **Manifest Creation Rate**: Should match file upload rate
2. **Glue Job Queue Depth**: Should stay < 100
3. **Glue Job Failure Rate**: Should be < 1%
4. **Average Processing Time**: Should be < 2 hours end-to-end
5. **Cost per TB**: Track for optimization

### Alarms Needed
```yaml
1. Manifest queue depth > 500
2. Glue job failures > 10/hour
3. Lambda errors > 100/hour
4. DynamoDB throttling > 0
5. Daily cost > $3,000
```

## Summary

### Current Status
- ✅ Architecture is solid for components
- ❌ Glue processing is major bottleneck
- ⚠️ Need to change from size-based to file-count batching

### Required Changes
1. **Critical**: Batch by file count (100 files/manifest)
2. **Critical**: Enable Glue concurrent runs (50+)
3. **Critical**: Increase Glue workers to G.2X
4. **Important**: Add manifest queue
5. **Important**: Implement auto-scaling

### Estimated Timeline
- Week 1: Implement file-count batching
- Week 2: Enable concurrent Glue jobs
- Week 3: Add monitoring and alarms
- Week 4: Load testing and optimization

### Expected Outcome
- ✅ Process 338,000 files in 3-7 hours
- ✅ Cost: $33K - $82K/month (Option 1) or $19K - $50K/month (EMR)
- ✅ Scalable to 500K+ files/day
- ✅ < 30 min latency

## Next Steps

1. Review this analysis
2. Choose architecture option (recommend starting with Option 1)
3. Implement file-count batching in Lambda
4. Test with production-like data (3.5 GB files)
5. Gradually increase concurrent Glue runs
6. Monitor costs and performance
7. Optimize based on real data
