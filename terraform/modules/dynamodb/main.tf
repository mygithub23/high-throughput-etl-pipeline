/**
 * DynamoDB Tables Module
 *
 * Creates DynamoDB tables for the NDJSON to Parquet pipeline:
 * - File tracking table (tracks processing state with GSI for status queries)
 * - Metrics table (stores pipeline metrics with TTL)
 */

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

###############################################################################
# File Tracking Table
###############################################################################

resource "aws_dynamodb_table" "file_tracking" {
  name           = "ndjson-parquet-sqs-file-tracking-${var.environment}"
  billing_mode   = "PROVISIONED"
  read_capacity  = var.file_tracking_read_capacity
  write_capacity = var.file_tracking_write_capacity
  hash_key       = "date_prefix"
  range_key      = "file_key"

  attribute {
    name = "date_prefix" # Date partition key (YYYY-MM-DD)
    type = "S"
  }

  attribute {
    name = "file_key" # Filename or "LOCK"/"MANIFEST"
    type = "S"
  }

  attribute {
    name = "status" # pending, manifested, processing, completed, failed
    type = "S"
  }

  # Global Secondary Index for querying by status
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "date_prefix"
    projection_type = "ALL"
    read_capacity   = var.file_tracking_read_capacity
    write_capacity  = var.file_tracking_write_capacity
  }

  # Enable DynamoDB Streams for event-driven manifest creation
  stream_enabled   = var.enable_streams
  stream_view_type = var.enable_streams ? "NEW_AND_OLD_IMAGES" : null

  # Enable TTL
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Enable point-in-time recovery
  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  # Server-side encryption
  server_side_encryption {
    enabled = true
  }

  tags = merge(
    var.tags,
    {
      Name        = "File Tracking Table"
      Description = "Tracks NDJSON file processing state"
    }
  )
}

# Auto-scaling for file tracking table - Read capacity
resource "aws_appautoscaling_target" "file_tracking_read" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.file_tracking_read_capacity * 4
  min_capacity       = var.file_tracking_read_capacity
  resource_id        = "table/${aws_dynamodb_table.file_tracking.name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "file_tracking_read" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "DynamoDBReadCapacityUtilization:${aws_appautoscaling_target.file_tracking_read[0].resource_id}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.file_tracking_read[0].resource_id
  scalable_dimension = aws_appautoscaling_target.file_tracking_read[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.file_tracking_read[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70.0
  }
}

# Auto-scaling for file tracking table - Write capacity
resource "aws_appautoscaling_target" "file_tracking_write" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.file_tracking_write_capacity * 4
  min_capacity       = var.file_tracking_write_capacity
  resource_id        = "table/${aws_dynamodb_table.file_tracking.name}"
  scalable_dimension = "dynamodb:table:WriteCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "file_tracking_write" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "DynamoDBWriteCapacityUtilization:${aws_appautoscaling_target.file_tracking_write[0].resource_id}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.file_tracking_write[0].resource_id
  scalable_dimension = aws_appautoscaling_target.file_tracking_write[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.file_tracking_write[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBWriteCapacityUtilization"
    }
    target_value = 70.0
  }
}

###############################################################################
# Metrics Table
###############################################################################

resource "aws_dynamodb_table" "metrics" {
  name           = "ndjson-parquet-sqs-metrics-${var.environment}"
  billing_mode   = "PROVISIONED"
  read_capacity  = var.metrics_read_capacity
  write_capacity = var.metrics_write_capacity
  hash_key       = "metric_type"
  range_key      = "timestamp"

  attribute {
    name = "metric_type" # Type of metric
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  # Enable TTL for automatic cleanup
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Enable point-in-time recovery
  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  # Server-side encryption
  server_side_encryption {
    enabled = true
  }

  tags = merge(
    var.tags,
    {
      Name        = "Metrics Table"
      Description = "Stores pipeline metrics and statistics"
    }
  )
}

# Auto-scaling for metrics table - Read capacity
resource "aws_appautoscaling_target" "metrics_read" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.metrics_read_capacity * 4
  min_capacity       = var.metrics_read_capacity
  resource_id        = "table/${aws_dynamodb_table.metrics.name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "metrics_read" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "DynamoDBReadCapacityUtilization:${aws_appautoscaling_target.metrics_read[0].resource_id}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.metrics_read[0].resource_id
  scalable_dimension = aws_appautoscaling_target.metrics_read[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.metrics_read[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70.0
  }
}

# Auto-scaling for metrics table - Write capacity
resource "aws_appautoscaling_target" "metrics_write" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.metrics_write_capacity * 4
  min_capacity       = var.metrics_write_capacity
  resource_id        = "table/${aws_dynamodb_table.metrics.name}"
  scalable_dimension = "dynamodb:table:WriteCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "metrics_write" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "DynamoDBWriteCapacityUtilization:${aws_appautoscaling_target.metrics_write[0].resource_id}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.metrics_write[0].resource_id
  scalable_dimension = aws_appautoscaling_target.metrics_write[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.metrics_write[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBWriteCapacityUtilization"
    }
    target_value = 70.0
  }
}
