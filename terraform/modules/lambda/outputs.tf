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
