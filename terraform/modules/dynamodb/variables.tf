variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "file_tracking_read_capacity" {
  description = "Read capacity units for file tracking table"
  type        = number
  default     = 10
}

variable "file_tracking_write_capacity" {
  description = "Write capacity units for file tracking table"
  type        = number
  default     = 10
}

variable "metrics_read_capacity" {
  description = "Read capacity units for metrics table"
  type        = number
  default     = 5
}

variable "metrics_write_capacity" {
  description = "Write capacity units for metrics table"
  type        = number
  default     = 5
}

variable "ttl_days" {
  description = "Number of days to retain records (for TTL calculation)"
  type        = number
  default     = 30
}

variable "enable_point_in_time_recovery" {
  description = "Enable point-in-time recovery for DynamoDB tables"
  type        = bool
  default     = false
}

variable "enable_autoscaling" {
  description = "Enable auto-scaling for DynamoDB tables"
  type        = bool
  default     = false
}

variable "enable_streams" {
  description = "Enable DynamoDB Streams on file tracking table for event-driven manifest creation"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
