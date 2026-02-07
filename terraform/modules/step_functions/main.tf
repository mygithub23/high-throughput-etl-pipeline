/**
 * Step Functions Module
 *
 * Creates an AWS Step Functions Standard workflow that:
 * - Receives manifest path from Lambda
 * - Updates DynamoDB status to "processing"
 * - Starts Glue job and waits for completion (.sync)
 * - Updates DynamoDB status to "completed" or "failed"
 * - Sends SNS notification on failure
 *
 * Note: Standard (not Express) is required for .sync Glue job integration
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
# CloudWatch Log Group for Step Functions
###############################################################################

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/states/ndjson-parquet-processor-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

###############################################################################
# Step Functions State Machine (Standard - required for .sync Glue integration)
###############################################################################

resource "aws_sfn_state_machine" "processor" {
  name     = "ndjson-parquet-processor-${var.environment}"
  role_arn = var.step_functions_role_arn
  type     = "STANDARD"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  definition = jsonencode({
    Comment = "NDJSON to Parquet Processing Workflow - Orchestrates Glue job execution with state tracking"
    StartAt = "UpdateStatusProcessing"

    States = {
      # Step 1: Update MANIFEST meta-record status to "processing"
      UpdateStatusProcessing = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.file_tracking_table_name
          Key = {
            "date_prefix" = { "S.$" = "$.date_prefix" }
            "file_key"    = { "S.$" = "$.file_key" }
          }
          UpdateExpression         = "SET #status = :status, processing_start_time = :start_time, manifest_path = :manifest_path, file_count = :file_count"
          ExpressionAttributeNames = { "#status" = "status" }
          ExpressionAttributeValues = {
            ":status"        = { "S" = "processing" }
            ":start_time"    = { "S.$" = "$.timestamp" }
            ":manifest_path" = { "S.$" = "$.manifest_path" }
            ":file_count"    = { "N.$" = "States.Format('{}', $.file_count)" }
          }
        }
        ResultPath = "$.dynamodb_update_result"
        Next       = "StartGlueJob"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "UpdateStatusFailed"
        }]
      }

      # Step 2: Start Glue Job and wait for completion
      StartGlueJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = var.glue_job_name
          Arguments = {
            "--MANIFEST_PATH.$"  = "$.manifest_path"
            "--MANIFEST_BUCKET"  = var.manifest_bucket_name
            "--OUTPUT_BUCKET"    = var.output_bucket_name
            "--OUTPUT_PREFIX"    = var.output_bucket_prefix
            "--COMPRESSION_TYPE" = var.compression_type
          }
        }
        ResultPath = "$.glue_result"
        Next       = "UpdateStatusCompleted"
        Retry = [{
          ErrorEquals     = ["Glue.ConcurrentRunsExceededException"]
          IntervalSeconds = 60
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "UpdateStatusFailed"
        }]
      }

      # Step 3a: Success - Update MANIFEST meta-record to "completed"
      UpdateStatusCompleted = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.file_tracking_table_name
          Key = {
            "date_prefix" = { "S.$" = "$.date_prefix" }
            "file_key"    = { "S.$" = "$.file_key" }
          }
          UpdateExpression         = "SET #status = :status, completed_time = :completed_time, glue_job_run_id = :job_run_id"
          ExpressionAttributeNames = { "#status" = "status" }
          ExpressionAttributeValues = {
            ":status"         = { "S" = "completed" }
            ":completed_time" = { "S.$" = "$$.State.EnteredTime" }
            ":job_run_id"     = { "S.$" = "$.glue_result.Id" }
          }
        }
        ResultPath = "$.final_update"
        Next       = "BatchUpdateCompleted"
      }

      # Step 3a-2: Success - Batch update individual file records to "completed"
      BatchUpdateCompleted = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.batch_status_updater_function_name
          Payload = {
            "manifest_path.$"   = "$.manifest_path"
            "date_prefix.$"     = "$.date_prefix"
            "new_status"        = "completed"
            "glue_job_run_id.$" = "$.glue_result.Id"
          }
        }
        ResultPath = "$.batch_update_result"
        Next       = "PipelineSucceeded"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed", "Lambda.ServiceException", "Lambda.SdkClientException"]
          IntervalSeconds = 5
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.batch_update_error"
          Next        = "PipelineSucceeded"
        }]
      }

      # Terminal success state (Glue succeeded; batch update is best-effort)
      PipelineSucceeded = {
        Type = "Succeed"
      }

      # Step 3b: Failure - Update MANIFEST meta-record to "failed"
      UpdateStatusFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.file_tracking_table_name
          Key = {
            "date_prefix" = { "S.$" = "$.date_prefix" }
            "file_key"    = { "S.$" = "$.file_key" }
          }
          UpdateExpression         = "SET #status = :status, failed_time = :failed_time, error_message = :error"
          ExpressionAttributeNames = { "#status" = "status" }
          ExpressionAttributeValues = {
            ":status"      = { "S" = "failed" }
            ":failed_time" = { "S.$" = "$$.State.EnteredTime" }
            ":error"       = { "S.$" = "States.Format('{}', $.error)" }
          }
        }
        ResultPath = "$.failure_update"
        Next       = "BatchUpdateFailed"
      }

      # Step 3b-2: Failure - Batch update individual file records to "failed"
      BatchUpdateFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.batch_status_updater_function_name
          Payload = {
            "manifest_path.$" = "$.manifest_path"
            "date_prefix.$"   = "$.date_prefix"
            "new_status"      = "failed"
            "error_message.$" = "States.Format('{}', $.error)"
          }
        }
        ResultPath = "$.batch_update_failed_result"
        Next       = "SendFailureAlert"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed", "Lambda.ServiceException", "Lambda.SdkClientException"]
          IntervalSeconds = 5
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.batch_update_failed_error"
          Next        = "SendFailureAlert"
        }]
      }

      # Step 4: Send SNS notification on failure
      SendFailureAlert = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = var.sns_topic_arn
          Subject     = "[ALERT] NDJSON Pipeline Failed - ${var.environment}"
          "Message.$" = "States.Format('Pipeline: {} | Date: {} | Manifest: {} | Check Step Functions console for error details.', '${var.environment}', $.date_prefix, $.manifest_path)"
        }
        End = true
      }
    }
  })

  tags = merge(
    var.tags,
    {
      Name        = "NDJSON Parquet Processor"
      Description = "Step Functions workflow for NDJSON to Parquet processing"
    }
  )
}
