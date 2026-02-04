/**
 * NDJSON to Parquet Pipeline - Main Terraform Configuration
 *
 * This is the root module that orchestrates all pipeline components using
 * modular Terraform configuration.
 *
 * Architecture:
 * - S3 buckets for input, manifest, output, quarantine
 * - DynamoDB tables for file tracking and metrics
 * - Lambda functions for manifest building, control plane, and state management
 * - Glue jobs for batch processing
 * - CloudWatch monitoring with SNS alerts
 * - SQS/DLQ for enhanced reliability
 */

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  common_tags = {
    Project     = "ndjson-parquet-pipeline"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # Naming convention
  name_prefix = "ndjson-parquet"
}

###############################################################################
# S3 Buckets Module
###############################################################################

module "s3" {
  source = "./modules/s3"

  environment = var.environment
  account_id  = local.account_id

  # Optional bucket creation
  create_input_bucket      = var.create_input_bucket
  input_bucket_name        = var.existing_input_bucket_name
  create_output_bucket     = var.create_output_bucket
  output_bucket_name       = var.existing_output_bucket_name
  create_manifest_bucket   = var.create_manifest_bucket
  manifest_bucket_name     = var.existing_manifest_bucket_name
  create_quarantine_bucket = var.create_quarantine_bucket
  quarantine_bucket_name   = var.existing_quarantine_bucket_name
  create_scripts_bucket    = var.create_scripts_bucket
  scripts_bucket_name      = var.existing_scripts_bucket_name

  # Bucket prefixes
  input_bucket_prefix  = var.input_bucket_prefix
  output_bucket_prefix = var.output_bucket_prefix

  # Lifecycle policies
  input_lifecycle_days      = var.input_lifecycle_days
  manifest_lifecycle_days   = var.manifest_lifecycle_days
  quarantine_lifecycle_days = var.quarantine_lifecycle_days

  # Enable versioning for production
  enable_versioning = var.environment == "prod"

  tags = local.common_tags
}

###############################################################################
# DynamoDB Tables Module
###############################################################################

module "dynamodb" {
  source = "./modules/dynamodb"

  environment = var.environment

  # Capacity settings
  file_tracking_read_capacity  = var.dynamodb_read_capacity
  file_tracking_write_capacity = var.dynamodb_write_capacity
  metrics_read_capacity        = var.dynamodb_read_capacity
  metrics_write_capacity       = var.dynamodb_write_capacity

  # TTL settings
  ttl_days = var.dynamodb_ttl_days

  # Enable point-in-time recovery for production
  enable_point_in_time_recovery = var.environment == "prod"

  tags = local.common_tags
}

###############################################################################
# IAM Roles Module
###############################################################################

module "iam" {
  source = "./modules/iam"

  environment = var.environment

  # S3 bucket ARNs
  input_bucket_arn      = module.s3.input_bucket_arn
  manifest_bucket_arn   = module.s3.manifest_bucket_arn
  output_bucket_arn     = module.s3.output_bucket_arn
  quarantine_bucket_arn = module.s3.quarantine_bucket_arn
  scripts_bucket_arn    = module.s3.scripts_bucket_arn

  # DynamoDB table ARNs
  file_tracking_table_arn = module.dynamodb.file_tracking_table_arn
  metrics_table_arn       = module.dynamodb.metrics_table_arn

  # SQS queue ARN
  sqs_queue_arn = module.sqs.queue_arn

  # SNS topic ARN (for Step Functions alerts)
  sns_topic_arn = module.monitoring.sns_topic_arn

  # Specific resource ARNs for least-privilege IAM (replacing wildcards)
  # Constructed deterministically to avoid circular dependencies
  step_function_arn = "arn:aws:states:${local.region}:${local.account_id}:stateMachine:ndjson-parquet-processor-${var.environment}"
  glue_job_arn      = "arn:aws:glue:${local.region}:${local.account_id}:job/ndjson-parquet-batch-job-${var.environment}"
  lambda_dlq_arn    = "arn:aws:sqs:${local.region}:${local.account_id}:ndjson-parquet-lambda-dlq-${var.environment}"

  tags = local.common_tags
}

###############################################################################
# Lambda Functions Module
###############################################################################

module "lambda" {
  source = "./modules/lambda"

