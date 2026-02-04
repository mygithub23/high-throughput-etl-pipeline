# CloudFormation to Terraform Migration Guide

This guide helps you understand the differences between the CloudFormation and Terraform implementations and provides migration strategies.

## Overview

Both implementations deploy the same architecture but use different Infrastructure as Code (IaC) tools:

- **CloudFormation**: AWS-native, uses nested stacks
- **Terraform**: Multi-cloud capable, uses modules

## Architecture Comparison

Both implementations create identical resources:

| Component | CloudFormation | Terraform |
|-----------|---------------|-----------|
| S3 Buckets | 5 buckets | 5 buckets |
| DynamoDB Tables | 2 tables | 2 tables |
| Lambda Functions | 3 functions | 3 functions |
| Glue Job | 1 job | 1 job |
| IAM Roles | 5 roles | 5 roles |
| CloudWatch Alarms | 10+ alarms | 10+ alarms |
| SQS (optional) | 2 queues | 2 queues |

## Key Differences

### 1. Structure

**CloudFormation:**
```
cloudformation/
├── main.yaml (orchestrates nested stacks)
├── s3-buckets.yaml
├── dynamodb-tables.yaml
├── iam-roles.yaml
├── lambda-function.yaml
├── control-plane.yaml
├── state-management.yaml
├── glue-job.yaml
├── monitoring.yaml
└── sqs-queues.yaml
```

**Terraform:**
```
terraform/
├── main.tf (root module)
├── variables.tf
├── outputs.tf
└── modules/
    ├── s3/
    ├── dynamodb/
    ├── iam/
    ├── lambda/
    ├── control_plane/
    ├── state_management/
    ├── glue/
    ├── monitoring/
    └── sqs/
```

### 2. Parameter Files

**CloudFormation:**
```json
// parameters-dev.json
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "dev"
  },
  {
    "ParameterKey": "GlueWorkerType",
    "ParameterValue": "G.1X"
  }
]
```

**Terraform:**
```hcl
# terraform.tfvars
environment      = "dev"
glue_worker_type = "G.1X"
```

### 3. Outputs

**CloudFormation:**
```yaml
Outputs:
  InputBucketName:
    Description: Input bucket name
    Value: !Ref InputBucket
    Export:
      Name: !Sub '${AWS::StackName}-InputBucketName'
```

**Terraform:**
```hcl
output "input_bucket_name" {
  description = "Input bucket name"
  value       = module.s3.input_bucket_name
}
```

### 4. Deployment Commands

**CloudFormation:**
```bash
./deploy.sh dev
# or
aws cloudformation deploy \
  --template-file main.yaml \
  --stack-name ndjson-parquet-pipeline-dev \
  --parameter-overrides file://parameters-dev.json \
  --capabilities CAPABILITY_NAMED_IAM
```

**Terraform:**
```bash
./deploy.sh dev
# or
terraform init
terraform plan
terraform apply
```

### 5. State Management

**CloudFormation:**
- State managed by AWS CloudFormation service
- Automatic rollback on failure
- Stack history maintained by AWS

**Terraform:**
- State stored locally by default (terraform.tfstate)
- Can use remote backends (S3, Terraform Cloud)
- Manual state management

## Advantages Comparison

### CloudFormation Advantages

✅ **AWS Native Integration**
- Deep integration with AWS services
- Automatic dependency resolution
- Built-in rollback on failure

✅ **No State File Management**
- AWS manages the state automatically
- No risk of state file corruption
- Easier for teams (no state locking needed by default)

✅ **ChangeSet Preview**
- See exact changes before applying
- Better change visibility

✅ **Stack Policies**
- Protect critical resources from updates
- Fine-grained update control

### Terraform Advantages

✅ **Multi-Cloud Support**
- Works with AWS, Azure, GCP, etc.
- Consistent syntax across providers

✅ **Better Module System**
- More flexible module composition
- Easier to reuse modules
- Better variable handling

✅ **Plan/Apply Workflow**
- Clearer separation between plan and apply
- More predictable deployments

✅ **Larger Community**
- More third-party modules
- Better documentation and examples

✅ **State Manipulation**
- Can import existing resources
- Can move resources between states
- Can remove resources from state

✅ **Better Variables Support**
- Complex data types (maps, lists, objects)
- Variable validation
- Local values

## When to Use Each

### Use CloudFormation if:

1. **AWS-Only Workload**
   - You're only deploying to AWS
   - Don't need multi-cloud portability

2. **Team Preference**
   - Team is more familiar with CloudFormation
   - Organization standard is CloudFormation

3. **Simplicity**
   - Want AWS to manage state automatically
   - Prefer built-in rollback capabilities

4. **Integration Requirements**
   - Need tight integration with AWS services
   - Using AWS Service Catalog

### Use Terraform if:

1. **Multi-Cloud**
   - Deploying across multiple cloud providers
   - Need consistent IaC across clouds

2. **Team Expertise**
   - Team has Terraform experience
   - Using Terraform for other projects

3. **Advanced State Management**
   - Need to import existing resources
   - Require state manipulation capabilities

4. **Module Reusability**
   - Building reusable infrastructure components
   - Sharing modules across projects

5. **CI/CD Integration**
   - Better support for automated pipelines
   - Easier integration with GitOps workflows

## Migration Strategies

### Strategy 1: Fresh Deployment (Recommended)

Deploy a new environment with Terraform alongside existing CloudFormation:

1. **Deploy dev environment with Terraform**
   ```bash
   cd terraform
   cp terraform.tfvars.dev.example terraform.tfvars
   ./deploy.sh dev
   ```

