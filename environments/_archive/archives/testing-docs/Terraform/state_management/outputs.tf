output "state_management_function_arn" {
  description = "State management Lambda function ARN"
  value       = aws_lambda_function.state_management.arn
}

output "state_management_function_name" {
  description = "State management Lambda function name"
  value       = aws_lambda_function.state_management.function_name
}

# API URL output removed - API Gateway feature permanently disabled

output "state_management_log_group_name" {
  description = "State management CloudWatch log group name"
  value       = aws_cloudwatch_log_group.state_management.name
}
