# Metrics Collector Deployment Checklist
## Step-by-Step Guide to Get Real Production Data

---

## Overview

You'll deploy a lightweight metrics collector Lambda that runs **in parallel** with your existing pipeline. It won't interfere with your current system - it only observes and records file metadata.

**Timeline:**
- Setup: 15-30 minutes
- Data collection: 24-48 hours (recommended)
- Analysis: 5 minutes
- Decision: Based on real data

---

## Pre-Deployment Checklist

### ☐ 1. Verify AWS CLI Access
```bash
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

### ☐ 2. Confirm Source Bucket Name
```bash
# List your S3 buckets to confirm the source bucket
aws s3 ls

# Verify bucket exists and you have access
aws s3 ls s3://YOUR-SOURCE-BUCKET-NAME/ --max-items 5
```

**Note down your source bucket name:** ________________

### ☐ 3. Choose AWS Region
**Region where your pipeline runs:** ________________

Example: `us-east-1`, `us-west-2`, etc.

---

## Step 1: Create DynamoDB Metrics Table (5 minutes)

### Option A: Using AWS CLI

```bash
# Create the metrics table
aws dynamodb create-table \
    --table-name s3-file-metrics \
    --attribute-definitions \
        AttributeName=date_hour,AttributeType=S \
        AttributeName=timestamp,AttributeType=N \
    --key-schema \
        AttributeName=date_hour,KeyType=HASH \
        AttributeName=timestamp,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region YOUR-REGION \
    --tags Key=Purpose,Value=ETLMetrics Key=Project,Value=YourProjectName

# Wait for table to be active
aws dynamodb wait table-exists \
    --table-name s3-file-metrics \
    --region YOUR-REGION

echo "✅ Table created successfully!"
```

### Option B: Using Python Script

```bash
# Run the provided script
python create_metrics_table.py
```

### ☐ Verify Table Creation

```bash
aws dynamodb describe-table \
    --table-name s3-file-metrics \
    --region YOUR-REGION \
    --query 'Table.[TableName,TableStatus,BillingModeSummary.BillingMode]'
```

Expected output:
```json
[
    "s3-file-metrics",
    "ACTIVE",
    "PAY_PER_REQUEST"
]
```

---

## Step 2: Create Lambda Function (10 minutes)

### ☐ 1. Create IAM Role for Lambda

```bash
# Create trust policy file
cat > lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role
aws iam create-role \
    --role-name s3-metrics-collector-role \
    --assume-role-policy-document file://lambda-trust-policy.json

# Attach basic Lambda execution policy
aws iam attach-role-policy \
    --role-name s3-metrics-collector-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### ☐ 2. Create Inline Policy for Metrics Collection

```bash
# Create policy document
cat > metrics-collector-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:HeadObject"
      ],
      "Resource": "arn:aws:s3:::YOUR-SOURCE-BUCKET-NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:YOUR-REGION:YOUR-ACCOUNT-ID:table/s3-file-metrics"
    }
  ]
}
EOF

# Replace YOUR-SOURCE-BUCKET-NAME, YOUR-REGION, and YOUR-ACCOUNT-ID with actual values
# Then attach the policy
aws iam put-role-policy \
    --role-name s3-metrics-collector-role \
    --policy-name MetricsCollectorPolicy \
    --policy-document file://metrics-collector-policy.json
```

### ☐ 3. Package Lambda Function

```bash
# Create deployment package
mkdir lambda-package
cp metrics_collector_lambda.py lambda-package/
cd lambda-package

# Zip the function
zip -r ../metrics-collector.zip .
cd ..

echo "✅ Lambda package created: metrics-collector.zip"
```

### ☐ 4. Deploy Lambda Function

```bash
# Get the role ARN
ROLE_ARN=$(aws iam get-role \
    --role-name s3-metrics-collector-role \
    --query 'Role.Arn' \
    --output text)

echo "Role ARN: $ROLE_ARN"

# Create Lambda function
aws lambda create-function \
    --function-name s3-metrics-collector \
    --runtime python3.11 \
    --role $ROLE_ARN \
    --handler metrics_collector_lambda.lambda_handler \
    --zip-file fileb://metrics-collector.zip \
    --timeout 30 \
    --memory-size 256 \
    --region YOUR-REGION \
    --description "Lightweight metrics collector for S3 file ingestion" \
    --tags Project=YourProjectName,Purpose=Metrics

echo "✅ Lambda function created!"
```

### ☐ 5. Verify Lambda Creation

```bash
aws lambda get-function \
    --function-name s3-metrics-collector \
    --region YOUR-REGION \
    --query '[FunctionName,Runtime,State,LastUpdateStatus]'
```

