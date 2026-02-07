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
# Archive Lambda Source Files
###############################################################################

data "archive_file" "manifest_builder" {
  type        = "zip"
  source_file = "${var.lambda_source_dir}/lambda_manifest_builder.py"
  output_path = "${path.module}/builds/lambda_manifest_builder.zip"
}

data "archive_file" "batch_status_updater" {
  type        = "zip"
  source_file = "${var.lambda_source_dir}/lambda_batch_status_updater.py"
  output_path = "${path.module}/builds/lambda_batch_status_updater.zip"
}

data "archive_file" "stream_manifest_creator" {
  type        = "zip"
  source_file = "${var.lambda_source_dir}/lambda_stream_manifest_creator.py"
  output_path = "${path.module}/builds/lambda_stream_manifest_creator.zip"
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

  filename         = data.archive_file.manifest_builder.output_path
  source_code_hash = data.archive_file.manifest_builder.output_base64sha256

  # Reserved concurrent executions
  #If your files vary greatly in size, increase size_tolerance_percent to 20-30%
  # If files are consistently smaller/larger, adjust expected_file_size_mb
  # If you want to accept ANY size, set size_tolerance_percent = 100 (not recommended)
  reserved_concurrent_executions = var.manifest_builder_concurrency

  environment {
    variables = {
      TRACKING_TABLE                  = var.file_tracking_table_name
      METRICS_TABLE                   = var.metrics_table_name
      INPUT_BUCKET                    = var.input_bucket_name
      INPUT_PREFIX                    = var.input_bucket_prefix
      OUTPUT_BUCKET                   = var.output_bucket_name
      OUTPUT_PREFIX                   = var.output_bucket_prefix
      MANIFEST_BUCKET                 = var.manifest_bucket_name
      MANIFEST_PREFIX                 = var.manifest_bucket_prefix
      QUARANTINE_BUCKET               = var.quarantine_bucket_name
      QUARANTINE_PREFIX               = var.quarantine_bucket_prefix
      MAX_FILES_PER_MANIFEST          = var.max_files_per_manifest
      EXPECTED_FILE_SIZE_MB           = var.expected_file_size_mb
      SIZE_TOLERANCE_PERCENT          = var.size_tolerance_percent
      ENVIRONMENT                     = var.environment
      STEP_FUNCTION_ARN               = var.step_function_arn
      TTL_DAYS                        = var.ttl_days
      LOG_LEVEL                       = var.log_level
      EVENT_BUS_NAME                  = var.event_bus_name
      NUM_STATUS_SHARDS               = var.num_status_shards
      ENABLE_STREAM_MANIFEST_CREATION = var.enable_stream_manifest_creation ? "true" : "false"
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

###############################################################################
# EventBridge - ManifestReady Event Rule & Step Functions Target
###############################################################################

resource "aws_cloudwatch_event_bus" "etl_pipeline" {
  count = var.event_bus_name != "" ? 1 : 0
  name  = var.event_bus_name

  tags = merge(var.tags, {
    Name        = "ETL Pipeline Event Bus"
    Description = "Event bus for ETL pipeline ManifestReady events"
  })
}

resource "aws_cloudwatch_event_rule" "manifest_ready" {
  count          = var.event_bus_name != "" ? 1 : 0
  name           = "${var.environment}-manifest-ready-rule"
  description    = "Routes ManifestReady events to Step Functions"
  event_bus_name = aws_cloudwatch_event_bus.etl_pipeline[0].name

  event_pattern = jsonencode({
    source      = ["etl.pipeline"]
    detail-type = ["ManifestReady"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "step_functions" {
  count          = var.event_bus_name != "" ? 1 : 0
  rule           = aws_cloudwatch_event_rule.manifest_ready[0].name
  event_bus_name = aws_cloudwatch_event_bus.etl_pipeline[0].name
  arn            = var.step_function_arn
  role_arn       = var.eventbridge_role_arn

  input_transformer {
    input_paths = {
      manifest_path = "$.detail.manifest_path"
      date_prefix   = "$.detail.date_prefix"
      file_count    = "$.detail.file_count"
      file_key      = "$.detail.file_key"
      timestamp     = "$.detail.timestamp"
    }
    input_template = <<-EOF
    {
      "manifest_path": <manifest_path>,
      "date_prefix": <date_prefix>,
      "file_count": <file_count>,
      "file_key": <file_key>,
      "timestamp": <timestamp>
    }
    EOF
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq[0].arn
  }
}

resource "aws_sqs_queue" "eventbridge_dlq" {
  count                     = var.event_bus_name != "" ? 1 : 0
  name                      = "ndjson-parquet-eventbridge-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(var.tags, {
    Name        = "EventBridge ManifestReady DLQ"
    Description = "Dead letter queue for failed EventBridge -> Step Functions deliveries"
  })
}

resource "aws_cloudwatch_metric_alarm" "eventbridge_dlq_messages" {
  count               = var.event_bus_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-EventBridge-DLQ-Messages-CRITICAL"
  alarm_description   = "Alert when EventBridge events fail to reach Step Functions"
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
    QueueName = aws_sqs_queue.eventbridge_dlq[0].name
  }

  tags = var.tags
}

###############################################################################
# DynamoDB Stream Lambda - Event-Driven Manifest Creator
###############################################################################

resource "aws_lambda_function" "stream_manifest_creator" {
  count         = var.file_tracking_table_stream_arn != "" ? 1 : 0
  function_name = "ndjson-parquet-stream-manifest-creator-${var.environment}"
  description   = "Creates manifests from DynamoDB Stream events when file threshold is reached"
  role          = var.lambda_role_arn
  handler       = "lambda_stream_manifest_creator.lambda_handler"
  runtime       = "python3.11"
  timeout       = 120
  memory_size   = 512

  filename         = data.archive_file.stream_manifest_creator.output_path
  source_code_hash = data.archive_file.stream_manifest_creator.output_base64sha256

  environment {
    variables = {
      TRACKING_TABLE         = var.file_tracking_table_name
      MANIFEST_BUCKET        = var.manifest_bucket_name
      MAX_FILES_PER_MANIFEST = var.max_files_per_manifest
      EVENT_BUS_NAME         = var.event_bus_name
      STEP_FUNCTION_ARN      = var.step_function_arn
      TTL_DAYS               = var.ttl_days
      NUM_STATUS_SHARDS      = var.num_status_shards
      LOG_LEVEL              = var.log_level
      ENVIRONMENT            = var.environment
    }
  }

  tags = merge(var.tags, {
    Name        = "Stream Manifest Creator Lambda"
    Description = "Event-driven manifest creation from DynamoDB Streams"
  })
}

resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  count                              = var.file_tracking_table_stream_arn != "" ? 1 : 0
  event_source_arn                   = var.file_tracking_table_stream_arn
  function_name                      = aws_lambda_function.stream_manifest_creator[0].arn
  starting_position                  = "LATEST"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 30

  # Process in parallel across shards
  parallelization_factor = 10

  # Retry and error handling
  maximum_retry_attempts         = 3
  maximum_record_age_in_seconds  = 3600
  bisect_batch_on_function_error = true

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_lambda_dlq[0].arn
    }
  }

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT"]
      })
    }
  }
}