2. **Test thoroughly**
   - Verify all resources are created correctly
   - Test the pipeline end-to-end
   - Compare with CloudFormation deployment

3. **Deploy prod environment with Terraform**
   ```bash
   cp terraform.tfvars.prod.example terraform.tfvars
   ./deploy.sh prod
   ```

4. **Migrate data (if needed)**
   - Copy DynamoDB data
   - Move S3 objects

5. **Delete CloudFormation stacks**
   ```bash
   aws cloudformation delete-stack --stack-name ndjson-parquet-pipeline-dev
   aws cloudformation delete-stack --stack-name ndjson-parquet-pipeline-prod
   ```

### Strategy 2: Import Existing Resources

Import CloudFormation-managed resources into Terraform:

1. **Map CloudFormation resources to Terraform**
   ```bash
   # List CloudFormation resources
   aws cloudformation describe-stack-resources \
     --stack-name ndjson-parquet-pipeline-dev
   ```

2. **Create Terraform configuration**
   ```bash
   cd terraform
   cp terraform.tfvars.dev.example terraform.tfvars
   terraform init
   ```

3. **Import resources one by one**
   ```bash
   # Import S3 bucket
   terraform import module.s3.aws_s3_bucket.input \
     ndjson-input-sqs-123456789012-dev

   # Import DynamoDB table
   terraform import module.dynamodb.aws_dynamodb_table.file_tracking \
     ndjson-parquet-sqs-file-tracking-dev

   # Continue for all resources...
   ```

4. **Verify import**
   ```bash
   terraform plan
   # Should show minimal or no changes
   ```

5. **Delete CloudFormation stack (without deleting resources)**
   ```bash
   aws cloudformation delete-stack \
     --stack-name ndjson-parquet-pipeline-dev \
     --retain-resources InputBucket,FileTrackingTable,...
   ```

### Strategy 3: Parallel Deployment

Run both CloudFormation and Terraform in parallel:

1. **Deploy new environment with Terraform**
   - Use different bucket names/resource names
   - Test with production-like data

2. **Gradually migrate traffic**
   - Start with small percentage of files
   - Monitor both pipelines

3. **Full cutover when confident**
   - Switch all traffic to Terraform deployment
   - Decommission CloudFormation

## Resource Naming Comparison

Both implementations use the same naming conventions:

| Resource Type | Naming Pattern |
|--------------|----------------|
| S3 Buckets | `ndjson-{type}-sqs-{account_id}-{env}` |
| DynamoDB Tables | `ndjson-parquet-sqs-{type}-{env}` |
| Lambda Functions | `ndjson-parquet-{type}-{env}` |
| Glue Jobs | `ndjson-parquet-batch-job-{env}` |
| IAM Roles | `ndjson-parquet-{type}-role-{env}` |

## Cost Comparison

Both implementations have the **same operational cost** since they deploy identical resources. However:

**CloudFormation:**
- No additional cost (included in AWS service)

**Terraform:**
- Free for self-managed (open source)
- Optional: Terraform Cloud for team collaboration ($20/user/month)

## Operational Differences

### Updates

**CloudFormation:**
```bash
# Update stack
aws cloudformation deploy \
  --template-file main.yaml \
  --stack-name ndjson-parquet-pipeline-dev \
  --capabilities CAPABILITY_NAMED_IAM
```

**Terraform:**
```bash
# Update infrastructure
terraform plan
terraform apply
```

### Rollback

**CloudFormation:**
- Automatic rollback on failure
- Can manually rollback to previous stack version
```bash
aws cloudformation rollback-stack --stack-name ndjson-parquet-pipeline-dev
```

**Terraform:**
- Manual rollback by reverting code changes
```bash
git revert HEAD
terraform apply
```

### Drift Detection

**CloudFormation:**
```bash
# Detect drift
aws cloudformation detect-stack-drift --stack-name ndjson-parquet-pipeline-dev
aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id <id>
```

**Terraform:**
```bash
# Check for drift
terraform plan
# Will show differences between state and reality
```

## Troubleshooting

### Issue: Resources Not Matching

If imported Terraform resources don't match CloudFormation:

1. **Check resource attributes**
   ```bash
   aws cloudformation describe-stack-resource \
     --stack-name ndjson-parquet-pipeline-dev \
     --logical-resource-id InputBucket
   ```

2. **Update Terraform configuration** to match
3. **Re-run plan** to verify

### Issue: State File Corruption

If Terraform state gets corrupted:

1. **Restore from backup**
   ```bash
   cp terraform.tfstate.backup terraform.tfstate
   ```

2. **Or rebuild state**
   ```bash
   terraform import module.s3.aws_s3_bucket.input <bucket-name>
   # Continue for all resources
   ```

## Recommendation

For this project, I recommend **Terraform** because:

1. ✅ **Better for version control** - Cleaner git diffs
2. ✅ **More portable** - Can move to other clouds if needed
3. ✅ **Better module system** - Easier to maintain and extend
4. ✅ **Industry standard** - More common in DevOps community
5. ✅ **Better tooling** - VS Code extensions, linters, validators

However, if your organization has:
- Strong CloudFormation expertise
- AWS-only infrastructure
- Existing CloudFormation workflows

Then **CloudFormation** is a perfectly valid choice.

## Next Steps

1. Review the Terraform implementation in `terraform/`
2. Choose your migration strategy
3. Test in development environment
4. Plan production migration
5. Execute migration with proper backups

## Support

Both implementations are fully functional and production-ready. Choose the one that best fits your team's expertise and organizational requirements.
