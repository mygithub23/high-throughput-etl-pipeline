# Development Environment Configuration

environment = "dev"
aws_region  = "us-east-1"

# S3 Configuration
create_input_bucket             = true
existing_input_bucket_name      = ""
create_output_bucket            = true
existing_output_bucket_name     = ""
create_manifest_bucket          = true
existing_manifest_bucket_name   = ""
create_quarantine_bucket        = true
existing_quarantine_bucket_name = ""
create_scripts_bucket           = true
existing_scripts_bucket_name    = ""

# S3 Bucket Prefixes
input_bucket_prefix      = "pipeline/input"
output_bucket_prefix     = "pipeline/output"
manifest_bucket_prefix   = "pipeline/manifests"
quarantine_bucket_prefix = "pipeline/quarantine"
scripts_bucket_prefix    = "pipeline/scripts"
glue_logs_prefix         = "pipeline/logs"
glue_temp_prefix         = "pipeline/temp"

# Lifecycle policies
input_lifecycle_days      = 3
manifest_lifecycle_days   = 1
quarantine_lifecycle_days = 7

# DynamoDB Configuration
# Increased capacity for bulk file processing (180+ files)
# 1 WCU = 1 write/sec for items up to 1KB
# With 180 files arriving together, need higher capacity to avoid throttling
dynamodb_read_capacity  = 5
dynamodb_write_capacity = 25 # Higher for burst writes during file ingestion
dynamodb_ttl_days       = 30

# Lambda Configuration
lambda_manifest_memory      = 512
lambda_manifest_timeout     = 180
lambda_manifest_concurrency = 2

# Manifest Builder Configuration
max_files_per_manifest = 10 # Creates manifest when 10 files are pending (for dev testing)
expected_file_size_mb  = 10 # Center of validation range (allows 0.1 - 19.9 MB with 99% tolerance)
size_tolerance_percent = 99 # Very permissive: allows files from 0.1 MB to 19.9 MB

# Glue Configuration
glue_version             = "4.0"
glue_worker_type         = "G.1X"
glue_number_of_workers   = 2
glue_max_concurrent_runs = 3 # Allow 3 concurrent jobs to prevent ConcurrentRunsExceededException
glue_timeout             = 2880
glue_max_retries         = 1 # Allow 1 retry on Glue job failure

# Monitoring Configuration
alert_email        = "magzine323@gmail.com"
log_retention_days = 3
create_dashboard   = true

# SQS Configuration
sqs_message_retention_seconds = 345600
sqs_visibility_timeout        = 360
sqs_max_receive_count         = 3
sqs_batch_size                = 10