  environment = var.environment

  # Manifest Builder Lambda
  manifest_builder_memory      = var.lambda_manifest_memory
  manifest_builder_timeout     = var.lambda_manifest_timeout
  manifest_builder_concurrency = var.lambda_manifest_concurrency

  # Environment variables
  input_bucket_name        = module.s3.input_bucket_name
  output_bucket_name       = module.s3.output_bucket_name
  input_bucket_prefix      = var.input_bucket_prefix
  output_bucket_prefix     = var.output_bucket_prefix
  manifest_bucket_name     = module.s3.manifest_bucket_name
  manifest_bucket_prefix   = var.manifest_bucket_prefix
  quarantine_bucket_name   = module.s3.quarantine_bucket_name
  quarantine_bucket_prefix = var.quarantine_bucket_prefix
  file_tracking_table_name = module.dynamodb.file_tracking_table_name
  metrics_table_name       = module.dynamodb.metrics_table_name
  max_files_per_manifest   = var.max_files_per_manifest
  expected_file_size_mb    = var.expected_file_size_mb
  size_tolerance_percent   = var.size_tolerance_percent

  # IAM role
  lambda_role_arn = module.iam.lambda_role_arn

  # Scripts bucket for code
  scripts_bucket_name = module.s3.scripts_bucket_name

  # Log retention
  log_retention_days = var.log_retention_days

  # DynamoDB TTL
  ttl_days = var.dynamodb_ttl_days

  # Logging - DEBUG for dev, INFO for production
  log_level = var.environment == "prod" ? "INFO" : "DEBUG"

  # SNS topic for alarm notifications
  alarm_sns_topic_arn = module.monitoring.sns_topic_arn

  # Step Functions ARN for triggering workflow after manifest creation
  # Constructed deterministically to avoid circular dependency with monitoring module
  step_function_arn = "arn:aws:states:${local.region}:${local.account_id}:stateMachine:ndjson-parquet-processor-${var.environment}"

  tags = local.common_tags

  depends_on = [module.iam]
}

###############################################################################
# Control Plane Lambda Module - REMOVED
###############################################################################

# Control plane module has been removed - functionality covered by:
# - State Management Lambda (automated maintenance and queries)
# - CloudWatch Dashboard (monitoring and metrics)
# - CloudWatch Alarms (alerting)
# - Direct DynamoDB queries (ad-hoc investigation)

###############################################################################
# State Management Lambda Module - DISABLED (to be enabled later)
###############################################################################

# This module provides admin/ops utilities for the pipeline:
# - Query file states and statistics
# - Find orphaned/stuck files
# - Reset stuck files
# - Validate consistency
#
# The core ETL pipeline works WITHOUT this module.
# To re-enable: uncomment the module block below and the output in outputs.tf

# module "state_management" {
#   source = "./modules/state_management"
#
#   environment = var.environment
#
#   # Configuration
#   memory_size = 512
#   timeout     = 300
#
#   # Environment variables
#   file_tracking_table_name = module.dynamodb.file_tracking_table_name
#   metrics_table_name       = module.dynamodb.metrics_table_name
#   input_bucket_name        = module.s3.input_bucket_name
#   manifest_bucket_name     = module.s3.manifest_bucket_name
#   output_bucket_name       = module.s3.output_bucket_name
#   quarantine_bucket_name   = module.s3.quarantine_bucket_name
#
#   # IAM role
#   role_arn = module.iam.state_management_role_arn
#
#   # Scripts bucket for code
#   scripts_bucket_name = module.s3.scripts_bucket_name
#
#   # Log retention
#   log_retention_days = var.log_retention_days
#
#   # Enable schedules in production only (internal health checks)
#   enable_schedules = var.environment == "prod"
#
#   tags = local.common_tags
#
#   depends_on = [module.iam]
# }

###############################################################################
# Glue Job Module
###############################################################################

module "glue" {
  source = "./modules/glue"

  environment = var.environment

  # Glue job configuration
  glue_version        = var.glue_version
  worker_type         = var.glue_worker_type
  number_of_workers   = var.glue_number_of_workers
  max_concurrent_runs = var.glue_max_concurrent_runs
  timeout             = var.glue_timeout
  max_retries         = var.glue_max_retries

