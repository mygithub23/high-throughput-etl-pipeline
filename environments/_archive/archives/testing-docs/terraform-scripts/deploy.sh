#!/bin/bash

###############################################################################
# Terraform Deployment Script for NDJSON to Parquet Pipeline
#
# This script automates the deployment of the high-throughput ingestion pipeline
# using Terraform with modular configuration.
#
# Usage:
#   ./deploy.sh <environment> [region]
#
# Arguments:
#   environment: dev or prod
#   region: AWS region (optional, defaults to us-east-1)
#
# Examples:
#   ./deploy.sh dev
#   ./deploy.sh prod us-west-2
###############################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display usage
usage() {
    echo "Usage: $0 <environment> [region]"
    echo ""
    echo "Arguments:"
    echo "  environment    Environment to deploy (dev or prod)"
    echo "  region         AWS region (optional, defaults to us-east-1)"
    echo ""
    echo "Examples:"
    echo "  $0 dev"
    echo "  $0 prod us-west-2"
    exit 1
}

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

ENVIRONMENT=$1
REGION=${2:-us-east-1}

# Validate environment
if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" ]]; then
    print_error "Invalid environment: $ENVIRONMENT. Must be 'dev' or 'prod'"
    usage
fi

print_info "Starting Terraform deployment for environment: $ENVIRONMENT in region: $REGION"

# Check prerequisites
print_info "Checking prerequisites..."

# Check Terraform
if ! command -v terraform &> /dev/null; then
    print_error "Terraform is not installed. Please install Terraform 1.5.0 or higher."
    exit 1
fi

TERRAFORM_VERSION=$(terraform version -json | grep -o '"terraform_version":"[^"]*' | cut -d'"' -f4)
print_info "Terraform version: $TERRAFORM_VERSION"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install AWS CLI."
    exit 1
fi

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_info "AWS Account ID: $ACCOUNT_ID"

# Define variables
SCRIPTS_BUCKET="ndjson-glue-scripts-${ACCOUNT_ID}-${ENVIRONMENT}"

print_info "Scripts Bucket: $SCRIPTS_BUCKET"

###############################################################################
# Step 1: Create and populate scripts bucket
###############################################################################
print_info "Checking if scripts bucket exists..."

if aws s3 ls "s3://$SCRIPTS_BUCKET" 2>&1 | grep -q 'NoSuchBucket'; then
    print_warning "Scripts bucket does not exist. Creating..."
    aws s3 mb "s3://$SCRIPTS_BUCKET" --region "$REGION"

    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "$SCRIPTS_BUCKET" \
        --versioning-configuration Status=Enabled \
        --region "$REGION"

    # Block public access
    aws s3api put-public-access-block \
        --bucket "$SCRIPTS_BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$REGION"

    print_success "Scripts bucket created successfully"
else
    print_success "Scripts bucket already exists"
fi

###############################################################################
# Step 2: Package and upload Lambda functions
###############################################################################
print_info "Packaging and uploading Lambda functions..."

cd "../environments/$ENVIRONMENT/lambda"

# Package manifest builder
if [ -f "lambda_manifest_builder.py" ]; then
    print_info "Packaging manifest builder..."
    zip -q lambda_manifest_builder.zip lambda_manifest_builder.py
    aws s3 cp lambda_manifest_builder.zip \
        "s3://$SCRIPTS_BUCKET/lambda/$ENVIRONMENT/lambda_manifest_builder.zip" \
        --region "$REGION"
    rm lambda_manifest_builder.zip
    print_success "Manifest builder packaged and uploaded"
else
    print_warning "lambda_manifest_builder.py not found, skipping..."
fi

# Control plane removed - module no longer exists

# Package state manager (DISABLED - module disabled, to be enabled later)
# Uncomment when re-enabling state management module
# if [ -f "lambda_state_manager.py" ]; then
#     print_info "Packaging state manager..."
#     zip -q lambda_state_manager.zip lambda_state_manager.py
#     aws s3 cp lambda_state_manager.zip \
#         "s3://$SCRIPTS_BUCKET/lambda/$ENVIRONMENT/lambda_state_manager.zip" \
#         --region "$REGION"
#     rm lambda_state_manager.zip
#     print_success "State manager packaged and uploaded"
# else
#     print_warning "lambda_state_manager.py not found, skipping..."
# fi

cd "../../../terraform"

###############################################################################
# Step 3: Upload Glue script
###############################################################################
print_info "Uploading Glue script..."

