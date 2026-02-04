variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "message_retention_seconds" {
  description = "Message retention period in seconds"
  type        = number
  default     = 345600 # 4 days
}

variable "visibility_timeout" {
  description = "Visibility timeout in seconds"
  type        = number
  default     = 360 # 6 minutes (2x Lambda timeout)
}

variable "max_receive_count" {
  description = "Maximum receives before sending to DLQ"
  type        = number
  default     = 3
}

variable "batch_size" {
  description = "Lambda event source mapping batch size"
  type        = number
  default     = 10
}

variable "lambda_function_arn" {
  description = "Lambda function ARN for event source mapping"
  type        = string
}

variable "input_bucket_arn" {
  description = "Input bucket ARN for SQS policy"
  type        = string
}

variable "input_bucket_id" {
  description = "Input bucket ID for S3 notification"
  type        = string
}

variable "input_bucket_prefix" {
  description = "S3 prefix to filter events"
  type        = string
  default     = ""
}

variable "enable_encryption" {
  description = "Enable SQS encryption"
  type        = bool
  default     = false
}

variable "create_alarms" {
  description = "Create CloudWatch alarms"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
