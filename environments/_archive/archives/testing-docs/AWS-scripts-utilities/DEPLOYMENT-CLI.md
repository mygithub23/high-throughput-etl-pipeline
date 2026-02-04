# AWS CLI Deployment Guide

This guide provides step-by-step commands for deploying the NDJSON to Parquet pipeline using the AWS CLI.

## Prerequisites

- AWS CLI installed and configured
- Bash shell (Linux, macOS, or WSL/Git Bash on Windows)
- Appropriate AWS permissions

## Quick Deploy (Automated)

```bash
cd cloudformation
chmod +x deploy.sh
./deploy.sh prod  # or dev
```

For manual deployment, continue below.

---

## Manual Deployment Steps

### Step 1: Set Environment Variables

```bash
# Set environment (dev or prod)
export ENVIRONMENT=prod  # or dev

# Get AWS account ID
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Set AWS region
export AWS_REGION=us-east-1  # or your preferred region

# Set names
export STACK_NAME="ndjson-parquet-pipeline-${ENVIRONMENT}"
export TEMPLATES_BUCKET="${ACCOUNT_ID}-cloudformation-templates"
export SCRIPTS_BUCKET="ndjson-glue-scripts-${ACCOUNT_ID}-${ENVIRONMENT}"

# Alert email (production only)
export ALERT_EMAIL="ops-team@company.com"  # Change this!

echo "Environment: $ENVIRONMENT"
echo "Account ID: $ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "Stack Name: $STACK_NAME"
```

---

### Step 2: Create S3 Bucket for CloudFormation Templates

```bash
# Create bucket
aws s3 mb s3://${TEMPLATES_BUCKET} --region ${AWS_REGION}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${TEMPLATES_BUCKET} \
  --versioning-configuration Status=Enabled \
  --region ${AWS_REGION}

# Block public access
aws s3api put-public-access-block \
  --bucket ${TEMPLATES_BUCKET} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region ${AWS_REGION}

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${TEMPLATES_BUCKET} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }' \
  --region ${AWS_REGION}

echo "✓ Templates bucket created: ${TEMPLATES_BUCKET}"
```

---

### Step 3: Upload CloudFormation Templates

```bash
# Upload nested stack templates
aws s3 cp s3-buckets.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

aws s3 cp dynamodb-tables.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

aws s3 cp iam-roles.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

aws s3 cp lambda-function.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

aws s3 cp glue-job.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

aws s3 cp monitoring.yaml \
  s3://${TEMPLATES_BUCKET}/ndjson-parquet-pipeline/ \
  --region ${AWS_REGION}

echo "✓ All templates uploaded"
```

---

### Step 4: Validate CloudFormation Templates

```bash
# Validate main template
aws cloudformation validate-template \
  --template-body file://main.yaml \
  --region ${AWS_REGION}

# Validate nested templates
for template in s3-buckets dynamodb-tables iam-roles lambda-function glue-job monitoring; do
  echo "Validating ${template}.yaml..."
  aws cloudformation validate-template \
    --template-body file://${template}.yaml \
    --region ${AWS_REGION} > /dev/null && echo "  ✓ Valid"
done

echo "✓ All templates validated successfully"
```

---

### Step 5: Create S3 Bucket for Glue Scripts

```bash
# Create scripts bucket
aws s3 mb s3://${SCRIPTS_BUCKET} --region ${AWS_REGION}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${SCRIPTS_BUCKET} \
  --versioning-configuration Status=Enabled \
  --region ${AWS_REGION}

# Block public access
aws s3api put-public-access-block \
  --bucket ${SCRIPTS_BUCKET} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region ${AWS_REGION}

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket ${SCRIPTS_BUCKET} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }' \
  --region ${AWS_REGION}

echo "✓ Scripts bucket created: ${SCRIPTS_BUCKET}"
```

---

### Step 6: Package and Upload Lambda Code

```bash
# Navigate to Lambda code directory
cd ../environments/${ENVIRONMENT}/lambda

# Create ZIP package
zip -r lambda_manifest_builder.zip lambda_manifest_builder.py

# Upload to S3
aws s3 cp lambda_manifest_builder.zip \
  s3://${SCRIPTS_BUCKET}/lambda/${ENVIRONMENT}/ \
  --region ${AWS_REGION}

# Clean up local ZIP
rm lambda_manifest_builder.zip

# Return to cloudformation directory
cd ../../../cloudformation

echo "✓ Lambda code packaged and uploaded"
```