Expected output:
```json
[
    "s3-metrics-collector",
    "python3.11",
    "Active",
    "Successful"
]
```

---

## Step 3: Add S3 Event Trigger (5 minutes)

### ⚠️ IMPORTANT: This Will Run in Parallel

The metrics collector will receive the **same** S3 events as your existing Lambda. Both will run for each file upload. This is **intentional** and **safe**.

### ☐ 1. Grant S3 Permission to Invoke Lambda

```bash
aws lambda add-permission \
    --function-name s3-metrics-collector \
    --principal s3.amazonaws.com \
    --statement-id s3-invoke-metrics \
    --action "lambda:InvokeFunction" \
    --source-arn arn:aws:s3:::YOUR-SOURCE-BUCKET-NAME \
    --source-account YOUR-ACCOUNT-ID \
    --region YOUR-REGION
```

### ☐ 2. Create S3 Event Notification Configuration

```bash
# First, get existing notification configuration (if any)
aws s3api get-bucket-notification-configuration \
    --bucket YOUR-SOURCE-BUCKET-NAME > existing-notifications.json

# Check if there are existing notifications
cat existing-notifications.json
```

**If you have existing notifications:**
You'll need to **merge** the new configuration. Here's how:

```bash
# Create new notification configuration that ADDS metrics collector
cat > notification-config.json << 'EOF'
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "MetricsCollector",
      "LambdaFunctionArn": "arn:aws:lambda:YOUR-REGION:YOUR-ACCOUNT-ID:function:s3-metrics-collector",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "suffix",
              "Value": ".ndjson"
            }
          ]
        }
      }
    }
  ]
}
EOF

# IMPORTANT: If you have existing Lambda notifications, 
# you must include them in the array above!
# Otherwise, they will be removed.
```

**If NO existing notifications:**

```bash
# Simple configuration - just metrics collector
cat > notification-config.json << 'EOF'
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "MetricsCollector",
      "LambdaFunctionArn": "arn:aws:lambda:YOUR-REGION:YOUR-ACCOUNT-ID:function:s3-metrics-collector",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "suffix",
              "Value": ".ndjson"
            }
          ]
        }
      }
    }
  ]
}
EOF
```

### ☐ 3. Apply Notification Configuration

```bash
# Replace placeholders in notification-config.json first!
# Then apply:
aws s3api put-bucket-notification-configuration \
    --bucket YOUR-SOURCE-BUCKET-NAME \
    --notification-configuration file://notification-config.json

echo "✅ S3 event notification configured!"
```

### ☐ 4. Verify S3 Trigger

```bash
# Check notification configuration
aws s3api get-bucket-notification-configuration \
    --bucket YOUR-SOURCE-BUCKET-NAME

# Should show your metrics collector Lambda in the list
```

---

## Step 4: Verify Setup (5 minutes)

### ☐ 1. Test Lambda Function Manually

```bash
# Create test event
cat > test-event.json << 'EOF'
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "eventTime": "2026-02-02T12:00:00.000Z",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": {
          "name": "YOUR-SOURCE-BUCKET-NAME"
        },
        "object": {
          "key": "test/sample.ndjson",
          "size": 3670016
        }
      }
    }
  ]
}
EOF

# Invoke Lambda with test event
aws lambda invoke \
    --function-name s3-metrics-collector \
    --payload file://test-event.json \
    --region YOUR-REGION \
    response.json

# Check response
cat response.json
```

Expected output in `response.json`:
```json
{
  "statusCode": 200,
  "body": "\"Processed 1 file metrics\""
}
```

### ☐ 2. Check CloudWatch Logs

```bash
# Get recent log events
aws logs tail /aws/lambda/s3-metrics-collector \
    --since 10m \
    --follow
```

You should see logs showing the test file being recorded.

### ☐ 3. Query DynamoDB to Verify Data

```bash
# Get current hour partition
CURRENT_HOUR=$(date -u +"%Y-%m-%d-%H")

echo "Querying for date_hour: $CURRENT_HOUR"

# Query the metrics table
aws dynamodb query \
    --table-name s3-file-metrics \
    --key-condition-expression "date_hour = :dh" \
    --expression-attribute-values "{\":dh\":{\"S\":\"$CURRENT_HOUR\"}}" \
    --region YOUR-REGION \
    --max-items 5
```

If test worked, you should see at least one item.

---

## Step 5: Monitor Data Collection (Ongoing)

### ☐ 1. Watch for Real Production Files

