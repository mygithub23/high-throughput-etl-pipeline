# API Gateway Security Configuration

## Overview

API Gateway has been **permanently disabled** for all environments to ensure the pipeline remains completely private with no external access points.

## Changes Made

### 1. Main Configuration (`main.tf`)

**State Management Module (Line 243):**
```hcl
# SECURITY: API Gateway disabled for all environments (no external access)
enable_api_gateway = false
```

**Control Plane Module (Line 205) - Commented Out:**
```hcl
# SECURITY: API Gateway disabled for all environments (no external access)
# enable_api_gateway = false
```

### 2. Module Documentation

Updated both module headers to reflect security policy:
- `modules/state_management/main.tf` - Added security note
- `modules/control_plane/main.tf` - Added security note

## Security Posture

### ✅ What's Protected

- **No Public Endpoints**: API Gateway is disabled, no HTTP/HTTPS endpoints are created
- **No CORS Vulnerabilities**: No cross-origin requests possible
- **No Unauthenticated Access**: Cannot be called without AWS credentials
- **Private Pipeline**: All communication happens within AWS VPC

### 🔒 Access Methods

The pipeline can only be accessed through:

1. **AWS Console**
   - CloudWatch Logs for monitoring
   - DynamoDB console for state queries
   - S3 console for data access

2. **AWS CLI** (with valid credentials)
   - Lambda invoke for direct function calls
   - DynamoDB queries for file tracking
   - S3 operations for data access

3. **AWS SDK** (programmatic access)
   - Application code with IAM credentials
   - Internal services within AWS

4. **CloudWatch Dashboard**
   - Monitoring and metrics visualization
   - No write access, read-only

## Previous Risk (Now Mitigated)

### What Would Have Been Exposed (If API Gateway Was Enabled)

**High Risk Issues:**
- ❌ `allow_origins = ["*"]` - Would allow requests from ANY domain
- ❌ No authentication - Anyone with URL could call the API
- ❌ Public internet exposure - API accessible worldwide

**These risks are now ELIMINATED** - API Gateway is not created at all.

## Deployment Verification

To verify API Gateway is disabled after deployment:

```bash
# Check Terraform outputs
terraform output state_management_api_url
# Expected: "N/A (API only available when enable_api_gateway=true)"

# Verify no API Gateway exists
aws apigatewayv2 get-apis --query 'Items[?Name==`ndjson-parquet-state-api-prod`]'
# Expected: []

aws apigatewayv2 get-apis --query 'Items[?Name==`ndjson-parquet-control-api-prod`]'
# Expected: []
```

## Future Considerations

If external access is ever needed in the future, implement these security controls:

### Option 1: IAM Authorization (Most Secure)
```hcl
authorization_type = "AWS_IAM"
```
- Requires AWS SigV4 signed requests
- Only authenticated AWS principals can access
- Fine-grained IAM policies

### Option 2: Private API Gateway (VPC Only)
```hcl
endpoint_configuration {
  types = ["PRIVATE"]
  vpc_endpoint_ids = [aws_vpc_endpoint.api.id]
}
```
- Only accessible from VPC
- No internet exposure
- Requires VPC endpoint

### Option 3: API Keys + IP Restrictions
```hcl
# API Key requirement
authorization_type = "API_KEY"

# Resource policy for IP restriction
resource_policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect = "Deny"
    Principal = "*"
    Action = "execute-api:Invoke"
    Resource = "*"
    Condition = {
      NotIpAddress = {
        "aws:SourceIp" = ["10.0.0.0/8", "172.16.0.0/12"]
      }
    }
  }]
})
```

## Compliance Notes

This configuration ensures:
- ✅ **Zero Trust Architecture**: No implicit trust, AWS credentials required
- ✅ **Defense in Depth**: Multiple layers (no public endpoint, IAM policies, SGs)
- ✅ **Principle of Least Privilege**: Only necessary AWS services can communicate
- ✅ **Data Privacy**: No external exposure of internal pipeline data

## Related Files

- `terraform/main.tf` - Main configuration with disabled API Gateway
- `terraform/modules/state_management/main.tf` - State management module
- `terraform/modules/control_plane/main.tf` - Control plane module (currently disabled)
- `terraform/terraform.tfvars.prod` - Production configuration

## Last Updated

2026-01-11 - API Gateway permanently disabled for all environments