---

### Step 7: Upload Glue Script

```bash
# Upload Glue script
aws s3 cp ../environments/${ENVIRONMENT}/glue/glue_batch_job.py \
  s3://${SCRIPTS_BUCKET}/glue/${ENVIRONMENT}/ \
  --region ${AWS_REGION}

echo "✓ Glue script uploaded"
```

---

### Step 8: Deploy CloudFormation Stack

#### Option A: Using Parameters File (Recommended)

```bash
# Create or update parameters file
# Edit parameters-${ENVIRONMENT}.json to set AlertEmail

# Deploy stack
aws cloudformation create-stack \
  --stack-name ${STACK_NAME} \
  --template-body file://main.yaml \
  --parameters file://parameters-${ENVIRONMENT}.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --tags \
    Key=Environment,Value=${ENVIRONMENT} \
    Key=Project,Value=ndjson-parquet-pipeline \
    Key=ManagedBy,Value=CloudFormation

echo "✓ Stack creation initiated: ${STACK_NAME}"
```

#### Option B: Inline Parameters (Development Example)

```bash
aws cloudformation create-stack \
  --stack-name ${STACK_NAME} \
  --template-body file://main.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=LambdaMemorySize,ParameterValue=512 \
    ParameterKey=LambdaTimeout,ParameterValue=180 \
    ParameterKey=LambdaReservedConcurrency,ParameterValue=5 \
    ParameterKey=GlueVersion,ParameterValue=4.0 \
    ParameterKey=GlueWorkerType,ParameterValue=G.1X \
    ParameterKey=GlueNumberOfWorkers,ParameterValue=10 \
    ParameterKey=GlueMaxConcurrentRuns,ParameterValue=5 \
    ParameterKey=GlueTimeout,ParameterValue=120 \
    ParameterKey=GlueMaxRetries,ParameterValue=1 \
    ParameterKey=MaxFilesPerManifest,ParameterValue=50 \
    ParameterKey=MaxBatchSizeGB,ParameterValue=200 \
    ParameterKey=ExpectedFileSizeMB,ParameterValue=3500 \
    ParameterKey=SizeTolerancePercent,ParameterValue=50 \
    ParameterKey=DynamoDBTTLDays,ParameterValue=3 \
    ParameterKey=LogRetentionDays,ParameterValue=3 \
    ParameterKey=AlertEmail,ParameterValue="" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --tags \
    Key=Environment,Value=dev \
    Key=Project,Value=ndjson-parquet-pipeline
```

#### Option C: Inline Parameters (Production Example)

```bash
aws cloudformation create-stack \
  --stack-name ${STACK_NAME} \
  --template-body file://main.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=prod \
    ParameterKey=LambdaMemorySize,ParameterValue=1024 \
    ParameterKey=LambdaTimeout,ParameterValue=300 \
    ParameterKey=LambdaReservedConcurrency,ParameterValue=10 \
    ParameterKey=GlueVersion,ParameterValue=4.0 \
    ParameterKey=GlueWorkerType,ParameterValue=G.2X \
    ParameterKey=GlueNumberOfWorkers,ParameterValue=20 \
    ParameterKey=GlueMaxConcurrentRuns,ParameterValue=30 \
    ParameterKey=GlueTimeout,ParameterValue=120 \
    ParameterKey=GlueMaxRetries,ParameterValue=2 \
    ParameterKey=MaxFilesPerManifest,ParameterValue=100 \
    ParameterKey=MaxBatchSizeGB,ParameterValue=500 \
    ParameterKey=ExpectedFileSizeMB,ParameterValue=3500 \
    ParameterKey=SizeTolerancePercent,ParameterValue=20 \
    ParameterKey=DynamoDBTTLDays,ParameterValue=7 \
    ParameterKey=LogRetentionDays,ParameterValue=7 \
    ParameterKey=AlertEmail,ParameterValue=${ALERT_EMAIL} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --tags \
    Key=Environment,Value=prod \
    Key=Project,Value=ndjson-parquet-pipeline \
    Key=CostCenter,Value=DataEngineering
```

---

