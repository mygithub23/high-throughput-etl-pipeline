# Daily Cost Estimate - NDJSON to Parquet Pipeline

## Configuration Summary (Dev Environment)

| Setting | Value |
|---------|-------|
| Region | us-east-1 |
| DynamoDB Capacity | 1 RCU / 1 WCU (Provisioned) |
| Lambda Memory | 512 MB |
| Lambda Timeout | 180 seconds |
| Glue Worker Type | G.1X (4 vCPU, 16GB) |
| Glue Workers | 2 |
| Log Retention | 3 days |

---

## Cost Breakdown by Resource

### 1. AWS Glue (Largest Cost Driver)

| Component | Pricing | Calculation |
|-----------|---------|-------------|
| G.1X Worker | $0.44/DPU-hour | 2 workers × $0.44 = $0.88/hour |

**Daily Estimate (based on usage):**

| Scenario | Jobs/Day | Avg Duration | Daily Cost |
|----------|----------|--------------|------------|
| Idle | 0 | - | $0.00 |
| Light (10 manifests) | 10 | 5 min | $0.73 |
| Medium (50 manifests) | 50 | 5 min | $3.67 |
| Heavy (200 manifests) | 200 | 5 min | $14.67 |

**Formula:** `jobs × (duration_hours) × 2_workers × $0.44`

---

### 2. AWS Step Functions (Standard)

| Component | Pricing |
|-----------|---------|
| State Transitions | $0.025 per 1,000 transitions |
| States per Execution | ~5 (UpdateProcessing → StartGlue → UpdateCompleted/Failed → SendAlert) |

**Daily Estimate:**

| Scenario | Executions/Day | Transitions | Daily Cost |
|----------|----------------|-------------|------------|
| Idle | 0 | 0 | $0.00 |
| Light | 10 | 50 | $0.00125 |
| Medium | 50 | 250 | $0.00625 |
| Heavy | 200 | 1,000 | $0.025 |

---

### 3. AWS Lambda

| Component | Pricing |
|-----------|---------|
| Requests | $0.20 per 1M requests |
| Duration | $0.0000166667 per GB-second |
| Memory | 512 MB (0.5 GB) |

**Daily Estimate (Manifest Builder):**

| Scenario | Invocations | Avg Duration | Daily Cost |
|----------|-------------|--------------|------------|
| Idle | 0 | - | $0.00 |
| Light (1K files) | 100 | 2 sec | $0.0017 |
| Medium (10K files) | 1,000 | 2 sec | $0.017 |
| Heavy (100K files) | 10,000 | 2 sec | $0.17 |

**Formula:** `invocations × duration_sec × 0.5GB × $0.0000166667`

---

### 4. Amazon DynamoDB (Provisioned)

| Component | Pricing | Your Config |
|-----------|---------|-------------|
| Read Capacity | $0.00013/RCU/hour | 1 RCU |
| Write Capacity | $0.00065/WCU/hour | 1 WCU |

**Daily Cost (24/7 baseline):**
- Read: 1 RCU × 24 hours × $0.00013 = **$0.003**
- Write: 1 WCU × 24 hours × $0.00065 = **$0.016**
- **Total: $0.019/day** (~$0.57/month)

**Note:** Storage is $0.25/GB/month, negligible for tracking data.

---

### 5. Amazon S3

| Component | Pricing |
|-----------|---------|
| Standard Storage | $0.023/GB/month |
| PUT/POST/LIST | $0.005 per 1,000 requests |
| GET/SELECT | $0.0004 per 1,000 requests |

**Daily Estimate (5 buckets):**

| Scenario | Storage (GB) | PUT Requests | GET Requests | Daily Cost |
|----------|--------------|--------------|--------------|------------|
| Idle | 1 | 0 | 0 | $0.00077 |
| Light | 5 | 1,000 | 5,000 | $0.012 |
| Medium | 20 | 10,000 | 50,000 | $0.087 |
| Heavy | 100 | 100,000 | 500,000 | $0.77 |

**Note:** Lifecycle policies auto-delete old data (input: 3 days, manifest: 1 day, quarantine: 7 days)

---

### 6. Amazon SQS

| Component | Pricing |
|-----------|---------|
| Requests | $0.40 per 1M requests (first 1M free) |

**Daily Estimate:**

| Scenario | Messages/Day | Daily Cost |
|----------|--------------|------------|
| Light | 1,000 | $0.00 (free tier) |
| Medium | 10,000 | $0.00 (free tier) |
| Heavy | 100,000 | $0.00 (free tier) |
| Very Heavy | 1,000,000 | $0.00 (free tier) |

**Note:** First 1M requests/month free, then $0.40/million

---

