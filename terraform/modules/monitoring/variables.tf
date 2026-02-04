variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
  default     = ""
}

variable "lambda_function_name" {
  description = "Lambda function name to monitor"
  type        = string
}

variable "glue_job_name" {
  description = "Glue job name to monitor"
  type        = string
}

variable "file_tracking_table_name" {
  description = "DynamoDB file tracking table name"
  type        = string
}

variable "metrics_table_name" {
  description = "DynamoDB metrics table name"
  type        = string
}

variable "create_alarms" {
  description = "Create CloudWatch alarms"
  type        = bool
  default     = true
}

variable "create_dashboard" {
  description = "Create CloudWatch dashboard"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "step_function_name" {
  description = "Step Functions state machine name to monitor"
  type        = string
  default     = ""
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds (for duration alarm threshold)"
  type        = number
  default     = 300
}

variable "sqs_queue_name" {
  description = "SQS queue name to monitor"
  type        = string
  default     = ""
}

variable "sqs_dlq_name" {
  description = "SQS DLQ name to monitor"
  type        = string
  default     = ""
}
