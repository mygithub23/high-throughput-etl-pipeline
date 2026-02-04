#!/bin/bash

###############################################################################
# Production Deployment Test Script
#
# This script tests the production deployment process and then destroys
# everything to avoid costs. Use this to verify deployment works before
# actual production deployment.
#
# Usage:
#   ./test-prod-deployment.sh
###############################################################################

set -e  # Exit on error

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

print_warning "========================================="
print_warning "PRODUCTION DEPLOYMENT TEST"
print_warning "========================================="
echo ""
print_warning "This will:"
print_warning "1. Deploy FULL production infrastructure to us-west-2"
print_warning "2. Verify deployment succeeds"
print_warning "3. IMMEDIATELY DESTROY everything to avoid costs"
echo ""
print_warning "NOTE: This uses MINIMAL resources for testing (G.1X workers, etc.)"
print_warning "      Real production would use larger resources!"
echo ""
read -p "Continue with test deployment? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    print_warning "Test cancelled"
    exit 0
fi

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_info "AWS Account ID: $ACCOUNT_ID"

# Set region for prod test
REGION="us-west-2"
ENVIRONMENT="prod"

print_info "Test region: $REGION"
print_info "Environment: $ENVIRONMENT"

###############################################################################
# Step 1: Backup existing terraform.tfvars if it exists
###############################################################################
if [ -f "terraform.tfvars" ]; then
    print_info "Backing up existing terraform.tfvars..."
    cp terraform.tfvars terraform.tfvars.backup
    print_success "Backup created: terraform.tfvars.backup"
fi

###############################################################################
# Step 2: Copy prod test config
###############################################################################
print_info "Using production test configuration..."
cp terraform.tfvars.prod terraform.tfvars

# Update scripts bucket name after deploy.sh creates it
SCRIPTS_BUCKET="ndjson-glue-scripts-${ACCOUNT_ID}-${ENVIRONMENT}"
print_info "Scripts bucket will be: $SCRIPTS_BUCKET"

###############################################################################
# Step 3: Run deploy.sh for prod
###############################################################################
print_info "Starting production deployment test..."
print_warning "This will take several minutes..."

# Run deploy.sh in non-interactive mode by auto-confirming
echo "yes" | ./deploy.sh prod $REGION

if [ $? -eq 0 ]; then
    print_success "Production deployment test SUCCESSFUL!"

    # Update terraform.tfvars with scripts bucket name
    sed -i "s|existing_scripts_bucket_name    = \".*\"|existing_scripts_bucket_name    = \"${SCRIPTS_BUCKET}\"|" terraform.tfvars

    print_info "Waiting 30 seconds before destroying (to let you review)..."
    sleep 30
else
    print_error "Production deployment FAILED!"
    exit 1
fi

###############################################################################
# Step 4: Show what was created
###############################################################################
print_info "Resources created:"
terraform output

###############################################################################
# Step 5: Destroy everything
###############################################################################
echo ""
print_warning "========================================="
print_warning "DESTROYING TEST DEPLOYMENT"
print_warning "========================================="
echo ""
print_info "Destroying all resources to avoid costs..."

terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    print_success "All resources destroyed successfully!"
else
    print_error "Destroy failed! Check AWS console and manually delete resources!"
    exit 1
fi

###############################################################################
# Step 6: Clean up scripts bucket
###############################################################################
print_info "Deleting scripts bucket..."

# Empty and delete scripts bucket
aws s3 rm s3://${SCRIPTS_BUCKET} --recursive --region $REGION
aws s3 rb s3://${SCRIPTS_BUCKET} --region $REGION

print_success "Scripts bucket deleted"

###############################################################################
# Step 7: Restore original terraform.tfvars
###############################################################################
if [ -f "terraform.tfvars.backup" ]; then
    print_info "Restoring original terraform.tfvars..."
    mv terraform.tfvars.backup terraform.tfvars
    print_success "Original configuration restored"
fi

###############################################################################
# Final Summary
###############################################################################
echo ""
print_success "========================================="
print_success "PRODUCTION DEPLOYMENT TEST COMPLETE"
print_success "========================================="
echo ""
print_success "✓ Deployment succeeded"
print_success "✓ All resources destroyed"
print_success "✓ Scripts bucket deleted"
print_success "✓ Configuration restored"
echo ""
print_info "Production deployment process is VERIFIED and working!"
print_info "When ready for real production, use: ./deploy.sh prod"
echo ""
