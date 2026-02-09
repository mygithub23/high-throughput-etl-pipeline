#!/usr/bin/env bash
# Diagnostic script: Why is batch_status_updater not updating individual files?
# Run this from the project root after the test completes.

set -euo pipefail

ENV="dev"
REGION="us-east-1"
STATE_MACHINE="ndjson-parquet-processor-${ENV}"
BATCH_UPDATER_FN="ndjson-parquet-batch-status-updater-${ENV}"

echo "============================================"
echo " Batch Status Updater Diagnostic"
echo "============================================"
echo ""

# 1. Check if batch_status_updater Lambda exists and is configured
echo "--- Step 1: Lambda Configuration ---"
aws lambda get-function --function-name "$BATCH_UPDATER_FN" --region "$REGION" \
  --query '{Runtime: Configuration.Runtime, Handler: Configuration.Handler, Timeout: Configuration.Timeout, MemorySize: Configuration.MemorySize, LastModified: Configuration.LastModified, CodeSha256: Configuration.CodeSha256, EnvVars: Configuration.Environment.Variables}' \
  --output json 2>&1 || echo "ERROR: Lambda not found!"
echo ""

# 2. Check the deployed Step Functions state machine definition
echo "--- Step 2: State Machine Definition (checking for BatchUpdateCompleted) ---"
SM_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
  --query "stateMachines[?name=='${STATE_MACHINE}'].stateMachineArn" --output text)

if [ -z "$SM_ARN" ]; then
  echo "ERROR: State machine '${STATE_MACHINE}' not found!"
else
  echo "State Machine ARN: $SM_ARN"
  DEFINITION=$(aws stepfunctions describe-state-machine --state-machine-arn "$SM_ARN" --region "$REGION" \
    --query 'definition' --output text)

  if echo "$DEFINITION" | python3 -c "import sys, json; d=json.load(sys.stdin); print('BatchUpdateCompleted' in d.get('States', {}))" 2>/dev/null | grep -q "True"; then
    echo "OK: BatchUpdateCompleted step EXISTS in deployed state machine"
  else
    echo "BUG FOUND: BatchUpdateCompleted step MISSING from deployed state machine!"
    echo "FIX: Run 'terraform apply' to deploy the updated state machine"
  fi
  echo ""

  # 3. Check recent executions
  echo "--- Step 3: Recent Execution History ---"
  EXECUTIONS=$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" --region "$REGION" \
    --max-results 5 --query 'executions[*].{ARN:executionArn, Status:status, Start:startDate, Stop:stopDate}' --output json)
  echo "$EXECUTIONS" | python3 -m json.tool
  echo ""

  # 4. Check if BatchUpdateCompleted was reached in the most recent execution
  echo "--- Step 4: Execution Steps for Latest Execution ---"
  LATEST_ARN=$(echo "$EXECUTIONS" | python3 -c "import sys, json; execs=json.load(sys.stdin); print(execs[0]['ARN'] if execs else '')")

  if [ -n "$LATEST_ARN" ]; then
    echo "Checking execution: $LATEST_ARN"
    aws stepfunctions get-execution-history --execution-arn "$LATEST_ARN" --region "$REGION" \
      --query 'events[*].{Id:id, Type:type, Step:stateEnteredEventDetails.name, Input:stateEnteredEventDetails.input, Output:stateExitedEventDetails.output, Error:taskFailedEventDetails.error, Cause:taskFailedEventDetails.cause}' \
      --output json | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    # Filter out None values
    e = {k:v for k,v in e.items() if v is not None}
    if 'Step' in e or 'Error' in e or 'Cause' in e:
        # Truncate long values
        for k in ['Input', 'Output', 'Cause']:
            if k in e and len(str(e[k])) > 200:
                e[k] = str(e[k])[:200] + '...'
        print(json.dumps(e, indent=2, default=str))
"
  fi
fi
echo ""

# 5. Check CloudWatch logs for batch_status_updater
echo "--- Step 5: Recent Batch Status Updater Lambda Logs ---"
LOG_GROUP="/aws/lambda/${BATCH_UPDATER_FN}"
echo "Log group: $LOG_GROUP"

# Get the latest log stream
LATEST_STREAM=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --region "$REGION" \
  --order-by LastEventTime --descending --max-items 1 \
  --query 'logStreams[0].logStreamName' --output text 2>&1)

if [ "$LATEST_STREAM" = "None" ] || [[ "$LATEST_STREAM" == *"ResourceNotFoundException"* ]]; then
  echo "WARNING: No log streams found - Lambda may never have been invoked!"
  echo "This means BatchUpdateCompleted step either:"
  echo " a) Does not exist in the deployed state machine"
  echo " b) Is never reached (execution errors before it)"
  echo " c) Has wrong FunctionName configured"
else
  echo "Latest log stream: $LATEST_STREAM"
  echo ""
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LATEST_STREAM" \
    --region "$REGION" --limit 50 --query 'events[*].message' --output text
fi

echo ""
echo "============================================"
echo " Diagnostic Complete"
echo "============================================"
