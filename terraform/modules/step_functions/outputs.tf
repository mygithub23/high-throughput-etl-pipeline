output "state_machine_arn" {
  description = "Step Functions state machine ARN"
  value       = aws_sfn_state_machine.processor.arn
}

output "state_machine_name" {
  description = "Step Functions state machine name"
  value       = aws_sfn_state_machine.processor.name
}

output "log_group_name" {
  description = "CloudWatch log group name for Step Functions"
  value       = aws_cloudwatch_log_group.step_functions.name
}
