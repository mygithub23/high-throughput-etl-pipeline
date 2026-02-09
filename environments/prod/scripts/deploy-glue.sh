#!/bin/bash

# Deploy Production Glue Batch Job
# Optimized for parallel processing of 3.5-4.5 GB files

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"
SCRIPT_KEY="scripts/glue_batch_job.py"

echo -e "${GREEN}Deploying Production Glue Batch Job${NC}"
echo "Job: $JOB_NAME"
echo "Region: $REGION"
echo ""

# Confirmation
echo -e "${YELLOW}This will deploy PRODUCTION Glue with:${NC}"
echo " - Batch mode (glueetl)"
echo " - 30 concurrent jobs"
echo " - 20 workers per job (G.2X)"
echo " - Optimized for 100 files × 3.5-4.5 GB"
echo ""
read -p "Continue with production deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Upload script
echo -e "${YELLOW}Step 1: Uploading Glue script to S3...${NC}"
cd ../glue
aws s3 cp glue_batch_job.py "s3://${DEPLOYMENT_BUCKET}/${SCRIPT_KEY}" --region $REGION
echo "Script uploaded: s3://${DEPLOYMENT_BUCKET}/${SCRIPT_KEY}"
echo ""

# Get current job config
echo -e "${YELLOW}Step 2: Getting current job configuration...${NC}"
CURRENT_CONFIG=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json)

ROLE=$(echo "$CURRENT_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Role'])")
echo "Using role: $ROLE"
echo ""

# Update job
echo -e "${YELLOW}Step 3: Updating Glue job configuration...${NC}"

# Create job update JSON
cat > /tmp/glue-job-update.json <<EOF
{
  "Role": "$ROLE",
  "Command": {
    "Name": "glueetl",
    "ScriptLocation": "s3://${DEPLOYMENT_BUCKET}/${SCRIPT_KEY}",
    "PythonVersion": "3"
  },
  "DefaultArguments": {
    "--job-language": "python",
    "--job-bookmark-option": "job-bookmark-disable",
    "--enable-metrics": "true",
    "--enable-spark-ui": "true",
    "--enable-job-insights": "true",
    "--enable-auto-scaling": "true",
    "--enable-glue-datacatalog": "true",
    "--TempDir": "s3://${DEPLOYMENT_BUCKET}/temp/",
    "--MANIFEST_BUCKET": "ndjson-manifests-${AWS_ACCOUNT_ID}",
    "--OUTPUT_BUCKET": "ndjson-parquet-output-${AWS_ACCOUNT_ID}",
    "--COMPRESSION_TYPE": "snappy",
    "--conf": "spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true"
  },
  "MaxRetries": 1,
  "Timeout": 120,
  "MaxCapacity": null,
  "WorkerType": "G.2X",
  "NumberOfWorkers": 20,
  "GlueVersion": "4.0",
  "ExecutionProperty": {
    "MaxConcurrentRuns": 30
  }
}
EOF

aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update file:///tmp/glue-job-update.json \
  --region $REGION

echo "Job configuration updated"
echo ""

# Verify
echo -e "${YELLOW}Step 4: Verifying deployment...${NC}"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.{Name:Name,Command:Command.Name,Workers:NumberOfWorkers,Type:WorkerType,MaxConcurrent:ExecutionProperty.MaxConcurrentRuns,GlueVersion:GlueVersion}' \
  --output table

echo ""
echo -e "${GREEN}Production Glue Job Deployed Successfully!${NC}"
echo ""

echo "Configuration:"
echo " Mode: BATCH (glueetl)"
echo " Max Concurrent Runs: 30"
echo " Workers per Job: 20"
echo " Worker Type: G.2X (16GB RAM, 2 DPU)"
echo " Glue Version: 4.0"
echo " Timeout: 120 minutes"
echo " Auto-scaling: Enabled"
echo ""

echo "Expected Performance:"
echo " Files per manifest: 100"
echo " Processing time per job: 3-5 minutes"
echo " Capacity: 30 jobs × 100 files = 3,000 files in parallel"
echo " Daily throughput: ~338,000 files in 4-8 hours"
echo ""

echo "Cost Estimate:"
echo " Per hour: 30 jobs × 20 workers × 2 DPU × \$0.44 = \$528/hour"
echo " Per day (8 hours): ~\$4,224/day"
echo " Per month: ~\$126,720/month"
echo ""
echo -e "${YELLOW}Note: Cost will be lower with actual usage patterns.${NC}"
echo -e "${YELLOW}Recommend EMR migration for 70% cost savings!${NC}"
echo ""

echo "Next steps:"
echo " 1. Test with sample data: cd ../../dev/scripts && ./test-end-to-end.sh"
echo " 2. Monitor production: ./monitor-pipeline.sh"
echo " 3. Review costs: aws ce get-cost-and-usage --time-period ..."
echo ""

# Cleanup
rm -f /tmp/glue-job-update.json
