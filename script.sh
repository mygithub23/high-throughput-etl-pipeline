
# The user wants a command to export S3 bucket object metadata (filename, modified datetime, size) to a CSV file. This is a straightforward AWS CLI question.
aws s3api list-objects-v2 --bucket YOUR_BUCKET_NAME --prefix "pipeline/input/" --region us-east-1 --query 'Contents[*].[Key,LastModified,Size]' --output text | tr '\t' ',' | sed '1i\filename,modified,size_bytes' > output/s3-objects.csv


# Or for a cleaner output with human-readable sizes:
# Replace the bucket name and prefix as needed. For the output bucket use ndjson-output-sqs-804450520964-dev, etc.
aws s3api list-objects-v2 --bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/" --region us-east-1 --output json | python3 -c "
import sys, json, csv
data = json.load(sys.stdin)
w = csv.writer(sys.stdout)
w.writerow(['filename', 'modified', 'size_bytes', 'size_mb'])
for obj in data.get('Contents', []):
    name = obj['Key'].split('/')[-1]
    w.writerow([name, obj['LastModified'], obj['Size'], f\"{obj['Size']/1024/1024:.4f}\"])
" > output/s3-objects.csv


# For a specific date's objects, add --query filtering on the key pre
aws s3api list-objects-v2 --bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/2026-02-06" --region us-east-1 --output json | python3 -c "
import sys, json, csv
data = json.load(sys.stdin)
w = csv.writer(sys.stdout)
w.writerow(['filename', 'modified', 'size_bytes', 'size_mb'])
for obj in data.get('Contents', []):
    name = obj['Key'].split('/')[-1]
    w.writerow([name, obj['LastModified'], obj['Size'], f\"{obj['Size']/1024/1024:.4f}\"])
" > output/s3-input-2026-02-06.csv


# Just change the date in the --prefix value. Works for any bucket:

# Input bucket
--bucket ndjson-input-sqs-804450520964-dev --prefix "pipeline/input/2026-02-06"

# Output bucket (parquet files)
--bucket ndjson-output-sqs-804450520964-dev --prefix "pipeline/output/2026-02-06"

# Manifests
--bucket ndjson-manifest-sqs-804450520964-dev --prefix "manifests/2026-02-06"
