output "job_name" {
  description = "Glue job name"
  value       = aws_glue_job.batch_processor.name
}

output "job_arn" {
  description = "Glue job ARN"
  value       = aws_glue_job.batch_processor.arn
}

# NOTE: Commented out due to disabled EventBridge trigger
# output "eventbridge_rule_name" {
#   description = "EventBridge rule name for manifest trigger"
#   value       = aws_cloudwatch_event_rule.manifest_created.name
# }

output "log_group_name" {
  description = "CloudWatch log group name for Glue job"
  value       = aws_cloudwatch_log_group.glue_job.name
}
