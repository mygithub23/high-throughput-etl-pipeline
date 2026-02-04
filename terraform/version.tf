
# *********************************** Dev

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Uncomment for remote state management
  backend "s3" {
    bucket = "tf-backend-<ACCOUNT>"
    key    = "ndjson-parquet-pipeline/terraform-devtfstate"
    region = "us-east-1"
  }
}
# = "ndjson-parquet-pipeline/terraform-prod.tfstate"
# encrypt        = true
# dynamodb_table = "terraform-state-lock"

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ndjson-parquet-pipeline"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