### Step 9: Wait for Stack Creation

```bash
# Wait for stack creation to complete (10-15 minutes)
echo "Waiting for stack creation... This may take 10-15 minutes."

aws cloudformation wait stack-create-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

if [ $? -eq 0 ]; then
  echo "✓ Stack created successfully!"
else
  echo "✗ Stack creation failed. Checking events..."
  aws cloudformation describe-stack-events \
    --stack-name ${STACK_NAME} \
    --region ${AWS_REGION} \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output table
  exit 1
fi
```

---

### Step 10: View Stack Outputs

```bash
# Display all stack outputs
aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

# Save outputs to variables
export INPUT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`InputBucket`].OutputValue' \
  --output text)

export OUTPUT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`OutputBucket`].OutputValue' \
  --output text)

export LAMBDA_FUNCTION=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
  --output text)

export GLUE_JOB=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`GlueJobName`].OutputValue' \
  --output text)

echo "Input Bucket: ${INPUT_BUCKET}"
echo "Output Bucket: ${OUTPUT_BUCKET}"
echo "Lambda Function: ${LAMBDA_FUNCTION}"
echo "Glue Job: ${GLUE_JOB}"
```

---

### Step 11: Subscribe to SNS Alerts (Production Only)

```bash
# Get SNS topic ARNs
export CRITICAL_TOPIC=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`CriticalAlertsTopicArn`].OutputValue' \
  --output text)

export WARNING_TOPIC=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`WarningAlertsTopicArn`].OutputValue' \
  --output text)

# Subscribe to critical alerts (if not already subscribed via parameters)
if [ "$ENVIRONMENT" = "prod" ]; then
  # Subscribe additional email
  aws sns subscribe \
    --topic-arn ${CRITICAL_TOPIC} \
    --protocol email \
    --notification-endpoint ${ALERT_EMAIL} \
    --region ${AWS_REGION}

  # Subscribe to warning alerts
  aws sns subscribe \
    --topic-arn ${WARNING_TOPIC} \
    --protocol email \
    --notification-endpoint ${ALERT_EMAIL} \
    --region ${AWS_REGION}

  echo "✓ SNS subscription requests sent. Check email to confirm!"
fi
```

---

### Step 12: List All Subscriptions

```bash
# List critical alerts subscriptions
echo "Critical Alerts Subscriptions:"
aws sns list-subscriptions-by-topic \
  --topic-arn ${CRITICAL_TOPIC} \
  --region ${AWS_REGION} \
  --query 'Subscriptions[*].[Protocol,Endpoint,SubscriptionArn]' \
  --output table

# List warning alerts subscriptions
echo ""
echo "Warning Alerts Subscriptions:"
aws sns list-subscriptions-by-topic \
  --topic-arn ${WARNING_TOPIC} \
  --region ${AWS_REGION} \
  --query 'Subscriptions[*].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

---

### Step 13: Verify Deployment

#### Check Lambda Function

```bash
# Get Lambda function details
aws lambda get-function \
  --function-name ${LAMBDA_FUNCTION} \
  --region ${AWS_REGION} \
  --query '{Name:Configuration.FunctionName,Runtime:Configuration.Runtime,Memory:Configuration.MemorySize,Timeout:Configuration.Timeout}' \
  --output table

# List environment variables
aws lambda get-function-configuration \
  --function-name ${LAMBDA_FUNCTION} \
  --region ${AWS_REGION} \
  --query 'Environment.Variables' \
  --output table
```

#### Check Glue Job

```bash
# Get Glue job details
aws glue get-job \
  --job-name ${GLUE_JOB} \
  --region ${AWS_REGION} \
  --query 'Job.{Name:Name,Role:Role,WorkerType:WorkerType,Workers:NumberOfWorkers,GlueVersion:GlueVersion}' \
  --output table
```

#### Check DynamoDB Tables

```bash
# List DynamoDB tables
aws dynamodb list-tables \
  --region ${AWS_REGION} \
  --query "TableNames[?contains(@, 'ndjson-parquet')]" \
  --output table

# Get file tracking table details
aws dynamodb describe-table \
  --table-name ndjson-parquet-sqs-file-tracking-${ENVIRONMENT} \
  --region ${AWS_REGION} \
  --query 'Table.{Name:TableName,Status:TableStatus,ItemCount:ItemCount,SizeBytes:TableSizeBytes}' \
  --output table
