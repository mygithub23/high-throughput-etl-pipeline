# Quick Reference - Batch Mode Configuration

## 🎯 TL;DR

**All scripts updated to BATCH MODE (glueetl).**

- **Dev:** 50 files/manifest, 5 concurrent jobs, G.1X workers
- **Prod:** 100 files/manifest, 30 concurrent jobs, G.2X workers
- **Processing:** 338K files/day in 4-8 hours
- **Cost:** $88K-$140K/month (or $23K-$50K with EMR)

---

## 📁 File Structure

```
environments/
├── BATCH-MODE-UPDATE-SUMMARY.md  ⭐ Overview of all changes
├── CONFIG-REFERENCE.md           ⭐ Complete config details
├── DEPLOYMENT-CHECKLIST.md       ⭐ Step-by-step deployment
├── QUICK-REFERENCE.md            ⭐ This file
├── README.md                         General documentation
├── SETUP-COMPLETE.md                 Setup status
│
├── dev/                              Development environment
│   ├── lambda/
│   │   └── lambda_manifest_builder.py   DEBUG logging, 50 files/batch
│   ├── glue/
│   │   └── glue_batch_job.py            Batch mode, G.1X workers
│   └── scripts/
│       ├── check-dynamodb-files.sh      Check file tracking
│       ├── check-lambda-logs.sh         View Lambda logs
│       ├── check-sqs-queue.sh           Check SQS status
│       ├── diagnose-pipeline.sh         Full diagnostic
│       ├── fix-lambda-trigger.sh        Fix S3 trigger
│       ├── generate-test-data.sh        Create KB files
│       ├── run-glue-batch.sh            Manual job trigger
│       ├── test-end-to-end.sh           End-to-end test
│       └── upload-test-data.sh          Upload to S3
│
└── prod/                              Production environment
    ├── lambda/
    │   └── lambda_manifest_builder.py   INFO logging, 100 files/batch
    ├── glue/
    │   └── glue_batch_job.py            Batch mode, G.2X workers
    └── scripts/
        ├── check-glue-errors.sh         Analyze failures
        ├── check-glue-logs.sh           View Glue logs
        ├── deploy-glue.sh               Deploy Glue job
        ├── deploy-lambda.sh             Deploy Lambda
        ├── generate-test-data.sh        Create 3.5-4GB files
        ├── monitor-pipeline.sh          Real-time monitoring
        ├── run-glue-batch.sh            Manual job trigger
        ├── test-production-scale.sh     Progressive testing (4 phases)
        ├── update-batch-config.sh       Update configuration
        └── upload-test-data.sh          Upload to S3
```

---

## ⚡ Quick Commands

### Development

```bash
# Deploy
cd environments/dev/lambda
zip -r lambda.zip lambda_manifest_builder.py
aws lambda update-function-code --function-name ndjson-parquet-sqs-manifest-builder --zip-file fileb://lambda.zip

# Test
cd ../scripts
./generate-test-data.sh 10 100
./upload-test-data.sh
./check-lambda-logs.sh

# Monitor
./diagnose-pipeline.sh
```

### Production

```bash
# Deploy
cd environments/prod/scripts
./deploy-lambda.sh
./deploy-glue.sh

# Test (Progressive)
./test-production-scale.sh  # Phase 1: 10 files
./test-production-scale.sh  # Phase 2: 100 files
./test-production-scale.sh  # Phase 3: 1,000 files
./test-production-scale.sh  # Phase 4: 10,000 files

# Monitor
./monitor-pipeline.sh
watch -n 30 './monitor-pipeline.sh'

# Check Errors
./check-glue-errors.sh

# Update Config
./update-batch-config.sh
```

---

## 🔧 Key Configuration

### Lambda (Prod)
```bash
MAX_FILES_PER_MANIFEST=100     # 100 files per batch
MAX_BATCH_SIZE_GB=500          # 450GB max (safety)
EXPECTED_FILE_SIZE_MB=3500     # 3.5GB typical
SIZE_TOLERANCE_PERCENT=20      # Accept 3.5-4.5GB
```

### Glue (Prod)
```bash
Command: glueetl               # BATCH mode
WorkerType: G.2X               # 16GB RAM
NumberOfWorkers: 20            # 20 workers per job
MaxConcurrentRuns: 30          # 30 jobs in parallel
```

---

## 📊 Performance

### Capacity
- **Parallel:** 3,000 files (30 jobs × 100 files)
- **Workers:** 600 total (30 jobs × 20 workers)
- **Throughput:** 36,000 files/hour peak

### For 338K Files/Day
- **Manifests:** 3,380 (338,000 ÷ 100)
- **Time:** 4-8 hours
- **Success rate:** >98%

---

## 💰 Costs

