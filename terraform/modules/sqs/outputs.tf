output "queue_arn" {
  description = "Main queue ARN"
  value       = aws_sqs_queue.main.arn
}

output "queue_url" {
  description = "Main queue URL"
  value       = aws_sqs_queue.main.url
}

output "queue_name" {
  description = "Main queue name"
  value       = aws_sqs_queue.main.name
}

output "dlq_arn" {
  description = "Dead letter queue ARN"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "Dead letter queue URL"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_name" {
  description = "Dead letter queue name"
  value       = aws_sqs_queue.dlq.name
}
