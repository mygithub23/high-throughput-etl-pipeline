/**
 * AWS Glue Job Module
 *
 * Creates the Glue batch processing job that:
 * - Reads manifest files from S3
 * - Processes NDJSON files in parallel
 * - Converts to Parquet format
 * - Writes to output bucket
 * - Updates file tracking in DynamoDB
 * - Triggered by EventBridge when manifests are created
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
# Glue Job
###############################################################################

resource "aws_glue_job" "batch_processor" {
  name     = "ndjson-parquet-batch-job-${var.environment}"
  role_arn = var.glue_role_arn

  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.timeout
  max_retries       = var.max_retries

  command {
    name            = "glueetl"
    script_location = "s3://${var.script_bucket_name}/glue/${var.environment}/glue_batch_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${var.script_bucket_name}/${var.glue_logs_prefix}/${var.environment}/"
    "--enable-job-insights"              = "true"
    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${var.script_bucket_name}/${var.glue_temp_prefix}/${var.environment}/"

    # Environment variables
    "--INPUT_BUCKET"      = var.input_bucket_name
    "--INPUT_PREFIX"      = var.input_bucket_prefix
    "--MANIFEST_BUCKET"   = var.manifest_bucket_name
    "--MANIFEST_PREFIX"   = var.manifest_bucket_prefix
    "--OUTPUT_BUCKET"     = var.output_bucket_name
    "--OUTPUT_PREFIX"     = var.output_bucket_prefix
    "--QUARANTINE_BUCKET" = var.quarantine_bucket_name
    "--QUARANTINE_PREFIX" = var.quarantine_bucket_prefix
    "--TRACKING_TABLE"    = var.file_tracking_table_name
    "--METRICS_TABLE"     = var.metrics_table_name
    "--ENVIRONMENT"       = var.environment
  }

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  tags = merge(
    var.tags,
    {
      Name        = "Glue Batch Processor"
      Description = "Converts NDJSON files to Parquet format"
    }
  )
}

###############################################################################
# EventBridge Rule for Manifest Trigger
###############################################################################

# NOTE: EventBridge cannot directly trigger Glue jobs.
# TODO: Implement Glue job triggering via Lambda function in manifest builder
# For now, Glue jobs must be triggered manually or via AWS SDK from Lambda

# resource "aws_cloudwatch_event_rule" "manifest_created" {
#   name        = "ndjson-parquet-manifest-trigger-${var.environment}"
#   description = "Trigger Glue job when manifest is created"
#
#   event_pattern = jsonencode({
#     source      = ["aws.s3"]
#     detail-type = ["Object Created"]
#     detail = {
#       bucket = {
#         name = [var.manifest_bucket_name_for_trigger]
#       }
#       object = {
#         key = [{
#           suffix = ".json"
#         }]
#       }
#     }
#   })
#
#   tags = var.tags
# }
#
# resource "aws_cloudwatch_event_target" "glue_job" {
#   rule      = aws_cloudwatch_event_rule.manifest_created.name
#   target_id = "GlueJobTarget"
#   arn       = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.batch_processor.name}"
#   role_arn  = var.eventbridge_role_arn
#
#   input_transformer {
#     input_paths = {
#       bucket = "$.detail.bucket.name"
#       key    = "$.detail.object.key"
#     }
#     input_template = jsonencode({
#       "--MANIFEST_KEY" = "<key>"
#     })
#   }
# }

# data "aws_region" "current" {}
# data "aws_caller_identity" "current" {}

###############################################################################
# CloudWatch Log Group for Glue Job
###############################################################################

resource "aws_cloudwatch_log_group" "glue_job" {
  name              = "/aws-glue/jobs/${aws_glue_job.batch_processor.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

###############################################################################
# CloudWatch Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "glue_job_failures" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${var.environment}-GlueJob-Failures-CRITICAL"
  alarm_description   = "Alert when Glue job has failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = aws_glue_job.batch_processor.name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "glue_job_timeout" {
  count               = var.environment == "prod" ? 1 : 0
  alarm_name          = "${var.environment}-GlueJob-Timeout-WARNING"
  alarm_description   = "Alert when Glue job approaches timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.ExecutorAllocationManager.executors.numberAllExecutors"
  namespace           = "Glue"
  period              = 300
  statistic           = "Average"
  threshold           = var.number_of_workers * 0.9
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = aws_glue_job.batch_processor.name
  }

  tags = var.tags
}
