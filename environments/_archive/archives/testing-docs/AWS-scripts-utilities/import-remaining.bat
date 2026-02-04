@echo off
REM =============================================================================
REM Import remaining resources that already exist in AWS
REM =============================================================================

SET ACCOUNT_ID=<ACCOUNT>
SET REGION=us-east-1
SET ENV=dev

echo ==========================================
echo Importing remaining resources...
echo ==========================================

REM DynamoDB metrics table
echo Importing DynamoDB metrics table...
terraform import "module.dynamodb.aws_dynamodb_table.metrics" "ndjson-parquet-sqs-metrics-%ENV%"

REM S3 Buckets with correct naming (these are the actual bucket names in AWS)
echo Importing S3 buckets...
terraform import "module.s3.aws_s3_bucket.manifest[0]" "ndjson-manifest-sqs-%ACCOUNT_ID%-%ENV%"
terraform import "module.s3.aws_s3_bucket.output[0]" "ndjson-output-sqs-%ACCOUNT_ID%-%ENV%"
terraform import "module.s3.aws_s3_bucket.quarantine[0]" "ndjson-quarantine-sqs-%ACCOUNT_ID%-%ENV%"
terraform import "module.s3.aws_s3_bucket.scripts[0]" "ndjson-glue-scripts-%ACCOUNT_ID%-%ENV%"

REM Lambda permission for S3 trigger
echo Importing Lambda S3 permission...
terraform import "module.lambda.aws_lambda_permission.s3_trigger" "ndjson-parquet-manifest-builder-%ENV%/AllowS3Invoke"

REM SQS Lambda event source mapping (UUID from error message)
echo Importing SQS event source mapping...
terraform import "module.sqs.aws_lambda_event_source_mapping.sqs_to_lambda" "76ef13a5-8457-4b7c-8468-99abb744830c"

echo ==========================================
echo Import complete! Now run: terraform plan
echo ==========================================
pause
