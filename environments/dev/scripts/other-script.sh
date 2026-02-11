#!/bin/bash


aws dynamodb delete-table --table-name ndjson-parquet-sqs-file-tracking-dev



 TABLE_NAME="ndjson-parquet-sqs-file-tracking-dev"
 AWS_REGION="us-east-1"





delete_by_date() {
    # local date_prefix="$1"

    echo -e "${RED}WARNING: This will delete ALL records for date: ${date_prefix}${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    # First, get all file_keys for this date
    echo "Finding records..."
    keys=$(aws dynamodb execute-statement \
        --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE date_prefix='${date_prefix}'" \
        --region "$REGION" \
        --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    dp = item['date_prefix']['S']
    fk = item['file_key']['S']
    print(f'{dp}|{fk}')
")

    count=0
    while IFS='|' read -r dp fk; do
        if [ -n "$dp" ] && [ -n "$fk" ]; then
            echo "  Deleting: $dp / $fk"
            aws dynamodb delete-item \
                --table-name "$TABLE_NAME" \
                --key "{\"date_prefix\": {\"S\": \"$dp\"}, \"file_key\": {\"S\": \"$fk\"}}" \
                --region "$REGION"
            ((count++))
        fi
    done <<< "$keys"

    echo -e "${GREEN}Deleted $count records${NC}"
}

delete_by_date

export TABLE_NAME="ndjson-parquet-sqs-file-tracking-dev"
export AWS_REGION="us-east-1"

# First, get all file_keys for this date
echo "Finding records..."
aws dynamodb execute-statement \
    --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" " \
    --region "$REGION" \
    --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    dp = item['date_prefix']['S']
    fk = item['file_key']['S']
    print(f'{dp}|{fk}')
"



#     # First, get all file_keys for this date
#     echo "Finding records..."
#     keys=$(aws dynamodb execute-statement \
#         --statement "SELECT date_prefix, file_key FROM \"${TABLE_NAME}\" WHERE date_prefix='${date_prefix}'" \
#         --region "$REGION" \
#         --output json | python3 -c "
# import sys, json
# data = json.load(sys.stdin)
# for item in data.get('Items', []):
#     dp = item['date_prefix']['S']
#     fk = item['file_key']['S']
#     print(f'{dp}|{fk}')
# ")
