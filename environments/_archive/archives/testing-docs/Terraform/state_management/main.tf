/**
 * State Management Lambda Module
 *
 * Creates the state management Lambda function that provides:
 * - File state queries and updates
 * - Orphan detection and cleanup
 * - Consistency validation
 * - Processing timeline analysis
 * - Scheduled health checks (production only)
 *
 * SECURITY NOTE: HTTP API Gateway is disabled by default to prevent external access.
 * For production deployments, the pipeline remains completely private.
 */

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

###############################################################################
# Lambda Function
###############################################################################

resource "aws_lambda_function" "state_management" {
  function_name = "ndjson-parquet-state-manager-${var.environment}"
  description   = "State management and querying for NDJSON to Parquet pipeline"
  role          = var.role_arn
  handler       = "lambda_state_manager.lambda_handler"
  runtime       = "python3.11"
  timeout       = var.timeout
  memory_size   = var.memory_size

  # Code from S3
  s3_bucket = var.scripts_bucket_name
  s3_key    = "lambda/${var.environment}/lambda_state_manager.zip"

  reserved_concurrent_executions = var.environment == "prod" ? 5 : 2

  environment {
    variables = {
      TRACKING_TABLE    = var.file_tracking_table_name
      METRICS_TABLE     = var.metrics_table_name
      INPUT_BUCKET      = var.input_bucket_name
      MANIFEST_BUCKET   = var.manifest_bucket_name
      OUTPUT_BUCKET     = var.output_bucket_name
      QUARANTINE_BUCKET = var.quarantine_bucket_name
      ENVIRONMENT       = var.environment
    }
  }

  tags = merge(
    var.tags,
    {
      Name        = "State Management Lambda"
      Description = "File state management and operations"
    }
  )
}

###############################################################################
# CloudWatch Log Group
###############################################################################

resource "aws_cloudwatch_log_group" "state_management" {
  name              = "/aws/lambda/ndjson-parquet-state-manager-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

###############################################################################
# API Gateway - REMOVED FOR SECURITY
###############################################################################

# API Gateway has been permanently removed to prevent any external access.
# The pipeline is designed to be completely private with no public endpoints.
# Access is only possible through AWS Console, CLI, or SDK with proper IAM credentials.

# All API Gateway resources have been removed:
# - aws_apigatewayv2_api
# - aws_apigatewayv2_integration
# - aws_apigatewayv2_route
# - aws_apigatewayv2_stage
# - aws_lambda_permission for API Gateway

###############################################################################
# EventBridge Scheduled Health Checks (Production Only)
###############################################################################

# Orphan detection schedule (every 6 hours)
resource "aws_cloudwatch_event_rule" "orphan_detection" {
  count               = var.enable_schedules ? 1 : 0
  name                = "ndjson-parquet-orphan-detection-${var.environment}"
  description         = "Scheduled orphan detection (every 6 hours)"
  schedule_expression = "rate(6 hours)"
  state               = "ENABLED"

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "orphan_detection" {
  count     = var.enable_schedules ? 1 : 0
  rule      = aws_cloudwatch_event_rule.orphan_detection[0].name
  target_id = "OrphanDetectionTarget"
  arn       = aws_lambda_function.state_management.arn

  input = jsonencode({
    operation             = "find_orphans"
    max_processing_hours  = 2
  })
}

resource "aws_lambda_permission" "orphan_detection" {
  count         = var.enable_schedules ? 1 : 0
  statement_id  = "AllowOrphanDetectionSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.state_management.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.orphan_detection[0].arn
}

# Stats collection schedule (every hour)
resource "aws_cloudwatch_event_rule" "stats_collection" {
  count               = var.enable_schedules ? 1 : 0
  name                = "ndjson-parquet-stats-collection-${var.environment}"
  description         = "Scheduled stats collection (every hour)"
  schedule_expression = "rate(1 hour)"
  state               = "ENABLED"

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "stats_collection" {
  count     = var.enable_schedules ? 1 : 0
  rule      = aws_cloudwatch_event_rule.stats_collection[0].name
  target_id = "StatsCollectionTarget"
  arn       = aws_lambda_function.state_management.arn

  input = jsonencode({
    operation = "get_stats"
  })
}

resource "aws_lambda_permission" "stats_collection" {
  count         = var.enable_schedules ? 1 : 0
  statement_id  = "AllowStatsCollectionSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.state_management.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stats_collection[0].arn
}

###############################################################################
# CloudWatch Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "state_management_errors" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${var.environment}-StateManagement-Errors-WARNING"
  alarm_description   = "Alert when state management function has errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.state_management.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "state_management_throttles" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${var.environment}-StateManagement-Throttles-WARNING"
  alarm_description   = "Alert when state management function is throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.state_management.function_name
  }

  tags = var.tags
}
