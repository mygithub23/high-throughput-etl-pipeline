#!/bin/bash
###############################################################################
# ONE-TIME REMEDIATION: Update stuck "manifested" files to "completed"
#
# Background: A bug in Step Functions (hardcoded file_key="MANIFEST" instead
# of using $.file_key) caused individual file records to never be updated
# past "manifested" status, even though Glue successfully processed them.
#
# This script:
# 1. Scans for all records with status beginning with "manifested"
# 2. Updates each record's status to "completed" (preserving shard suffix)
# 3. Logs all changes for audit trail
#
# Prerequisites:
# - AWS CLI configured with appropriate credentials
# - jq installed
#
# Usage:
# # Dry run (default) - shows what would be changed
# ./remediate-manifested-files.sh
#
# # Execute changes
# ./remediate-manifested-files.sh --execute
###############################################################################

set -euo pipefail

TABLE_NAME="ndjson-parquet-sqs-file-tracking-dev"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
DRY_RUN=true
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_FILE="remediation-${TIMESTAMP//[:.]/-}.log"

if [[ "${1:-}" == "--execute" ]]; then
    DRY_RUN=false
    echo "=== EXECUTE MODE: Changes WILL be written to DynamoDB ==="
else
    echo "=== DRY RUN MODE: No changes will be made (use --execute to apply) ==="
fi

echo "Table: ${TABLE_NAME}"
echo "Region: ${REGION}"
echo "Log file: ${LOG_FILE}"
echo ""

# Scan for all records with status beginning with "manifested"
# Excludes MANIFEST# and LOCK# meta-records
echo "Scanning for stuck 'manifested' file records..."

TOTAL=0
UPDATED=0
ERRORS=0

scan_and_update() {
    local start_key=""
    local scan_args

    while true; do
        scan_args=(
            dynamodb scan
            --table-name "${TABLE_NAME}"
            --filter-expression "begins_with(#s, :status_prefix) AND NOT begins_with(file_key, :manifest_prefix) AND NOT begins_with(file_key, :lock_prefix)"
            --expression-attribute-names '{"#s": "status"}'
            --expression-attribute-values '{":status_prefix": {"S": "manifested"}, ":manifest_prefix": {"S": "MANIFEST#"}, ":lock_prefix": {"S": "LOCK#"}}'
            --projection-expression "date_prefix, file_key, #s, manifest_path"
            --region "${REGION}"
        )

        if [[ -n "${start_key}" ]]; then
            scan_args+=(--exclusive-start-key "${start_key}")
        fi

        result=$(aws "${scan_args[@]}")
        items=$(echo "${result}" | jq -c '.Items[]')

        while IFS= read -r item; do
            [[ -z "${item}" ]] && continue

            date_prefix=$(echo "${item}" | jq -r '.date_prefix.S')
            file_key=$(echo "${item}" | jq -r '.file_key.S')
            current_status=$(echo "${item}" | jq -r '.status.S')
            manifest_path=$(echo "${item}" | jq -r '.manifest_path.S // "unknown"')

            # Compute new status: manifested -> completed (preserve shard suffix)
            if [[ "${current_status}" == *"#"* ]]; then
                shard_suffix="#${current_status#*#}"
                new_status="completed${shard_suffix}"
            else
                new_status="completed"
            fi

            TOTAL=$((TOTAL + 1))

            if [[ "${DRY_RUN}" == true ]]; then
                echo "[DRY RUN] ${date_prefix}/${file_key}: ${current_status} -> ${new_status}" | tee -a "${LOG_FILE}"
            else
                echo "Updating ${date_prefix}/${file_key}: ${current_status} -> ${new_status}" | tee -a "${LOG_FILE}"

                if aws dynamodb update-item \
                    --table-name "${TABLE_NAME}" \
                    --key "{\"date_prefix\": {\"S\": \"${date_prefix}\"}, \"file_key\": {\"S\": \"${file_key}\"}}" \
                    --update-expression "SET #s = :new_status, updated_at = :ua, remediation_note = :note" \
                    --expression-attribute-names '{"#s": "status"}' \
                    --expression-attribute-values "{\":new_status\": {\"S\": \"${new_status}\"}, \":ua\": {\"S\": \"${TIMESTAMP}\"}, \":note\": {\"S\": \"Remediated from ${current_status} - Step Functions bug fix\"}}" \
                    --region "${REGION}" 2>>"${LOG_FILE}"; then
                    UPDATED=$((UPDATED + 1))
                else
                    ERRORS=$((ERRORS + 1))
                    echo " ERROR updating ${file_key}" | tee -a "${LOG_FILE}"
                fi
            fi
        done <<< "${items}"

        # Check for pagination
        start_key=$(echo "${result}" | jq -r '.LastEvaluatedKey // empty')
        if [[ -z "${start_key}" ]]; then
            break
        fi
    done
}

scan_and_update

echo ""
echo "=== Summary ==="
echo "Total manifested records found: ${TOTAL}"
if [[ "${DRY_RUN}" == true ]]; then
    echo "Mode: DRY RUN (no changes made)"
    echo "Run with --execute to apply changes"
else
    echo "Successfully updated: ${UPDATED}"
    echo "Errors: ${ERRORS}"
fi
echo "Log file: ${LOG_FILE}"