  # Environment variables
  input_bucket_name        = module.s3.input_bucket_name
  input_bucket_prefix      = var.input_bucket_prefix
  manifest_bucket_name     = module.s3.manifest_bucket_name
  manifest_bucket_prefix   = var.manifest_bucket_prefix
  output_bucket_name       = module.s3.output_bucket_name
  output_bucket_prefix     = var.output_bucket_prefix
  quarantine_bucket_name   = module.s3.quarantine_bucket_name
  quarantine_bucket_prefix = var.quarantine_bucket_prefix
  glue_logs_prefix         = var.glue_logs_prefix
  glue_temp_prefix         = var.glue_temp_prefix
  file_tracking_table_name = module.dynamodb.file_tracking_table_name
  metrics_table_name       = module.dynamodb.metrics_table_name

  # IAM role
  glue_role_arn = module.iam.glue_role_arn

  # Script location
  script_bucket_name = module.s3.scripts_bucket_name

  # EventBridge trigger
  manifest_bucket_name_for_trigger = module.s3.manifest_bucket_name
  eventbridge_role_arn             = module.iam.eventbridge_role_arn

  # Log retention
  log_retention_days = var.log_retention_days

  tags = local.common_tags

  depends_on = [module.iam]
}

###############################################################################
# Monitoring Module
###############################################################################

module "monitoring" {
  source = "./modules/monitoring"

  environment = var.environment

  # SNS configuration
  alert_email = var.alert_email

  # Resources to monitor
  lambda_function_name     = module.lambda.manifest_builder_function_name
  glue_job_name            = module.glue.job_name
  file_tracking_table_name = module.dynamodb.file_tracking_table_name
  metrics_table_name       = module.dynamodb.metrics_table_name

  # Step Functions monitoring
  step_function_name = "ndjson-parquet-processor-${var.environment}"

  # Lambda configuration for alarms
  lambda_timeout = var.lambda_manifest_timeout

  # SQS monitoring
  sqs_queue_name = "ndjson-parquet-file-events-${var.environment}"
  sqs_dlq_name   = "ndjson-parquet-dlq-${var.environment}"

  # Create alarms only in production
  create_alarms = var.environment == "prod"

  # Create dashboard
  create_dashboard = var.create_dashboard

  tags = local.common_tags
}

###############################################################################
# SQS Module
###############################################################################

module "sqs" {
  source = "./modules/sqs"

  environment = var.environment

  # Queue configuration
  message_retention_seconds = var.sqs_message_retention_seconds
  visibility_timeout        = var.sqs_visibility_timeout
  max_receive_count         = var.sqs_max_receive_count
  batch_size                = var.sqs_batch_size

  # Lambda function for event source mapping
  lambda_function_arn = module.lambda.manifest_builder_function_arn

  # Input bucket for S3 → SQS notification
  input_bucket_arn    = module.s3.input_bucket_arn
  input_bucket_id     = module.s3.input_bucket_id
  input_bucket_prefix = var.input_bucket_prefix

  # Enable encryption in production
  enable_encryption = var.environment == "prod"

  # Create alarms in production
  create_alarms = var.environment == "prod"

  tags = local.common_tags
}

###############################################################################
# Step Functions Module
###############################################################################

module "step_functions" {
  source = "./modules/step_functions"

  environment = var.environment
  aws_region  = var.aws_region

  # Glue job information
  glue_job_name = module.glue.job_name
  glue_job_arn  = module.glue.job_arn

  # DynamoDB table information
  file_tracking_table_name = module.dynamodb.file_tracking_table_name
  file_tracking_table_arn  = module.dynamodb.file_tracking_table_arn

  # SNS topic for failure alerts
  sns_topic_arn = module.monitoring.sns_topic_arn

  # IAM role
  step_functions_role_arn = module.iam.step_functions_role_arn

  # S3 bucket information for Glue job arguments
  manifest_bucket_name = module.s3.manifest_bucket_name
  output_bucket_name   = module.s3.output_bucket_name
  output_bucket_prefix = var.output_bucket_prefix
  compression_type     = "snappy"

  # Log retention
  log_retention_days = var.log_retention_days

  tags = local.common_tags

  depends_on = [module.iam, module.glue, module.monitoring]
}
