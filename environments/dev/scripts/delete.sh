#!/bin/bash


./cleanup-pipeline.sh all

./dynamodb-queries.sh delete-date 2026-02-06

# Step 1: Empty all S3 buckets
echo "Emptying S3 buckets..."

for bucket in ${INPUT_BUCKET} \
              ndjson-manifests-${ACCOUNT_ID}-${ENVIRONMENT} \
              ${OUTPUT_BUCKET} \
              ndjson-quarantine-${ACCOUNT_ID}-${ENVIRONMENT} \
              ${SCRIPTS_BUCKET}; do
  echo "Emptying ${bucket}..."
  aws s3 rm s3://${bucket} --recursive --region ${AWS_REGION}
done

# Step 2: Delete CloudFormation stack
echo "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

# Step 3: Wait for deletion
echo "Waiting for stack deletion... This may take 5-10 minutes."
aws cloudformation wait stack-delete-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

if [ $? -eq 0 ]; then
  echo "✓ Stack deleted successfully!"
else
  echo "✗ Stack deletion failed or timed out. Check CloudFormation console."
fi

# Step 4: Delete templates bucket (optional)
echo "Delete templates bucket? (y/n)"
read -r response
if [ "$response" = "y" ]; then
  aws s3 rm s3://${TEMPLATES_BUCKET} --recursive --region ${AWS_REGION}
  aws s3 rb s3://${TEMPLATES_BUCKET} --region ${AWS_REGION}
  echo "✓ Templates bucket deleted"
fi