### Current (Batch)
```
Glue:     $75,000 - $105,000/month
Lambda:   $600/month
S3:       $12,000 - $35,000/month
DynamoDB: $450/month
-----------------------------------
Total:    $88,000 - $140,000/month
```

### With EMR (Recommended)
```
EMR:      $10,000 - $15,000/month  ✅ 70% savings!
Lambda:   $600/month
S3:       $12,000 - $35,000/month
DynamoDB: $450/month
-----------------------------------
Total:    $23,000 - $50,000/month  ✅
```

---

## 🚀 Deployment Steps

1. **Deploy Dev**
   ```bash
   cd environments/dev/lambda
   # Package and deploy Lambda
   cd ../scripts
   ./generate-test-data.sh 10 100
   ./upload-test-data.sh
   ```

2. **Test Dev**
   ```bash
   ./check-lambda-logs.sh
   ./check-dynamodb-files.sh
   ./diagnose-pipeline.sh
   ```

3. **Deploy Prod**
   ```bash
   cd environments/prod/scripts
   ./deploy-lambda.sh
   ./deploy-glue.sh
   ```

4. **Test Prod (Progressive)**
   ```bash
   ./test-production-scale.sh  # Phase 1: 10 files
   # Verify success, then continue
   ./test-production-scale.sh  # Phase 2: 100 files
   ./test-production-scale.sh  # Phase 3: 1,000 files
   ./test-production-scale.sh  # Phase 4: 10,000 files
   ```

5. **Monitor**
   ```bash
   ./monitor-pipeline.sh
   ./check-glue-errors.sh
   ```

---

## 🔍 Verification

### Check Lambda Config
```bash
aws lambda get-function-configuration \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --query 'Environment.Variables.MAX_FILES_PER_MANIFEST'

# Should output: "100" (prod) or "50" (dev)
```

### Check Glue Config
```bash
aws glue get-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --query 'Job.Command.Name'

# Should output: "glueetl" (NOT "gluestreaming")
```

### Check Batch Processing
```bash
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --max-results 5 \
  --query 'JobRuns[*].{State:JobRunState,Duration:ExecutionTime}'

# Jobs should complete in 3-10 minutes each
```

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| [BATCH-MODE-UPDATE-SUMMARY.md](BATCH-MODE-UPDATE-SUMMARY.md) | Overview of changes |
| [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) | Complete configuration |
| [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) | Deployment guide |
| [README.md](README.md) | General documentation |
| [SETUP-COMPLETE.md](SETUP-COMPLETE.md) | Setup status |

**External:**
- [SCALABILITY-ANALYSIS.md](../SCALABILITY-ANALYSIS.md) - Architecture analysis
- [ARCHITECTURE-OPTIONS.md](../ARCHITECTURE-OPTIONS.md) - 4 options comparison
- [STREAMING-VS-BATCH.md](../STREAMING-VS-BATCH.md) - Why batch is better

---

## 🆘 Troubleshooting

### Jobs not starting?
```bash
# Check Glue config
aws glue get-job --job-name ndjson-parquet-sqs-streaming-processor

# Manually trigger
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --arguments='--manifest_path=s3://...'
```

### Jobs failing?
```bash
cd environments/prod/scripts
./check-glue-errors.sh
```

### High costs?
```bash
./monitor-pipeline.sh  # Check cost estimate
./update-batch-config.sh  # Reduce concurrent jobs
```

### Slow processing?
```bash
./update-batch-config.sh  # Increase concurrent jobs
```

---

## ✅ Checklist

Before deployment:
- [ ] Read [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md)
- [ ] Verify Lambda config shows `MAX_FILES_PER_MANIFEST`
- [ ] Verify Glue config shows `Command.Name = "glueetl"`
- [ ] Test in dev with small files
- [ ] Set up billing alarms

After deployment:
- [ ] Phase 1 test (10 files) passes
- [ ] Phase 2 test (100 files) passes
- [ ] Phase 3 test (1,000 files) passes
- [ ] Monitor shows healthy status
- [ ] Costs align with estimates

---

## 🎯 Success Criteria

**Deployment succeeds when:**
- All Glue jobs show `Command.Name = "glueetl"`
- Manifests contain ~100 files each (prod) or ~50 (dev)
- Multiple jobs run concurrently (30 prod, 5 dev)
- Processing completes in 4-8 hours for 338K files
- Success rate >98%
- Costs within expected range

---

## 📞 Need Help?

1. Check [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) for configuration details
2. Run diagnostic scripts: `./diagnose-pipeline.sh`
3. Check errors: `./check-glue-errors.sh`
4. Review [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md)

---

**Everything is updated and ready to deploy!** 🚀

Follow [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) for detailed steps.
