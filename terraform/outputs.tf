/**
 * Root Module Outputs
 *
 * All outputs from the NDJSON to Parquet pipeline infrastructure
 */

###############################################################################
# S3 Bucket Outputs
###############################################################################

output "input_bucket_name" {
  description = "Input bucket name"
  value       = module.s3.input_bucket_name
}

output "manifest_bucket_name" {
  description = "Manifest bucket name"
  value       = module.s3.manifest_bucket_name
}

output "output_bucket_name" {
  description = "Output bucket name"
  value       = module.s3.output_bucket_name
}

output "quarantine_bucket_name" {
  description = "Quarantine bucket name"
  value       = module.s3.quarantine_bucket_name
}

output "scripts_bucket_name" {
  description = "Scripts bucket name"
  value       = module.s3.scripts_bucket_name
}

###############################################################################
# DynamoDB Table Outputs
###############################################################################

output "file_tracking_table_name" {
  description = "File tracking table name"
  value       = module.dynamodb.file_tracking_table_name
}

output "metrics_table_name" {
  description = "Metrics table name"
  value       = module.dynamodb.metrics_table_name
}

###############################################################################
# Lambda Function Outputs
###############################################################################

output "manifest_builder_function_name" {
  description = "Manifest builder Lambda function name"
  value       = module.lambda.manifest_builder_function_name
}

output "manifest_builder_function_arn" {
  description = "Manifest builder Lambda function ARN"
  value       = module.lambda.manifest_builder_function_arn
}

# Control plane outputs removed - module no longer exists

# State management output - DISABLED (module disabled, to be enabled later)
# output "state_management_function_name" {
#   description = "State management Lambda function name"
#   value       = module.state_management.state_management_function_name
# }

# API URL output removed - API Gateway feature permanently disabled

###############################################################################
# Glue Job Outputs
###############################################################################

output "glue_job_name" {
  description = "Glue job name"
  value       = module.glue.job_name
}

###############################################################################
# Monitoring Outputs
###############################################################################

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = module.monitoring.sns_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.monitoring.dashboard_name
}

###############################################################################
# SQS Outputs
###############################################################################

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = module.sqs.queue_url
}

output "sqs_queue_name" {
  description = "SQS queue name"
  value       = module.sqs.queue_name
}

output "sqs_dlq_url" {
  description = "SQS DLQ URL"
  value       = module.sqs.dlq_url
}

output "sqs_dlq_name" {
  description = "SQS DLQ name"
  value       = module.sqs.dlq_name
}

###############################################################################
# Step Functions Outputs
###############################################################################

output "step_function_arn" {
  description = "Step Functions state machine ARN"
  value       = module.step_functions.state_machine_arn
}

output "step_function_name" {
  description = "Step Functions state machine name"
  value       = module.step_functions.state_machine_name
}

###############################################################################
# General Information
###############################################################################

output "environment" {
  description = "Deployment environment"
  value       = var.environment
}

output "region" {
  description = "AWS region"
  value       = local.region
}

output "account_id" {
  description = "AWS account ID"
  value       = local.account_id
}
