variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "glue_role_arn" {
  description = "IAM role ARN for Glue job"
  type        = string
}

variable "glue_version" {
  description = "Glue version to use"
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type (G.1X, G.2X, etc.)"
  type        = string
  default     = "G.2X"
}

variable "number_of_workers" {
  description = "Number of Glue workers"
  type        = number
  default     = 20
}

variable "timeout" {
  description = "Job timeout in minutes"
  type        = number
  default     = 2880
}

variable "max_retries" {
  description = "Maximum number of retries"
  type        = number
  default     = 1
}

variable "max_concurrent_runs" {
  description = "Maximum concurrent Glue job runs"
  type        = number
  default     = 30
}

variable "manifest_bucket_name" {
  description = "S3 manifest bucket name"
  type        = string
}

variable "output_bucket_name" {
  description = "S3 output bucket name"
  type        = string
}

variable "input_bucket_name" {
  description = "S3 input bucket name"
  type        = string
}

variable "quarantine_bucket_name" {
  description = "S3 quarantine bucket name"
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

variable "glue_logs_prefix" {
  description = "S3 prefix for Glue logs"
  type        = string
  default     = "logs/glue"
}

variable "glue_temp_prefix" {
  description = "S3 prefix for Glue temp files"
  type        = string
  default     = "temp/glue"
}

variable "file_tracking_table_name" {
  description = "DynamoDB file tracking table name"
  type        = string
}

variable "metrics_table_name" {
  description = "DynamoDB metrics table name"
  type        = string
}

variable "script_bucket_name" {
  description = "S3 bucket containing Glue script"
  type        = string
}

variable "manifest_bucket_name_for_trigger" {
  description = "Manifest bucket name for EventBridge trigger"
  type        = string
}

variable "eventbridge_role_arn" {
  description = "IAM role ARN for EventBridge to trigger Glue"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 7
}

variable "compression_type" {
  description = "Parquet compression codec"
  type        = string
  default     = "snappy"
  validation {
    condition     = contains(["snappy", "gzip", "lzo", "brotli", "lz4", "zstd"], var.compression_type)
    error_message = "compression_type must be a valid Parquet codec."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