if [ -f "../environments/$ENVIRONMENT/glue/glue_batch_job.py" ]; then
    aws s3 cp "../environments/$ENVIRONMENT/glue/glue_batch_job.py" \
        "s3://$SCRIPTS_BUCKET/glue/$ENVIRONMENT/glue_batch_job.py" \
        --region "$REGION"
    print_success "Glue script uploaded"
else
    print_warning "Glue script not found, skipping..."
fi

###############################################################################
# Step 4: Check for terraform.tfvars
###############################################################################
print_info "Checking for terraform.tfvars..."

if [ ! -f "terraform.tfvars" ]; then
    print_warning "terraform.tfvars not found. Using example file..."
    if [ -f "terraform.tfvars.${ENVIRONMENT}.example" ]; then
        cp "terraform.tfvars.${ENVIRONMENT}.example" "terraform.tfvars"
        print_warning "Please review and customize terraform.tfvars before continuing"
        read -p "Press Enter to continue or Ctrl+C to abort..."
    else
        print_error "No example tfvars file found for $ENVIRONMENT"
        exit 1
    fi
fi

###############################################################################
# Step 5: Initialize Terraform
###############################################################################
print_info "Initializing Terraform..."

terraform init

if [ $? -eq 0 ]; then
    print_success "Terraform initialized successfully"
else
    print_error "Terraform initialization failed"
    exit 1
fi

###############################################################################
# Step 6: Validate Terraform configuration
###############################################################################
print_info "Validating Terraform configuration..."

terraform validate

if [ $? -eq 0 ]; then
    print_success "Terraform configuration is valid"
else
    print_error "Terraform configuration validation failed"
    exit 1
fi

###############################################################################
# Step 7: Plan Terraform deployment
###############################################################################
print_info "Planning Terraform deployment..."

terraform plan -out=tfplan

if [ $? -eq 0 ]; then
    print_success "Terraform plan created successfully"
else
    print_error "Terraform plan failed"
    exit 1
fi

###############################################################################
# Step 8: Ask for confirmation
###############################################################################
echo ""
print_warning "==========================================="
print_warning "Review the plan above carefully!"
print_warning "==========================================="
echo ""
read -p "Do you want to apply this plan? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    print_warning "Deployment cancelled"
    rm tfplan
    exit 0
fi

###############################################################################
# Step 9: Apply Terraform plan
###############################################################################
print_info "Applying Terraform plan..."

terraform apply tfplan

if [ $? -eq 0 ]; then
    print_success "Terraform deployment completed successfully!"
else
    print_error "Terraform deployment failed"
    exit 1
fi

# Clean up plan file
rm tfplan

###############################################################################
# Step 10: Display outputs
###############################################################################
print_info "Retrieving Terraform outputs..."
echo ""
terraform output
echo ""

###############################################################################
# Step 11: Display next steps
###############################################################################
echo ""
print_info "========================================="
print_info "Next Steps:"
print_info "========================================="
echo ""
echo "1. Upload NDJSON files to the input bucket:"
INPUT_BUCKET=$(terraform output -raw input_bucket_name)
echo "   aws s3 cp your-file.ndjson s3://${INPUT_BUCKET}/"
echo ""
echo "2. Monitor Lambda function logs:"
echo "   aws logs tail /aws/lambda/ndjson-parquet-manifest-builder-${ENVIRONMENT} --follow"
echo ""
echo "3. Monitor Glue job execution:"
GLUE_JOB=$(terraform output -raw glue_job_name)
echo "   aws glue get-job-runs --job-name ${GLUE_JOB}"
echo ""
echo "4. Check processed Parquet files:"
OUTPUT_BUCKET=$(terraform output -raw output_bucket_name)
echo "   aws s3 ls s3://${OUTPUT_BUCKET}/parquet/"
echo ""
echo "5. Monitor DynamoDB file tracking:"
TRACKING_TABLE=$(terraform output -raw file_tracking_table_name)
echo "   aws dynamodb scan --table-name ${TRACKING_TABLE} --max-items 10"
echo ""
echo "6. View CloudWatch Dashboard:"
DASHBOARD=$(terraform output -raw dashboard_name)
if [[ "$DASHBOARD" != "N/A"* ]]; then
    echo "   https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD}"
fi
echo ""
print_info "========================================="
print_success "All done! Your pipeline is ready to use."
print_info "========================================="
