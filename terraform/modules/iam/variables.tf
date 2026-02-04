variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "input_bucket_arn" {
  description = "Input bucket ARN"
  type        = string
}

variable "manifest_bucket_arn" {
  description = "Manifest bucket ARN"
  type        = string
}

variable "output_bucket_arn" {
  description = "Output bucket ARN"
  type        = string
}

variable "quarantine_bucket_arn" {
  description = "Quarantine bucket ARN"
  type        = string
}

variable "scripts_bucket_arn" {
  description = "Scripts bucket ARN"
  type        = string
}

variable "file_tracking_table_arn" {
  description = "File tracking DynamoDB table ARN"
  type        = string
}

variable "metrics_table_arn" {
  description = "Metrics DynamoDB table ARN"
  type        = string
}

variable "sqs_queue_arn" {
  description = "SQS queue ARN"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
