/**
 * Root Module Variables
 *
 * All input variables for the NDJSON to Parquet pipeline infrastructure
 */

###############################################################################
# Environment Configuration
###############################################################################

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

###############################################################################
# S3 Configuration
###############################################################################

# Bucket  
variable "create_input_bucket" {
  description = "Whether to create input bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_input_bucket_name" {
  description = "Name of existing input bucket (only used if create_input_bucket = false)"
  type        = string
  default     = "ndjson-parquet-input-sqs-<ACCOUNT>"
}

variable "create_output_bucket" {
  description = "Whether to create output bucket (set to false to use existing bucket)"
  type        = bool
  default     = false
}

variable "existing_output_bucket_name" {
  description = "Name of existing output bucket (only used if create_output_bucket = false)"
  type        = string
  default     = ""
}

variable "create_manifest_bucket" {
  description = "Whether to create manifest bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_manifest_bucket_name" {
  description = "Name of existing manifest bucket (only used if create_manifest_bucket = false)"
  type        = string
  default     = ""
}

variable "create_quarantine_bucket" {
  description = "Whether to create quarantine bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_quarantine_bucket_name" {
  description = "Name of existing quarantine bucket (only used if create_quarantine_bucket = false)"
  type        = string
  default     = ""
}

variable "create_scripts_bucket" {
  description = "Whether to create scripts bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "existing_scripts_bucket_name" {
  description = "Name of existing scripts bucket (only used if create_scripts_bucket = false)"
  type        = string
  default     = ""
}

# Bucket prefixes

variable "input_bucket_prefix" {
  description = "S3 prefix (folder path) for input files (e.g., 'raw-data' for s3://bucket/raw-data/)"
  type        = string
  default     = "landing/ndjson"
}

variable "output_bucket_prefix" {
  description = "S3 prefix (folder path) for output files (e.g., 'parquet' for s3://bucket/parquet/)"
  type        = string
  default     = "parquet"
}

variable "manifest_bucket_prefix" {
  description = "S3 prefix (folder path) for manifest files (e.g., 'manifests' for s3://bucket/manifests/)"
  type        = string
  default     = "manifests"
}

variable "quarantine_bucket_prefix" {
  description = "S3 prefix (folder path) for quarantined files (e.g., 'quarantine' for s3://bucket/quarantine/)"
  type        = string
  default     = "quarantine"
}

variable "scripts_bucket_prefix" {
  description = "S3 prefix (folder path) for Lambda/Glue scripts (e.g., 'scripts' for s3://bucket/scripts/)"
  type        = string
  default     = "scripts"
}

variable "glue_logs_prefix" {
  description = "S3 prefix (folder path) for Glue logs (e.g., 'logs/glue' for s3://bucket/logs/glue/)"
  type        = string
  default     = "logs/glue"
}

variable "glue_temp_prefix" {
  description = "S3 prefix (folder path) for Glue temp files (e.g., 'temp/glue' for s3://bucket/temp/glue/)"
  type        = string
  default     = "temp/glue"
}

# lifecycle 

variable "input_lifecycle_days" {
  description = "Number of days to retain files in input bucket (only applies if creating new bucket)"
  type        = number
  default     = 7
}

variable "manifest_lifecycle_days" {
  description = "Number of days to retain manifest files"
  type        = number
  default     = 3
}

variable "quarantine_lifecycle_days" {
  description = "Number of days to retain quarantined files"
  type        = number
  default     = 30
}

###############################################################################
# DynamoDB Configuration
###############################################################################

variable "dynamodb_read_capacity" {
  description = "DynamoDB read capacity units"
  type        = number
  default     = 10
}

variable "dynamodb_write_capacity" {
  description = "DynamoDB write capacity units"
  type        = number
  default     = 10
}

variable "dynamodb_ttl_days" {
  description = "Number of days to retain DynamoDB records"
  type        = number
  default     = 30
}

###############################################################################
# Lambda Configuration
###############################################################################

variable "lambda_manifest_memory" {
  description = "Memory size for manifest builder Lambda (MB)"
  type        = number
  default     = 1024
}

variable "lambda_manifest_timeout" {
  description = "Timeout for manifest builder Lambda (seconds)"
  type        = number
  default     = 180
}

variable "lambda_manifest_concurrency" {
  description = "Reserved concurrent executions for manifest builder"
  type        = number
  default     = 50
}

###############################################################################
# Manifest Builder Configuration
###############################################################################

variable "max_files_per_manifest" {
  description = "Maximum number of files per manifest - triggers manifest creation when reached"
  type        = number
  default     = 10
}

variable "expected_file_size_mb" {
  description = "Expected file size in MB"
  type        = number
  default     = 4096
}

variable "size_tolerance_percent" {
  description = "Size tolerance percentage for validation"
  type        = number
  default     = 10
}

###############################################################################
# Glue Configuration
###############################################################################

variable "glue_version" {
  description = "AWS Glue version"
  type        = string
  default     = "4.0"
}

variable "glue_worker_type" {
  description = "Glue worker type (G.1X, G.2X, G.4X, G.8X)"
  type        = string
  default     = "G.2X"
}

variable "glue_number_of_workers" {
  description = "Number of Glue workers"
  type        = number
  default     = 20
}

variable "glue_max_concurrent_runs" {
  description = "Maximum concurrent Glue job runs"
  type        = number
  default     = 30
}

variable "glue_timeout" {
  description = "Glue job timeout in minutes"
  type        = number
  default     = 2880 # 48 hours
}

variable "glue_max_retries" {
  description = "Maximum number of Glue job retries"
  type        = number
  default     = 1
}

###############################################################################
# Monitoring Configuration
###############################################################################

variable "alert_email" {
  description = "Email address for CloudWatch alerts"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 7
}

variable "create_dashboard" {
  description = "Create CloudWatch dashboard"
  type        = bool
  default     = true
}

###############################################################################
# SQS Configuration
###############################################################################

variable "sqs_message_retention_seconds" {
  description = "SQS message retention period in seconds"
  type        = number
  default     = 345600 # 4 days
}

variable "sqs_visibility_timeout" {
  description = "SQS visibility timeout in seconds"
  type        = number
  default     = 360 # 6 minutes
}

variable "sqs_max_receive_count" {
  description = "Maximum receives before sending to DLQ"
  type        = number
  default     = 3
}

variable "sqs_batch_size" {
  description = "Lambda event source mapping batch size"
  type        = number
  default     = 10
}

###############################################################################
# Phase 3: Scaling Configuration
###############################################################################

variable "enable_eventbridge_decoupling" {
  description = "Enable EventBridge-based Step Functions invocation instead of direct"
  type        = bool
  default     = false
}

variable "num_status_shards" {
  description = "Number of GSI write shards for DynamoDB status partitioning"
  type        = number
  default     = 10
}

variable "enable_stream_manifest_creation" {
  description = "Enable DynamoDB Streams-based manifest creation"
  type        = bool
  default     = false
}