### 7. Amazon SNS

| Component | Pricing |
|-----------|---------|
| Publish | $0.50 per 1M requests (first 1M free) |
| Email Delivery | $0.00 |

**Daily Estimate:** ~$0.00 (only used for failure alerts)

---

### 8. Amazon CloudWatch

| Component | Pricing |
|-----------|---------|
| Log Ingestion | $0.50 per GB |
| Log Storage | $0.03 per GB/month |
| Metrics | First 10 custom metrics free |
| Dashboard | $3.00/month per dashboard |

**Daily Estimate:**

| Scenario | Log Volume | Daily Cost |
|----------|------------|------------|
| Idle | 0 MB | $0.00 |
| Light | 50 MB | $0.025 |
| Medium | 200 MB | $0.10 |
| Heavy | 1 GB | $0.50 |

**Dashboard:** $0.10/day ($3/month) if enabled

---

## Daily Cost Summary Tables

### Scenario: IDLE (No Processing)

| Resource | Daily Cost |
|----------|------------|
| DynamoDB | $0.019 |
| CloudWatch Dashboard | $0.10 |
| S3 Storage (minimal) | $0.001 |
| **Total** | **$0.12** |

### Scenario: LIGHT (1,000 files/day, 10 manifests)

| Resource | Daily Cost |
|----------|------------|
| Glue Jobs | $0.73 |
| Step Functions | $0.001 |
| Lambda | $0.002 |
| DynamoDB | $0.019 |
| S3 | $0.012 |
| SQS | $0.00 |
| CloudWatch Logs | $0.025 |
| CloudWatch Dashboard | $0.10 |
| **Total** | **$0.89** |

### Scenario: MEDIUM (10,000 files/day, 50 manifests)

| Resource | Daily Cost |
|----------|------------|
| Glue Jobs | $3.67 |
| Step Functions | $0.006 |
| Lambda | $0.017 |
| DynamoDB | $0.019 |
| S3 | $0.087 |
| SQS | $0.00 |
| CloudWatch Logs | $0.10 |
| CloudWatch Dashboard | $0.10 |
| **Total** | **$4.00** |

### Scenario: HEAVY (100,000 files/day, 200 manifests)

| Resource | Daily Cost |
|----------|------------|
| Glue Jobs | $14.67 |
| Step Functions | $0.025 |
| Lambda | $0.17 |
| DynamoDB | $0.05* |
| S3 | $0.77 |
| SQS | $0.00 |
| CloudWatch Logs | $0.50 |
| CloudWatch Dashboard | $0.10 |
| **Total** | **$16.29** |

*DynamoDB may need capacity increase for heavy load

---

## Monthly Cost Projection

| Scenario | Daily | Monthly (30 days) |
|----------|-------|-------------------|
| Idle | $0.12 | $3.60 |
| Light | $0.89 | $26.70 |
| Medium | $4.00 | $120.00 |
| Heavy | $16.29 | $488.70 |

---

## Cost Optimization Recommendations

### 1. **Glue Job Optimization** (Biggest Impact)
- Reduce workers from 2 to 1 for light workloads → saves 50%
- Use Glue Auto Scaling to scale workers based on data volume
- Consider Glue Flex (preemptible) for non-time-critical jobs → saves ~70%

### 2. **DynamoDB Optimization**
- Switch to On-Demand pricing for variable workloads
- Use provisioned for predictable, steady workloads
- Current config (1 RCU/WCU) is already minimal

### 3. **CloudWatch Optimization**
- Reduce log retention (currently 3 days - already minimal)
- Disable dashboard in dev ($3/month savings)
- Use log filters to reduce ingestion volume

### 4. **S3 Optimization**
- Lifecycle policies already in place (good!)
- Consider S3 Intelligent Tiering for output bucket if data accessed infrequently

### 5. **Step Functions Optimization**
- Standard workflow is required for Glue .sync
- Consider Express for future Lambda-only workflows (much cheaper)

---

## Free Tier Considerations

Many services have AWS Free Tier benefits (first 12 months):
- Lambda: 1M requests, 400,000 GB-seconds/month
- S3: 5 GB storage, 20,000 GET, 2,000 PUT
- DynamoDB: 25 GB storage, 25 RCU, 25 WCU
- SQS: 1M requests/month
- CloudWatch: 10 custom metrics, 5 GB log data ingestion

**With Free Tier, actual costs could be $0 for light workloads.**

---

## Notes

1. Prices are based on us-east-1 (N. Virginia) region as of January 2025
2. Actual costs may vary based on specific usage patterns
3. Data transfer costs not included (typically minimal within same region)
4. Taxes not included
5. Glue is by far the largest cost driver - optimize there first