```

#### Check CloudWatch Alarms (Production)

```bash
if [ "$ENVIRONMENT" = "prod" ]; then
  aws cloudwatch describe-alarms \
    --alarm-name-prefix ${ENVIRONMENT}- \
    --region ${AWS_REGION} \
    --query 'MetricAlarms[*].[AlarmName,StateValue,ActionsEnabled]' \
    --output table
fi
```

---

### Step 14: Test the Pipeline

#### Create Test File

```bash
# Create test NDJSON file
cat > test.ndjson <<EOF
{"id": 1, "name": "test1", "value": 100, "timestamp": "2024-12-28T10:00:00Z"}
{"id": 2, "name": "test2", "value": 200, "timestamp": "2024-12-28T10:00:01Z"}
{"id": 3, "name": "test3", "value": 300, "timestamp": "2024-12-28T10:00:02Z"}
EOF

echo "✓ Test file created"
```

#### Upload Test File

```bash
# Upload to input bucket
aws s3 cp test.ndjson s3://${INPUT_BUCKET}/ --region ${AWS_REGION}

echo "✓ Test file uploaded to ${INPUT_BUCKET}"
```

#### Monitor Lambda Execution

```bash
# Wait a moment for Lambda to execute
sleep 5

# Get latest Lambda log stream
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name /aws/lambda/${LAMBDA_FUNCTION} \
  --region ${AWS_REGION} \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --query 'logStreams[0].logStreamName' \
  --output text)

# View logs
echo "Lambda Logs:"
aws logs get-log-events \
  --log-group-name /aws/lambda/${LAMBDA_FUNCTION} \
  --log-stream-name ${LOG_STREAM} \
  --region ${AWS_REGION} \
  --query 'events[*].message' \
  --output text
```

#### Check DynamoDB for File Record

```bash
# Query file tracking table
aws dynamodb scan \
  --table-name ndjson-parquet-sqs-file-tracking-${ENVIRONMENT} \
  --region ${AWS_REGION} \
  --filter-expression "contains(file_key, :filename)" \
  --expression-attribute-values '{":filename":{"S":"test.ndjson"}}' \
  --query 'Items[*].{FileKey:file_key.S,Status:status.S,Size:file_size_mb.N}' \
  --output table
```

---

## Common Operations

### Update Stack

```bash
# Update stack with new parameters
aws cloudformation update-stack \
  --stack-name ${STACK_NAME} \
  --template-body file://main.yaml \
  --parameters file://parameters-${ENVIRONMENT}.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION}

# Wait for update
aws cloudformation wait stack-update-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}
```

### View Stack Events

```bash
# View all events
aws cloudformation describe-stack-events \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]' \
  --output table

# View only failed events
aws cloudformation describe-stack-events \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatusReason]' \
  --output table
```

### Monitor Lambda Function

```bash
# Tail Lambda logs in real-time
aws logs tail /aws/lambda/${LAMBDA_FUNCTION} \
  --follow \
  --region ${AWS_REGION}
```

### Monitor Glue Job

```bash
# List recent Glue job runs
aws glue get-job-runs \
  --job-name ${GLUE_JOB} \
  --region ${AWS_REGION} \
  --max-results 10 \
  --query 'JobRuns[*].[Id,JobRunState,StartedOn,ExecutionTime]' \
  --output table

# Get specific job run details
JOB_RUN_ID="jr_..." # Replace with actual run ID
aws glue get-job-run \
  --job-name ${GLUE_JOB} \
  --run-id ${JOB_RUN_ID} \
  --region ${AWS_REGION}
```

### Test SNS Notification

```bash
# Send test message to critical alerts
aws sns publish \
  --topic-arn ${CRITICAL_TOPIC} \
  --subject "Test Alert - NDJSON Parquet Pipeline" \
  --message "This is a test notification from the ${ENVIRONMENT} environment." \
  --region ${AWS_REGION}

echo "✓ Test notification sent. Check your email."
```

### View CloudWatch Dashboard

```bash
# Get dashboard URL
DASHBOARD_URL=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
  --output text)

echo "Dashboard URL: ${DASHBOARD_URL}"

# Or open in browser (macOS)
# open "${DASHBOARD_URL}"

