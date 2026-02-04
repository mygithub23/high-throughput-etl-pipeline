# NDJSON to Parquet Pipeline - Environments

This directory contains development and production versions of the pipeline code.

## Directory Structure

```
environments/
├── dev/                          # Development environment
│   ├── lambda/                   # Lambda functions with extensive logging
│   │   └── lambda_manifest_builder.py
│   ├── glue/                     # Glue jobs with debug features
│   │   └── glue_streaming_job.py
│   └── scripts/                  # Testing and debugging scripts
│       ├── upload-test-data.sh
│       ├── check-lambda-logs.sh
│       ├── check-dynamodb-files.sh
│       ├── check-sqs-queue.sh
│       ├── diagnose-pipeline.sh
│       ├── run-glue-batch.sh
│       └── test-end-to-end.sh
│
├── prod/                         # Production environment
│   ├── lambda/                   # Optimized Lambda functions
│   │   └── lambda_manifest_builder.py
│   ├── glue/                     # Production Glue jobs
│   │   └── glue_streaming_job.py
│   └── scripts/                  # Production deployment scripts
│       ├── deploy-lambda.sh
│       ├── deploy-glue.sh
│       ├── update-batch-size.sh
│       └── monitor-pipeline.sh
│
└── README.md                     # This file
```

## Development Environment

### Features
- **Extensive Logging**: DEBUG level with detailed object dumps
- **Try-Catch Blocks**: Comprehensive error handling with stack traces
- **Object Introspection**: Logs request/response objects
- **Testing Scripts**: Full suite of diagnostic and testing tools
- **Enhanced Metrics**: Detailed performance and execution metrics

### Lambda Development Features
```python
- DEBUG level logging with emoji markers (🚀, ✓, ✗, ⚠️)
- Full event and context logging
- Try-catch blocks at every level
- Stack traces for all exceptions
- Object dumps with json.dumps(obj, indent=2, default=str)
- Detailed progress logging for each step
- Lock acquisition/release logging
- File-by-file processing logs
- Batch creation details
```

### Usage
```bash
# Deploy dev Lambda
cd environments/dev/lambda
zip -r lambda.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://lambda.zip \
  --region us-east-1

# Deploy dev Glue job
cd environments/dev/glue
aws s3 cp glue_batch_job.py s3://ndjson-parquet-deployment-<ACCOUNT>/scripts/

# Run tests
cd environments/dev/scripts
./test-end-to-end.sh
```

## Production Environment

### Features
- **Minimal Logging**: INFO level only for critical events
- **Optimized Performance**: No unnecessary logging or debugging code
- **Error Handling**: Production-grade error handling without verbose traces
- **Streamlined Code**: Removed all debug features for best performance
- **Clean Logs**: Only essential information logged

### Lambda Production Features
```python
- INFO level logging only
- No object dumps or detailed tracing
- Minimal error messages
- Optimized for performance
- Clean, concise log output
- Summary-level metrics only
```

### Usage
```bash
# Deploy prod Lambda
cd environments/prod/lambda
zip -r lambda.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://lambda.zip \
  --region us-east-1

# Deploy prod Glue job
cd environments/prod/glue
aws s3 cp glue_streaming_job.py s3://ndjson-parquet-deployment-<ACCOUNT>/scripts/

# Monitor production
cd environments/prod/scripts
./monitor-pipeline.sh
```

## Key Differences: Dev vs Prod

### Lambda Function

| Feature | Development | Production |
|---------|-------------|------------|
| Log Level | DEBUG | INFO |
| Event Logging | Full event dump | Minimal |
| Error Traces | Full stack traces | Error message only |
| Object Dumps | Yes, with indent | No |
| Progress Logs | Every step | Summary only |
| Emoji Markers | Yes (🚀, ✓, ✗) | No |
| Try-Catch Scope | Every operation | Critical paths only |

### Glue Job

| Feature | Development | Production |
|---------|-------------|------------|
| Log Level | DEBUG | INFO |
| Data Samples | First 10 rows | None |
| Performance Metrics | Detailed | Summary only |
| Error Handling | Verbose | Concise |
| Schema Logging | Full schema dump | None |

### Scripts

