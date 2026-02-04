variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "role_arn" {
  description = "IAM role ARN for state management Lambda"
  type        = string
}

variable "memory_size" {
  description = "Memory size in MB"
  type        = number
  default     = 512
}

variable "timeout" {
  description = "Timeout in seconds"
  type        = number
  default     = 300
}

variable "file_tracking_table_name" {
  description = "DynamoDB file tracking table name"
  type        = string
}

variable "metrics_table_name" {
  description = "DynamoDB metrics table name"
  type        = string
}

variable "input_bucket_name" {
  description = "S3 input bucket name"
  type        = string
}

variable "manifest_bucket_name" {
  description = "S3 manifest bucket name"
  type        = string
}

variable "output_bucket_name" {
  description = "S3 output bucket name"
  type        = string
}

variable "quarantine_bucket_name" {
  description = "S3 quarantine bucket name"
  type        = string
}

variable "scripts_bucket_name" {
  description = "S3 bucket containing Lambda code"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 7
}

# API Gateway variable removed - feature permanently disabled for security

variable "enable_schedules" {
  description = "Enable EventBridge scheduled health checks"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
