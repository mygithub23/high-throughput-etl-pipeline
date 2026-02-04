/**
 * Monitoring Module
 *
 * Creates monitoring and alerting infrastructure:
 * - SNS topics for alerts
 * - CloudWatch alarms for all pipeline components
 * - CloudWatch dashboard for visualization
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
# SNS Topics for Alerts
###############################################################################

resource "aws_sns_topic" "alerts" {
  name         = "ndjson-parquet-alerts-${var.environment}"
  display_name = "NDJSON to Parquet Pipeline Alerts"

  tags = merge(
    var.tags,
    {
      Name        = "Pipeline Alerts"
      Description = "SNS topic for pipeline alerts"
    }
  )
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# DynamoDB Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "file_tracking_read_throttle" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-FileTracking-ReadThrottle-WARNING"
  alarm_description   = "File tracking table read throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UserErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TableName = var.file_tracking_table_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "file_tracking_write_throttle" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-FileTracking-WriteThrottle-WARNING"
  alarm_description   = "File tracking table write throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "WriteThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TableName = var.file_tracking_table_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "metrics_table_errors" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-MetricsTable-Errors-WARNING"
  alarm_description   = "Metrics table errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TableName = var.metrics_table_name
  }

  tags = var.tags
}

###############################################################################
# Lambda Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-Lambda-Errors-CRITICAL"
  alarm_description   = "Lambda function errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-Lambda-Throttles-CRITICAL"
  alarm_description   = "Lambda function throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_concurrent_executions" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-Lambda-ConcurrentExecutions-WARNING"
  alarm_description   = "Lambda concurrent executions approaching limit"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ConcurrentExecutions"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Maximum"
  threshold           = 40
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

###############################################################################
# Glue Job Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "glue_job_failures" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-GlueJob-Failures-CRITICAL"
  alarm_description   = "Glue job failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    JobName = var.glue_job_name
  }

  tags = var.tags
}

###############################################################################
# Step Functions Alarms - CRITICAL SERVER ISSUES
###############################################################################

resource "aws_cloudwatch_metric_alarm" "step_functions_execution_failed" {
  count               = var.create_alarms && var.step_function_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-StepFunctions-ExecutionFailed-CRITICAL"
  alarm_description   = "Step Functions workflow execution failed - indicates severe processing issues"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    StateMachineArn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.step_function_name}"
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "step_functions_execution_timeout" {
  count               = var.create_alarms && var.step_function_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-StepFunctions-ExecutionTimeout-CRITICAL"
  alarm_description   = "Step Functions workflow execution timed out - severe processing delay"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsTimedOut"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    StateMachineArn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.step_function_name}"
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "step_functions_execution_throttled" {
  count               = var.create_alarms && var.step_function_name != "" ? 1 : 0
  alarm_name          = "${var.environment}-StepFunctions-ExecutionThrottled-WARNING"
  alarm_description   = "Step Functions executions throttled - capacity issue"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ExecutionThrottled"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    StateMachineArn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.step_function_name}"
  }

  tags = var.tags
}

###############################################################################
# Lambda Advanced Alarms - PERFORMANCE & RELIABILITY
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_duration_high" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-Lambda-DurationHigh-WARNING"
  alarm_description   = "Lambda duration approaching timeout - performance degradation detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  # Alert at 80% of timeout
  threshold          = var.lambda_timeout * 1000 * 0.8
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_iterator_age" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-Lambda-IteratorAgeHigh-WARNING"
  alarm_description   = "Lambda iterator age high - event processing backlog detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "IteratorAge"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Maximum"
  threshold           = 60000 # 1 minute in milliseconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

###############################################################################
# DynamoDB System Errors - AWS SERVICE ISSUES
###############################################################################

resource "aws_cloudwatch_metric_alarm" "file_tracking_system_errors" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-FileTracking-SystemErrors-CRITICAL"
  alarm_description   = "File tracking table system errors - AWS service issue"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TableName = var.file_tracking_table_name
  }

  tags = var.tags
}

###############################################################################
# CloudWatch Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "pipeline" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = "ndjson-parquet-pipeline-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      # Lambda metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Invocations" }],
            [".", "Errors", { stat = "Sum", label = "Errors" }],
            [".", "Throttles", { stat = "Sum", label = "Throttles" }],
            [".", "Duration", { stat = "Average", label = "Avg Duration" }],
            [".", "ConcurrentExecutions", { stat = "Maximum", label = "Max Concurrent" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          title  = "Lambda Metrics - ${var.lambda_function_name}"
          dimensions = {
            FunctionName = var.lambda_function_name
          }
        }
      },
      # DynamoDB metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", { stat = "Sum", label = "Read Units" }],
            [".", "ConsumedWriteCapacityUnits", { stat = "Sum", label = "Write Units" }],
            [".", "UserErrors", { stat = "Sum", label = "User Errors" }],
            [".", "SystemErrors", { stat = "Sum", label = "System Errors" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          title  = "DynamoDB Metrics - ${var.file_tracking_table_name}"
          dimensions = {
            TableName = var.file_tracking_table_name
          }
        }
      },
      # Glue job metrics
      {
        type = "metric"
        properties = {
          metrics = [
            ["Glue", "glue.driver.aggregate.numCompletedTasks", { stat = "Sum", label = "Completed Tasks" }],
            [".", "glue.driver.aggregate.numFailedTasks", { stat = "Sum", label = "Failed Tasks" }],
            [".", "glue.driver.aggregate.numKilledTasks", { stat = "Sum", label = "Killed Tasks" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          title  = "Glue Job Metrics - ${var.glue_job_name}"
          dimensions = {
            JobName = var.glue_job_name
          }
        }
      }
    ]
  })
}

###############################################################################
# Data Sources
###############################################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