```bash
# Monitor CloudWatch logs in real-time
aws logs tail /aws/lambda/s3-metrics-collector \
    --since 1m \
    --follow

# Press Ctrl+C to stop
```

You should see entries like:
```
Recorded: path/to/file.ndjson - 3.45 MB
Recorded: another/file.ndjson - 3.52 MB
```

### ☐ 2. Check DynamoDB Item Count

```bash
# Scan table to get rough count (use sparingly - reads all items)
aws dynamodb scan \
    --table-name s3-file-metrics \
    --select COUNT \
    --region YOUR-REGION
```

### ☐ 3. Monitor Lambda Metrics

```bash
# Check Lambda invocation count
aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Invocations \
    --dimensions Name=FunctionName,Value=s3-metrics-collector \
    --start-time $(date -u -d '1 hour ago' --iso-8601=seconds) \
    --end-time $(date -u --iso-8601=seconds) \
    --period 300 \
    --statistics Sum \
    --region YOUR-REGION
```

---

## Step 6: Data Collection Period

### Minimum Collection Time: 1 Hour
- **Good for:** Quick sanity check
- **Use case:** Verify metrics collector is working
- **Data quality:** Limited, may not capture peak hours

### Recommended Collection Time: 24 Hours
- **Good for:** Understanding daily patterns
- **Use case:** Accurate average and peak calculations
- **Data quality:** Shows hourly variation

### Optimal Collection Time: 7 Days
- **Good for:** Complete picture including weekends
- **Use case:** Long-term capacity planning
- **Data quality:** Shows weekly patterns and true peaks

**Recommendation:** Start with 24 hours minimum, extend to 7 days if possible.

---

## Step 7: Run Analysis (After Collection Period)

### ☐ 1. Install Required Python Libraries (if not already installed)

```bash
pip install boto3
```

### ☐ 2. Run Analysis Script

```bash
# For last 24 hours
python analyze_metrics.py

# For last 7 days
python analyze_metrics.py 168  # 168 hours = 7 days

# For last hour (testing)
python analyze_metrics.py 1
```

### ☐ 3. Review Output

The script will output:
```
================================================================================
S3 FILE METRICS ANALYSIS - Last 24 Hours
================================================================================

📊 OVERALL STATISTICS
   Total Files Processed: 96,000
   Time Period: 24 hours
   Total Volume: 336.00 GB (0.33 TB)

📏 FILE SIZE STATISTICS
   Average File Size: 3.500 MB
   Median File Size: 3.498 MB
   Min File Size: 2.100 MB
   Max File Size: 4.800 MB
   Std Deviation: 0.245 MB

📈 PERCENTILES
   P50 (Median): 3.498 MB
   P95: 3.890 MB
   P99: 4.320 MB

⚡ VELOCITY METRICS
   Files/Hour (Average): 4,000.00
   Files/Second (Average): 1.111
   GB/Hour: 14.00
   TB/Day (Projected): 0.34
   TB/Month (Projected): 10.08

🔥 PEAK METRICS
   Peak Hour: 2026-02-02-14
   Peak Files/Hour: 7,000
   Peak GB/Hour: 24.50
   Peak Files/Second: 1.944

💡 KEY FINDINGS:
   Your ACTUAL file size: 3.500 MB (confirmed!)
   Your ACTUAL ingestion rate: 4,000 files/hour
   Your ACTUAL daily volume: 0.34 TB/day
```

---

## Step 8: Decision Making

### Based on Metrics Results:

#### If Average File Size < 1.5 GB:
✅ **Your Lambda architecture is PERFECT**
- No changes needed
- Implement only Opus's quality improvements
- Total cost: ~$1,000-1,500/month

#### If Average File Size 1.5 - 2.5 GB:
⚠️ **Your Lambda architecture needs optimization**
- Increase Lambda timeout to 15 minutes
- Optimize Glue batching
- Consider hybrid approach
- Monitor timeout errors

#### If Average File Size > 2.5 GB:
❌ **Need architectural changes**
- Lambda will timeout frequently
- Migrate to ECS Fargate or optimize Glue
- Re-evaluate based on actual data

---

## Troubleshooting

### Issue: Lambda Not Being Invoked

**Check:**
```bash
# Verify S3 event notification exists
aws s3api get-bucket-notification-configuration \
    --bucket YOUR-SOURCE-BUCKET-NAME

# Check Lambda permissions
aws lambda get-policy \
    --function-name s3-metrics-collector \
    --region YOUR-REGION
```

**Fix:**
Re-run Step 3 (S3 Event Trigger setup)

---

### Issue: Lambda Errors in CloudWatch

**Check logs:**
```bash
aws logs tail /aws/lambda/s3-metrics-collector \
    --since 30m
```

