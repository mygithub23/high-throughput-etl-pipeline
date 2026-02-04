#!/bin/bash

# Check SQS Queue Status
# Verify if messages are reaching the queue

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

echo -e "${GREEN}Checking SQS Queue Status${NC}"
echo ""

# Get queue URL
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "${STACK_NAME}-file-events" \
  --region $REGION \
  --query 'QueueUrl' \
  --output text)

echo "Queue URL: $QUEUE_URL"
echo ""

# Get queue attributes
echo -e "${YELLOW}Queue Statistics:${NC}"
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names All \
  --region $REGION \
  --query 'Attributes.{
    ApproximateNumberOfMessages:ApproximateNumberOfMessages,
    ApproximateNumberOfMessagesNotVisible:ApproximateNumberOfMessagesNotVisible,
    ApproximateNumberOfMessagesDelayed:ApproximateNumberOfMessagesDelayed,
    NumberOfMessagesSent:ApproximateNumberOfMessagesSent,
    NumberOfMessagesReceived:ApproximateNumberOfMessagesReceived,
    NumberOfMessagesDeleted:ApproximateNumberOfMessagesDeleted
  }' \
  --output table

echo ""

# Check Lambda trigger
echo -e "${YELLOW}Checking Lambda Event Source Mapping:${NC}"
aws lambda list-event-source-mappings \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION \
  --query 'EventSourceMappings[*].{State:State,BatchSize:BatchSize,EventSourceArn:EventSourceArn}' \
  --output table

echo ""

# Peek at messages (without removing them)
echo -e "${YELLOW}Peeking at messages in queue:${NC}"
MESSAGES=$(aws sqs receive-message \
  --queue-url "$QUEUE_URL" \
  --max-number-of-messages 1 \
  --visibility-timeout 0 \
  --region $REGION \
  --query 'Messages[0].Body' \
  --output text 2>/dev/null || echo "")

if [ ! -z "$MESSAGES" ] && [ "$MESSAGES" != "None" ]; then
    echo "Sample message:"
    echo "$MESSAGES" | head -20
else
    echo -e "${RED}No messages in queue${NC}"
fi

echo ""
echo -e "${GREEN}Queue check complete${NC}"
