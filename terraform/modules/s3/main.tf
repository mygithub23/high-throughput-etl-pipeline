/**
 * S3 Buckets Module
 *
 * Creates S3 buckets required for the NDJSON to Parquet pipeline:
 * - Input bucket (receives NDJSON files) - OPTIONAL: can use existing
 * - Manifest bucket (stores batch manifests) - always created
 * - Output bucket (stores converted Parquet files) - OPTIONAL: can use existing
 * - Quarantine bucket (stores problematic files) - always created
 * - Scripts bucket (stores Lambda and Glue code) - always created
 */

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  bucket_prefix = "ndjson"
}

###############################################################################
# Data Sources for Existing Buckets
###############################################################################

data "aws_s3_bucket" "existing_input" {
  count  = var.create_input_bucket ? 0 : 1
  bucket = var.input_bucket_name
}

data "aws_s3_bucket" "existing_output" {
  count  = var.create_output_bucket ? 0 : 1
  bucket = var.output_bucket_name
}

data "aws_s3_bucket" "existing_manifest" {
  count  = var.create_manifest_bucket ? 0 : 1
  bucket = var.manifest_bucket_name
}

data "aws_s3_bucket" "existing_quarantine" {
  count  = var.create_quarantine_bucket ? 0 : 1
  bucket = var.quarantine_bucket_name
}

data "aws_s3_bucket" "existing_scripts" {
  count  = var.create_scripts_bucket ? 0 : 1
  bucket = var.scripts_bucket_name
}

###############################################################################
# Input Bucket (Optional - can use existing bucket)
###############################################################################

resource "aws_s3_bucket" "input" {
  count  = var.create_input_bucket ? 1 : 0
  bucket = var.input_bucket_name != "" ? var.input_bucket_name : "${local.bucket_prefix}-input-sqs-${var.account_id}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Name        = "NDJSON Input Bucket"
      Description = "Receives NDJSON files for processing"
    }
  )
}

resource "aws_s3_bucket_versioning" "input" {
  count  = var.create_input_bucket && var.enable_versioning ? 1 : 0
  bucket = aws_s3_bucket.input[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "input" {
  count  = var.create_input_bucket ? 1 : 0
  bucket = aws_s3_bucket.input[0].id

  rule {
    id     = "delete-old-files"
    status = "Enabled"

    filter {}

    expiration {
      days = var.input_lifecycle_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "input" {
  count  = var.create_input_bucket ? 1 : 0
  bucket = aws_s3_bucket.input[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  count  = var.create_input_bucket ? 1 : 0
  bucket = aws_s3_bucket.input[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################################################
# Manifest Bucket (Optional - can use existing bucket)
###############################################################################

resource "aws_s3_bucket" "manifest" {
  count  = var.create_manifest_bucket ? 1 : 0
  bucket = var.manifest_bucket_name != "" ? var.manifest_bucket_name : "${local.bucket_prefix}-manifest-sqs-${var.account_id}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Name        = "Manifest Bucket"
      Description = "Stores batch manifests for Glue processing"
    }
  )
}

resource "aws_s3_bucket_versioning" "manifest" {
  count  = var.create_manifest_bucket && var.enable_versioning ? 1 : 0
  bucket = aws_s3_bucket.manifest[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "manifest" {
  count  = var.create_manifest_bucket ? 1 : 0
  bucket = aws_s3_bucket.manifest[0].id

  rule {
    id     = "delete-old-manifests"
    status = "Enabled"

    filter {}

    expiration {
      days = var.manifest_lifecycle_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }
}

resource "aws_s3_bucket_public_access_block" "manifest" {
  count  = var.create_manifest_bucket ? 1 : 0
  bucket = aws_s3_bucket.manifest[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "manifest" {
  count  = var.create_manifest_bucket ? 1 : 0
  bucket = aws_s3_bucket.manifest[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################################################
# Output Bucket (Optional - can use existing bucket)
###############################################################################

resource "aws_s3_bucket" "output" {
  count  = var.create_output_bucket ? 1 : 0
  bucket = var.output_bucket_name != "" ? var.output_bucket_name : "${local.bucket_prefix}-output-sqs-${var.account_id}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Name        = "Output Bucket"
      Description = "Stores converted Parquet files"
    }
  )
}

resource "aws_s3_bucket_versioning" "output" {
  count  = var.create_output_bucket && var.enable_versioning ? 1 : 0
  bucket = aws_s3_bucket.output[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "output" {
  count  = var.create_output_bucket ? 1 : 0
  bucket = aws_s3_bucket.output[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  count  = var.create_output_bucket ? 1 : 0
  bucket = aws_s3_bucket.output[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################################################
# Quarantine Bucket (Optional - can use existing bucket)
###############################################################################

resource "aws_s3_bucket" "quarantine" {
  count  = var.create_quarantine_bucket ? 1 : 0
  bucket = var.quarantine_bucket_name != "" ? var.quarantine_bucket_name : "${local.bucket_prefix}-quarantine-sqs-${var.account_id}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Name        = "Quarantine Bucket"
      Description = "Stores files that failed validation or processing"
    }
  )
}

resource "aws_s3_bucket_versioning" "quarantine" {
  count  = var.create_quarantine_bucket && var.enable_versioning ? 1 : 0
  bucket = aws_s3_bucket.quarantine[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "quarantine" {
  count  = var.create_quarantine_bucket ? 1 : 0
  bucket = aws_s3_bucket.quarantine[0].id

  rule {
    id     = "delete-old-quarantined-files"
    status = "Enabled"

    filter {}

    expiration {
      days = var.quarantine_lifecycle_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "quarantine" {
  count  = var.create_quarantine_bucket ? 1 : 0
  bucket = aws_s3_bucket.quarantine[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "quarantine" {
  count  = var.create_quarantine_bucket ? 1 : 0
  bucket = aws_s3_bucket.quarantine[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################################################
# Scripts Bucket (Optional - can use existing bucket)
###############################################################################

resource "aws_s3_bucket" "scripts" {
  count  = var.create_scripts_bucket ? 1 : 0
  bucket = var.scripts_bucket_name != "" ? var.scripts_bucket_name : "${local.bucket_prefix}-glue-scripts-${var.account_id}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Name        = "Scripts Bucket"
      Description = "Stores Lambda and Glue job code"
    }
  )
}

resource "aws_s3_bucket_versioning" "scripts" {
  count  = var.create_scripts_bucket ? 1 : 0
  bucket = aws_s3_bucket.scripts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  count  = var.create_scripts_bucket ? 1 : 0
  bucket = aws_s3_bucket.scripts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  count  = var.create_scripts_bucket ? 1 : 0
  bucket = aws_s3_bucket.scripts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
