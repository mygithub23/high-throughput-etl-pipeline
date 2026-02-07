output "manifest_builder_function_arn" {
  description = "Manifest builder Lambda function ARN"
  value       = aws_lambda_function.manifest_builder.arn
}

output "manifest_builder_function_name" {
  description = "Manifest builder Lambda function name"
  value       = aws_lambda_function.manifest_builder.function_name
}

output "manifest_builder_log_group_name" {
  description = "Manifest builder CloudWatch log group name"
  value       = aws_cloudwatch_log_group.manifest_builder.name
}

output "lambda_dlq_arn" {
  description = "Lambda Dead Letter Queue ARN"
  value       = aws_sqs_queue.lambda_dlq.arn
}

output "lambda_dlq_url" {
  description = "Lambda Dead Letter Queue URL"
  value       = aws_sqs_queue.lambda_dlq.id
}

output "event_bus_name" {
  description = "EventBridge event bus name for ManifestReady events"
  value       = var.event_bus_name != "" ? aws_cloudwatch_event_bus.etl_pipeline[0].name : ""
}

output "event_bus_arn" {
  description = "EventBridge event bus ARN"
  value       = var.event_bus_name != "" ? aws_cloudwatch_event_bus.etl_pipeline[0].arn : ""
}

output "eventbridge_dlq_arn" {
  description = "EventBridge DLQ ARN"
  value       = var.event_bus_name != "" ? aws_sqs_queue.eventbridge_dlq[0].arn : ""
}

output "stream_manifest_creator_function_arn" {
  description = "Stream manifest creator Lambda function ARN"
  value       = var.file_tracking_table_stream_arn != "" ? aws_lambda_function.stream_manifest_creator[0].arn : ""
}

output "stream_manifest_creator_function_name" {
  description = "Stream manifest creator Lambda function name"
  value       = var.file_tracking_table_stream_arn != "" ? aws_lambda_function.stream_manifest_creator[0].function_name : ""
}

output "batch_status_updater_function_arn" {
  description = "Batch status updater Lambda function ARN"
  value       = aws_lambda_function.batch_status_updater.arn
}

output "batch_status_updater_function_name" {
  description = "Batch status updater Lambda function name"
  value       = aws_lambda_function.batch_status_updater.function_name
}