resource "aws_cloudwatch_log_group" "stream_manifest_creator" {
  count             = var.file_tracking_table_stream_arn != "" ? 1 : 0
  name              = "/aws/lambda/ndjson-parquet-stream-manifest-creator-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_sqs_queue" "stream_lambda_dlq" {
  count                     = var.file_tracking_table_stream_arn != "" ? 1 : 0
  name                      = "ndjson-parquet-stream-lambda-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(var.tags, {
    Name        = "Stream Lambda DLQ"
    Description = "Dead letter queue for failed DynamoDB Stream processing"
  })
}

resource "aws_cloudwatch_metric_alarm" "stream_lambda_dlq_messages" {
  count               = var.file_tracking_table_stream_arn != "" ? 1 : 0
  alarm_name          = "${var.environment}-Stream-Lambda-DLQ-Messages-CRITICAL"
  alarm_description   = "Alert when DynamoDB Stream Lambda fails"
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
    QueueName = aws_sqs_queue.stream_lambda_dlq[0].name
  }

  tags = var.tags
}

###############################################################################
# Batch Status Updater Lambda - Updates individual file records after Glue
###############################################################################

resource "aws_lambda_function" "batch_status_updater" {
  function_name = "ndjson-parquet-batch-status-updater-${var.environment}"
  description   = "Updates individual file record statuses after Glue job completes"
  role          = var.lambda_role_arn
  handler       = "lambda_batch_status_updater.lambda_handler"
  runtime       = "python3.11"
  timeout       = 120
  memory_size   = 256

  filename         = data.archive_file.batch_status_updater.output_path
  source_code_hash = data.archive_file.batch_status_updater.output_base64sha256

  environment {
    variables = {
      TRACKING_TABLE = var.file_tracking_table_name
      TTL_DAYS       = var.ttl_days
      LOG_LEVEL      = var.log_level
      ENVIRONMENT    = var.environment
    }
  }

  tags = merge(var.tags, {
    Name        = "Batch Status Updater Lambda"
    Description = "Updates individual file statuses after Glue processing"
  })
}

resource "aws_cloudwatch_log_group" "batch_status_updater" {
  name              = "/aws/lambda/ndjson-parquet-batch-status-updater-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}