| Development | Production |
|-------------|------------|
| upload-test-data.sh | deploy-lambda.sh |
| check-lambda-logs.sh | deploy-glue.sh |
| check-dynamodb-files.sh | update-batch-size.sh |
| check-sqs-queue.sh | monitor-pipeline.sh |
| diagnose-pipeline.sh | - |
| test-end-to-end.sh | - |

## Configuration

### Environment Variables

Both environments use the same environment variables:

```bash
MANIFEST_BUCKET=ndjson-manifests-<ACCOUNT>
TRACKING_TABLE=ndjson-parquet-sqs-file-tracking
METRICS_TABLE=ndjson-parquet-sqs-metrics
GLUE_JOB_NAME=ndjson-parquet-sqs-streaming-processor
QUARANTINE_BUCKET=ndjson-quarantine-<ACCOUNT>
LOCK_TABLE=ndjson-parquet-sqs-file-tracking
LOCK_TTL_SECONDS=300
```

### Development-Specific
```bash
MAX_BATCH_SIZE_GB=0.001          # 1MB for testing
EXPECTED_FILE_SIZE_MB=3.5
SIZE_TOLERANCE_PERCENT=20
```

### Production-Specific
```bash
MAX_BATCH_SIZE_GB=1.0            # 1GB for production
EXPECTED_FILE_SIZE_MB=3.5
SIZE_TOLERANCE_PERCENT=10
```

## Testing Workflow

### Development Testing
```bash
1. Upload test data
   ./environments/dev/scripts/upload-test-data.sh

2. Check Lambda processing
   ./environments/dev/scripts/check-lambda-logs.sh
   ./environments/dev/scripts/check-dynamodb-files.sh

3. Verify manifests created
   aws s3 ls s3://ndjson-manifests-<ACCOUNT>/manifests/ --recursive

4. Run Glue job
   ./environments/dev/scripts/run-glue-batch.sh

5. Verify Parquet output
   aws s3 ls s3://ndjson-parquet-output-<ACCOUNT>/ --recursive

6. Run full end-to-end test
   ./environments/dev/scripts/test-end-to-end.sh
```

### Production Deployment
```bash
1. Test in dev first!

2. Deploy Lambda
   ./environments/prod/scripts/deploy-lambda.sh

3. Deploy Glue job
   ./environments/prod/scripts/deploy-glue.sh

4. Update configuration
   ./environments/prod/scripts/update-batch-size.sh

5. Monitor
   ./environments/prod/scripts/monitor-pipeline.sh
```

## Cost Optimization

### Development
- Small batch size (0.001 GB) for quick testing
- 2 Glue workers (G.1X) - $0.88/hour
- Jobs run on-demand only
- Test with small datasets

### Production
- Optimal batch size (1.0 GB) for efficiency
- 2 Glue workers (G.1X) - $0.88/hour
- Jobs triggered by manifests
- Auto-scaling if needed

## Troubleshooting

### Development
Use the comprehensive diagnostic script:
```bash
./environments/dev/scripts/diagnose-pipeline.sh
```

### Production
Check monitoring:
```bash
./environments/prod/scripts/monitor-pipeline.sh
```

## Migration Path

### Dev → Prod
1. Test thoroughly in dev environment
2. Review logs for any warnings
3. Validate data quality in Parquet output
4. Update batch size from 0.001 to 1.0 GB
5. Deploy prod Lambda and Glue code
6. Monitor first production run closely
7. Gradually increase load

## Best Practices

### Development
- Always test locally first
- Use small datasets
- Check logs after every change
- Verify DynamoDB entries
- Inspect manifest files
- Review Parquet schema

### Production
- Deploy during low-traffic periods
- Monitor CloudWatch metrics
- Set up alarms for errors
- Regular cost reviews
- Backup configurations
- Document all changes

## Support

For issues:
1. Check dev environment logs first
2. Run diagnostic scripts
3. Review this README
4. Check CloudWatch logs
5. Verify IAM permissions

## Version History

- v1.0.0 - Initial release
- v1.1.0 - Added distributed locking, pagination
- v1.2.0-dev - Development version with extensive logging
- v1.2.0-prod - Production version with optimization