**Common errors:**

1. **AccessDenied on S3:**
   - Check IAM policy includes your bucket
   - Verify bucket name in policy

2. **AccessDenied on DynamoDB:**
   - Check IAM policy has dynamodb:PutItem
   - Verify table name and region

3. **Table not found:**
   - Confirm table exists: `aws dynamodb describe-table --table-name s3-file-metrics`
   - Check region matches

---

### Issue: No Data in DynamoDB

**Check:**
```bash
# Verify table exists and is active
aws dynamodb describe-table \
    --table-name s3-file-metrics \
    --query 'Table.[TableName,TableStatus]'

# Check if any items exist
aws dynamodb scan \
    --table-name s3-file-metrics \
    --select COUNT
```

**Possible causes:**
1. No files uploaded to S3 yet
2. S3 event notification not configured
3. Lambda failing silently (check CloudWatch logs)

---

## Cleanup (After Analysis Complete)

### ☐ 1. Remove S3 Event Trigger (Keep Other Notifications!)

```bash
# CAREFUL: This removes ALL notifications if not done correctly
# Better: Use AWS Console to remove only MetricsCollector notification

# Or manually edit notification-config.json to remove metrics collector
# Then apply:
aws s3api put-bucket-notification-configuration \
    --bucket YOUR-SOURCE-BUCKET-NAME \
    --notification-configuration file://updated-notifications.json
```

### ☐ 2. (Optional) Delete Lambda Function

```bash
aws lambda delete-function \
    --function-name s3-metrics-collector \
    --region YOUR-REGION
```

### ☐ 3. (Optional) Delete IAM Role

```bash
# Detach policies
aws iam detach-role-policy \
    --role-name s3-metrics-collector-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Delete inline policy
aws iam delete-role-policy \
    --role-name s3-metrics-collector-role \
    --policy-name MetricsCollectorPolicy

# Delete role
aws iam delete-role \
    --role-name s3-metrics-collector-role
```

### ☐ 4. (Optional) Delete DynamoDB Table

```bash
# Only if you don't need the historical metrics
aws dynamodb delete-table \
    --table-name s3-file-metrics \
    --region YOUR-REGION
```

---

## Cost Estimate for Metrics Collection

### 24-Hour Collection Period:

**DynamoDB:**
- Items stored: 96,000 (at 4,000 files/hour)
- Storage: ~50 MB
- Writes: 96,000 × $1.25/million = $0.12
- Storage: $0.25/GB × 0.05 GB = $0.01
- **Total: ~$0.13**

**Lambda:**
- Invocations: 96,000
- Duration: 0.5 sec per file
- Memory: 256 MB
- Request cost: 96,000 × $0.20/million = $0.02
- Compute cost: 96,000 × 0.5 sec × $0.0000016667 = $0.08
- **Total: ~$0.10**

**CloudWatch Logs:**
- ~100 KB per file × 96,000 = 9.6 GB
- Ingestion: 9.6 GB × $0.50/GB = $4.80
- Storage: 9.6 GB × $0.03/GB = $0.29
- **Total: ~$5.09**

**Total Cost for 24 Hours:** ~$5.32

**Total Cost for 7 Days:** ~$37.24

---

## Quick Reference Commands

### Check if metrics are flowing:
```bash
aws logs tail /aws/lambda/s3-metrics-collector --since 5m
```

### Count items collected:
```bash
aws dynamodb scan --table-name s3-file-metrics --select COUNT
```

### Run analysis:
```bash
python analyze_metrics.py
```

### Check Lambda errors:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=s3-metrics-collector \
  --start-time $(date -u -d '24 hours ago' --iso-8601) \
  --end-time $(date -u --iso-8601) \
  --period 3600 \
  --statistics Sum
```

---

## Success Criteria

✅ **Setup Complete When:**
- DynamoDB table is ACTIVE
- Lambda function is deployed
- S3 event trigger is configured
- Test invocation succeeds
- Real files are being recorded

✅ **Ready for Analysis When:**
- At least 24 hours of data collected
- Multiple files recorded per hour
- Peak and average hours captured
- No Lambda errors in CloudWatch

✅ **Ready for Decision When:**
- Analysis script runs successfully
- File size distribution is clear
- Ingestion rate patterns are understood
- Peak vs average is known

---

## Next Steps After Analysis

1. **Share metrics output** with me
2. **We'll validate** the numbers together
3. **Determine if** your architecture needs changes
4. **Create action plan** based on real data
5. **Implement improvements** with confidence

**No guessing. No assumptions. Data-driven decisions.** 📊
