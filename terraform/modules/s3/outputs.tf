output "input_bucket_id" {
  description = "Input bucket ID"
  value       = var.create_input_bucket ? aws_s3_bucket.input[0].id : data.aws_s3_bucket.existing_input[0].id
}

output "input_bucket_arn" {
  description = "Input bucket ARN"
  value       = var.create_input_bucket ? aws_s3_bucket.input[0].arn : data.aws_s3_bucket.existing_input[0].arn
}

output "input_bucket_name" {
  description = "Input bucket name"
  value       = var.create_input_bucket ? aws_s3_bucket.input[0].bucket : data.aws_s3_bucket.existing_input[0].bucket
}

output "manifest_bucket_id" {
  description = "Manifest bucket ID"
  value       = var.create_manifest_bucket ? aws_s3_bucket.manifest[0].id : data.aws_s3_bucket.existing_manifest[0].id
}

output "manifest_bucket_arn" {
  description = "Manifest bucket ARN"
  value       = var.create_manifest_bucket ? aws_s3_bucket.manifest[0].arn : data.aws_s3_bucket.existing_manifest[0].arn
}

output "manifest_bucket_name" {
  description = "Manifest bucket name"
  value       = var.create_manifest_bucket ? aws_s3_bucket.manifest[0].bucket : data.aws_s3_bucket.existing_manifest[0].bucket
}

output "output_bucket_id" {
  description = "Output bucket ID"
  value       = var.create_output_bucket ? aws_s3_bucket.output[0].id : data.aws_s3_bucket.existing_output[0].id
}

output "output_bucket_arn" {
  description = "Output bucket ARN"
  value       = var.create_output_bucket ? aws_s3_bucket.output[0].arn : data.aws_s3_bucket.existing_output[0].arn
}

output "output_bucket_name" {
  description = "Output bucket name"
  value       = var.create_output_bucket ? aws_s3_bucket.output[0].bucket : data.aws_s3_bucket.existing_output[0].bucket
}

output "quarantine_bucket_id" {
  description = "Quarantine bucket ID"
  value       = var.create_quarantine_bucket ? aws_s3_bucket.quarantine[0].id : data.aws_s3_bucket.existing_quarantine[0].id
}

output "quarantine_bucket_arn" {
  description = "Quarantine bucket ARN"
  value       = var.create_quarantine_bucket ? aws_s3_bucket.quarantine[0].arn : data.aws_s3_bucket.existing_quarantine[0].arn
}

output "quarantine_bucket_name" {
  description = "Quarantine bucket name"
  value       = var.create_quarantine_bucket ? aws_s3_bucket.quarantine[0].bucket : data.aws_s3_bucket.existing_quarantine[0].bucket
}

output "scripts_bucket_id" {
  description = "Scripts bucket ID"
  value       = var.create_scripts_bucket ? aws_s3_bucket.scripts[0].id : data.aws_s3_bucket.existing_scripts[0].id
}

output "scripts_bucket_arn" {
  description = "Scripts bucket ARN"
  value       = var.create_scripts_bucket ? aws_s3_bucket.scripts[0].arn : data.aws_s3_bucket.existing_scripts[0].arn
}

output "scripts_bucket_name" {
  description = "Scripts bucket name"
  value       = var.create_scripts_bucket ? aws_s3_bucket.scripts[0].bucket : data.aws_s3_bucket.existing_scripts[0].bucket
}
