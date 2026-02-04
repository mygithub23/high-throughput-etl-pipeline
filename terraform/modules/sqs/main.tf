/**
 * SQS Module
 *
 * Creates SQS infrastructure for enhanced reliability:
 * - Main queue for file events
 * - Dead Letter Queue (DLQ) for failed messages
 * - Lambda event source mapping
 * - CloudWatch alarms for queue monitoring
 *
 * Provides better reliability, throttle protection, and DLQ capabilities
 * compared to direct S3 → Lambda triggers.
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
# Dead Letter Queue
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "ndjson-parquet-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(
    var.tags,
    {
      Name        = "Pipeline DLQ"
      Description = "Dead letter queue for failed file events"
    }
  )
}

###############################################################################
# Main Queue
###############################################################################

resource "aws_sqs_queue" "main" {
  name                       = "ndjson-parquet-file-events-${var.environment}"
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20 # Enable long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  # Enable encryption in production
  sqs_managed_sse_enabled = var.enable_encryption

  tags = merge(
    var.tags,
    {
      Name        = "Pipeline File Events Queue"
      Description = "Queue for NDJSON file processing events"
    }
  )
}

###############################################################################
# Queue Policy (Allow S3 to Send Messages)
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = var.input_bucket_arn
          }
        }
      }
    ]
  })
}

###############################################################################
# S3 Bucket Notification to SQS
###############################################################################

resource "aws_s3_bucket_notification" "input_to_sqs" {
  bucket = var.input_bucket_id

  queue {
    queue_arn     = aws_sqs_queue.main.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.input_bucket_prefix
    filter_suffix = ".ndjson"
  }

  depends_on = [aws_sqs_queue_policy.main]
}

###############################################################################
# Lambda Event Source Mapping
###############################################################################

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = var.lambda_function_arn
  batch_size       = var.batch_size
  enabled          = true

  # Configure scaling - match Lambda reserved concurrency
  scaling_config {
    maximum_concurrency = var.environment == "prod" ? 50 : 2
  }

  # Configure failure handling
  function_response_types = ["ReportBatchItemFailures"]
}

###############################################################################
# CloudWatch Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-SQS-QueueDepth-WARNING"
  alarm_description   = "Alert when queue depth is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 1000
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "message_age" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-SQS-MessageAge-WARNING"
  alarm_description   = "Alert when messages are old"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 3600 # 1 hour
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  count               = var.create_alarms ? 1 : 0
  alarm_name          = "${var.environment}-DLQ-Messages-CRITICAL"
  alarm_description   = "Alert when messages arrive in DLQ"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  tags = var.tags
}
