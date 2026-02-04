output "lambda_role_arn" {
  description = "Lambda manifest builder role ARN"
  value       = aws_iam_role.lambda.arn
}

output "lambda_role_name" {
  description = "Lambda manifest builder role name"
  value       = aws_iam_role.lambda.name
}

# Control plane outputs removed - module no longer exists

output "state_management_role_arn" {
  description = "State management Lambda role ARN"
  value       = aws_iam_role.state_management.arn
}

output "state_management_role_name" {
  description = "State management Lambda role name"
  value       = aws_iam_role.state_management.name
}

output "glue_role_arn" {
  description = "Glue job role ARN"
  value       = aws_iam_role.glue.arn
}

output "glue_role_name" {
  description = "Glue job role name"
  value       = aws_iam_role.glue.name
}

output "eventbridge_role_arn" {
  description = "EventBridge role ARN"
  value       = aws_iam_role.eventbridge.arn
}

output "eventbridge_role_name" {
  description = "EventBridge role name"
  value       = aws_iam_role.eventbridge.name
}

output "step_functions_role_arn" {
  description = "Step Functions role ARN"
  value       = aws_iam_role.step_functions.arn
}

output "step_functions_role_name" {
  description = "Step Functions role name"
  value       = aws_iam_role.step_functions.name
}
