output "file_tracking_table_name" {
  description = "File tracking table name"
  value       = aws_dynamodb_table.file_tracking.name
}

output "file_tracking_table_arn" {
  description = "File tracking table ARN"
  value       = aws_dynamodb_table.file_tracking.arn
}

output "file_tracking_table_id" {
  description = "File tracking table ID"
  value       = aws_dynamodb_table.file_tracking.id
}

output "metrics_table_name" {
  description = "Metrics table name"
  value       = aws_dynamodb_table.metrics.name
}

output "metrics_table_arn" {
  description = "Metrics table ARN"
  value       = aws_dynamodb_table.metrics.arn
}

output "metrics_table_id" {
  description = "Metrics table ID"
  value       = aws_dynamodb_table.metrics.id
}