# Or open in browser (Linux)
# xdg-open "${DASHBOARD_URL}"

# Or open in browser (Windows WSL)
# cmd.exe /c start "${DASHBOARD_URL}"
```

---

## Delete Stack (Clean Up)

**WARNING:** This will delete all resources and data!

```bash
# Step 1: Empty all S3 buckets
echo "Emptying S3 buckets..."

for bucket in ${INPUT_BUCKET} \
              ndjson-manifests-${ACCOUNT_ID}-${ENVIRONMENT} \
              ${OUTPUT_BUCKET} \
              ndjson-quarantine-${ACCOUNT_ID}-${ENVIRONMENT} \
              ${SCRIPTS_BUCKET}; do
  echo "Emptying ${bucket}..."
  aws s3 rm s3://${bucket} --recursive --region ${AWS_REGION}
done

# Step 2: Delete CloudFormation stack
echo "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

# Step 3: Wait for deletion
echo "Waiting for stack deletion... This may take 5-10 minutes."
aws cloudformation wait stack-delete-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

if [ $? -eq 0 ]; then
  echo "✓ Stack deleted successfully!"
else
  echo "✗ Stack deletion failed or timed out. Check CloudFormation console."
fi

# Step 4: Delete templates bucket (optional)
echo "Delete templates bucket? (y/n)"
read -r response
if [ "$response" = "y" ]; then
  aws s3 rm s3://${TEMPLATES_BUCKET} --recursive --region ${AWS_REGION}
  aws s3 rb s3://${TEMPLATES_BUCKET} --region ${AWS_REGION}
  echo "✓ Templates bucket deleted"
fi
```

---

## Troubleshooting Commands

### Check Stack Status

```bash
aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].StackStatus' \
  --output text
```

### Get Stack Resource Details

```bash
# List all resources
aws cloudformation list-stack-resources \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'StackResourceSummaries[*].[LogicalResourceId,ResourceType,ResourceStatus]' \
  --output table

# Get specific resource
aws cloudformation describe-stack-resource \
  --stack-name ${STACK_NAME} \
  --logical-resource-id LambdaStack \
  --region ${AWS_REGION}
```

### Check Lambda Errors

```bash
# Get Lambda error metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=${LAMBDA_FUNCTION} \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region ${AWS_REGION}
```

### Check DynamoDB Throttles

```bash
# Get DynamoDB throttle metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name WriteThrottleEvents \
  --dimensions Name=TableName,Value=ndjson-parquet-sqs-file-tracking-${ENVIRONMENT} \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region ${AWS_REGION}
```

---

## Advanced: Multi-Environment Deployment

Deploy both dev and prod in sequence:

```bash
#!/bin/bash

for ENV in dev prod; do
  echo "========================================="
  echo "Deploying ${ENV} environment..."
  echo "========================================="

  export ENVIRONMENT=${ENV}
  export STACK_NAME="ndjson-parquet-pipeline-${ENV}"

  # Deploy stack
  aws cloudformation create-stack \
    --stack-name ${STACK_NAME} \
    --template-body file://main.yaml \
    --parameters file://parameters-${ENV}.json \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${AWS_REGION} \
    --tags Key=Environment,Value=${ENV} Key=Project,Value=ndjson-parquet-pipeline

  # Wait for completion
  aws cloudformation wait stack-create-complete \
    --stack-name ${STACK_NAME} \
    --region ${AWS_REGION}

  echo "✓ ${ENV} deployment complete"
  echo ""
done

echo "All environments deployed successfully!"
```

---

## Summary

You've successfully deployed the NDJSON to Parquet pipeline using AWS CLI!

**What you created:**
- ✅ 5 S3 buckets
- ✅ 2 DynamoDB tables
- ✅ 1 Lambda function
- ✅ 1 Glue job
- ✅ IAM roles and policies
- ✅ 2 SNS topics (production)
- ✅ 10 CloudWatch alarms (production)
- ✅ 1 CloudWatch dashboard (production)

**Next Steps:**
- Monitor CloudWatch logs
- Review CloudWatch dashboard
- Set up additional email alerts
- Test with real data
- Optimize based on usage patterns

For console deployment, see [DEPLOYMENT-CONSOLE.md](DEPLOYMENT-CONSOLE.md)
