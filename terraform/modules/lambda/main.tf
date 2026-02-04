/**
 * Lambda Function Module
 *
 * Creates the manifest builder Lambda function that:
 * - Receives S3 or SQS events when NDJSON files arrive
 * - Validates file size and format
 * - Batches files into manifests (100 files per manifest)
 * - Writes manifests to S3
 * - Tracks file state in DynamoDB
 */

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

###############################################################################
# Lambda Function
###############################################################################

resource "aws_lambda_function" "manifest_builder" {
  function_name = "ndjson-parquet-manifest-builder-${var.environment}"
  description   = "Builds manifests from incoming NDJSON files for batch processing"
  role          = var.lambda_role_arn
  handler       = "lambda_manifest_builder.lambda_handler"
  runtime       = "python3.11"
  timeout       = var.manifest_builder_timeout
  memory_size   = var.manifest_builder_memory

  # Code from S3
  s3_bucket = var.scripts_bucket_name
  s3_key    = "lambda/${var.environment}/lambda_manifest_builder.zip"

  # Reserved concurrent executions
  #If your files vary greatly in size, increase size_tolerance_percent to 20-30%
  # If files are consistently smaller/larger, adjust expected_file_size_mb
  # If you want to accept ANY size, set size_tolerance_percent = 100 (not recommended)
  reserved_concurrent_executions = var.manifest_builder_concurrency

  environment {
    variables = {
      TRACKING_TABLE         = var.file_tracking_table_name
      METRICS_TABLE          = var.metrics_table_name
      INPUT_BUCKET           = var.input_bucket_name
      INPUT_PREFIX           = var.input_bucket_prefix
      OUTPUT_BUCKET          = var.output_bucket_name
      OUTPUT_PREFIX          = var.output_bucket_prefix
      MANIFEST_BUCKET        = var.manifest_bucket_name
      MANIFEST_PREFIX        = var.manifest_bucket_prefix
      QUARANTINE_BUCKET      = var.quarantine_bucket_name
      QUARANTINE_PREFIX      = var.quarantine_bucket_prefix
      MAX_FILES_PER_MANIFEST = var.max_files_per_manifest
      EXPECTED_FILE_SIZE_MB  = var.expected_file_size_mb
      SIZE_TOLERANCE_PERCENT = var.size_tolerance_percent
      ENVIRONMENT            = var.environment
      STEP_FUNCTION_ARN      = var.step_function_arn
      TTL_DAYS               = var.ttl_days
      LOG_LEVEL              = var.log_level
    }
  }

  tags = merge(
    var.tags,
    {
      Name        = "Manifest Builder Lambda"
      Description = "Batches NDJSON files into manifests"
    }
  )
}

###############################################################################
# Lambda Dead Letter Queue
###############################################################################

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "ndjson-parquet-lambda-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(
    var.tags,
    {
      Name        = "Lambda Manifest Builder DLQ"
      Description = "Dead letter queue for failed Lambda invocations"
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "lambda_dlq_messages" {
  alarm_name          = "${var.environment}-Lambda-DLQ-Messages-CRITICAL"
  alarm_description   = "Alert when messages arrive in Lambda DLQ - investigate failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  dimensions = {
    QueueName = aws_sqs_queue.lambda_dlq.name
  }

  tags = var.tags
}

###############################################################################
# CloudWatch Log Group
###############################################################################

resource "aws_cloudwatch_log_group" "manifest_builder" {
  name              = "/aws/lambda/ndjson-parquet-manifest-builder-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

###############################################################################
# S3 Event Trigger - REMOVED
# Using S3 → SQS → Lambda flow instead of direct S3 → Lambda
# This provides better reliability, throttle protection, and DLQ capabilities
###############################################################################

# The S3 bucket notification to SQS is configured in the SQS module
# Lambda is triggered via SQS event source mapping (also in SQS module)

###############################################################################
# CloudWatch Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.environment}-ManifestBuilder-Errors-WARNING"
  alarm_description   = "Alert when manifest builder has errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  dimensions = {
    FunctionName = aws_lambda_function.manifest_builder.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.environment}-ManifestBuilder-Throttles-WARNING"
  alarm_description   = "Alert when manifest builder is throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  dimensions = {
    FunctionName = aws_lambda_function.manifest_builder.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${var.environment}-ManifestBuilder-Duration-WARNING"
  alarm_description   = "Alert when manifest builder approaches timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = var.manifest_builder_timeout * 1000 * 0.8 # 80% of timeout in milliseconds
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  dimensions = {
    FunctionName = aws_lambda_function.manifest_builder.function_name
  }

  tags = var.tags
}
