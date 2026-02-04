variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "lambda_role_arn" {
  description = "IAM role ARN for Lambda function"
  type        = string
}

variable "manifest_builder_memory" {
  description = "Memory size in MB for manifest builder Lambda"
  type        = number
  default     = 1024
}

variable "manifest_builder_timeout" {
  description = "Timeout in seconds for manifest builder Lambda"
  type        = number
  default     = 300
}

variable "manifest_builder_concurrency" {
  description = "Reserved concurrent executions for manifest builder"
  type        = number
  default     = 50
}

variable "file_tracking_table_name" {
  description = "DynamoDB file tracking table name"
  type        = string
}

variable "metrics_table_name" {
  description = "DynamoDB metrics table name"
  type        = string
}

variable "manifest_bucket_name" {
  description = "S3 manifest bucket name"
  type        = string
}

variable "quarantine_bucket_name" {
  description = "S3 quarantine bucket name"
  type        = string
}

variable "max_files_per_manifest" {
  description = "Maximum number of files per manifest (triggers manifest creation)"
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

variable "scripts_bucket_name" {
  description = "S3 bucket containing Lambda code"
  type        = string
}

variable "input_bucket_name" {
  description = "Input bucket name for environment variable"
  type        = string
}

variable "output_bucket_name" {
  description = "Output bucket name for environment variable"
  type        = string
}

variable "input_bucket_prefix" {
  description = "S3 prefix for input files"
  type        = string
  default     = ""
}

variable "output_bucket_prefix" {
  description = "S3 prefix for output files"
  type        = string
  default     = "parquet"
}

variable "manifest_bucket_prefix" {
  description = "S3 prefix for manifest files"
  type        = string
  default     = "manifests"
}

variable "quarantine_bucket_prefix" {
  description = "S3 prefix for quarantine files"
  type        = string
  default     = "quarantine"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 7
}

variable "step_function_arn" {
  description = "Step Functions state machine ARN"
  type        = string
  default     = ""
}

variable "ttl_days" {
  description = "Number of days before DynamoDB records expire (TTL)"
  type        = number
  default     = 30
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Logging level for Lambda function"
  type        = string
  default     = "INFO"
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be DEBUG, INFO, WARNING, or ERROR."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
