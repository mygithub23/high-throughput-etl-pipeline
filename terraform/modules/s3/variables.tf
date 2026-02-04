variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'."
  }
}

variable "account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "create_input_bucket" {
  description = "Whether to create input bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "input_bucket_name" {
  description = "Name of existing input bucket (only used if create_input_bucket = false)"
  type        = string
  default     = ""
}

variable "create_output_bucket" {
  description = "Whether to create output bucket (set to false to use existing bucket)"
  type        = bool
  default     = true
}

variable "output_bucket_name" {
  description = "Name of existing output bucket (only used if create_output_bucket = false)"
  type        = string
  default     = ""
}

variable "input_bucket_prefix" {
  description = "S3 prefix (folder path) for input files (e.g., 'raw-data' for s3://bucket/raw-data/)"
  type        = string
  default     = ""
}

variable "output_bucket_prefix" {
  description = "S3 prefix (folder path) for output files (e.g., 'parquet' for s3://bucket/parquet/)"
  type        = string
  default     = "parquet"
}

variable "create_manifest_bucket" {
  description = "Whether to create manifest bucket"
  type        = bool
  default     = true
}

variable "manifest_bucket_name" {
  description = "Name of existing manifest bucket (only used if create_manifest_bucket = false)"
  type        = string
  default     = ""
}

variable "create_quarantine_bucket" {
  description = "Whether to create quarantine bucket"
  type        = bool
  default     = true
}

variable "quarantine_bucket_name" {
  description = "Name of existing quarantine bucket (only used if create_quarantine_bucket = false)"
  type        = string
  default     = ""
}

variable "create_scripts_bucket" {
  description = "Whether to create scripts bucket"
  type        = bool
  default     = true
}

variable "scripts_bucket_name" {
  description = "Name of existing scripts bucket (only used if create_scripts_bucket = false)"
  type        = string
  default     = ""
}

variable "input_lifecycle_days" {
  description = "Number of days to retain files in input bucket"
  type        = number
  default     = 7
}

variable "manifest_lifecycle_days" {
  description = "Number of days to retain manifest files"
  type        = number
  default     = 30
}

variable "quarantine_lifecycle_days" {
  description = "Number of days to retain quarantined files"
  type        = number
  default     = 30
}

variable "enable_versioning" {
  description = "Enable versioning on buckets"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
