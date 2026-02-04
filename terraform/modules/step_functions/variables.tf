variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "aws_region" {
  description = "AWS region for console links in notifications"
  type        = string
  default     = "us-east-1"
}

variable "glue_job_name" {
  description = "Name of the Glue job to execute"
  type        = string
}

variable "glue_job_arn" {
  description = "ARN of the Glue job"
  type        = string
}

variable "file_tracking_table_name" {
  description = "DynamoDB file tracking table name"
  type        = string
}

variable "file_tracking_table_arn" {
  description = "DynamoDB file tracking table ARN"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for failure notifications"
  type        = string
}

variable "step_functions_role_arn" {
  description = "IAM role ARN for Step Functions"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "manifest_bucket_name" {
  description = "S3 bucket name for manifests"
  type        = string
}

variable "output_bucket_name" {
  description = "S3 bucket name for Parquet output"
  type        = string
}

variable "output_bucket_prefix" {
  description = "S3 prefix for Parquet output files"
  type        = string
  default     = ""
}

variable "compression_type" {
  description = "Parquet compression type (snappy, gzip, lzo, uncompressed)"
  type        = string
  default     = "snappy"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
