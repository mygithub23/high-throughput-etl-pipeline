# Lambda Manifest Builder

**File:** `environments/prod/lambda/lambda_manifest_builder.py`

## Purpose

The Manifest Builder Lambda is the entry point for the pipeline. It:
1. Validates incoming NDJSON files
2. Tracks files in DynamoDB
3. Groups files into batches (manifests)
4. Triggers Glue jobs when batch threshold reached

## Trigger

- **Source:** SQS Queue
- **Batch Size:** 10 messages per invocation
- **Concurrency:** 2 (dev), 50 (prod)

## Processing Flow

```
SQS Message (S3 Event)
        │
        ▼
┌───────────────────┐
│  Parse S3 Event   │
│  Extract: bucket, │
│  key, size        │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐     ┌───────────────────┐
│  Validate File    │────▶│   Quarantine      │
│  - Extension      │ NO  │   Invalid File    │
│  - Size range     │     └───────────────────┘
└─────────┬─────────┘
          │ YES
          ▼
┌───────────────────┐
│  Extract Date     │
│  from filename    │
│  (regex pattern)  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│  Track File in    │
│  DynamoDB         │
│  status: pending  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│  Check Batch      │
│  Threshold        │
│  >= 700 MB?       │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │ NO        │ YES
    ▼           ▼
  Return    ┌───────────────────┐
            │  Acquire Lock     │
            │  (DynamoDB)       │
            └─────────┬─────────┘
                      │
                      ▼
            ┌───────────────────┐
            │  Create Manifest  │
            │  Upload to S3     │
            └─────────┬─────────┘
                      │
                      ▼
            ┌───────────────────┐
            │  Update Status    │
            │  → "manifested"   │
            └─────────┬─────────┘
                      │
                      ▼
            ┌───────────────────┐
            │  Release Lock     │
            └───────────────────┘
```

## Key Functions

### validate_file() - Lines 167-179

Validates incoming files before processing.

```python
def validate_file(key: str, size: int) -> Tuple[bool, str]:
    # Check extension
    if not key.endswith('.ndjson'):
        return False, "Invalid extension"

    # Check size (current: 0.1 MB - 20 MB)
    size_mb = size / (1024 * 1024)
    min_size = EXPECTED_FILE_SIZE_MB * (1 - SIZE_TOLERANCE_PERCENT / 100)
    max_size = EXPECTED_FILE_SIZE_MB * (1 + SIZE_TOLERANCE_PERCENT / 100)

    if size_mb < min_size or size_mb > max_size:
        return False, f"Size {size_mb:.2f}MB out of range"

    return True, "OK"
```

### extract_date_and_filename() - Lines 198-206

Extracts date from file path using regex.

```python
def extract_date_and_filename(key: str) -> Tuple[str, str]:
    parts = key.split('/')
    filename = parts[-1]

    # Find date pattern anywhere in path
    match = re.search(r'(\d{4}-\d{2}-\d{2})', key)
    date_prefix = match.group(1) if match else datetime.utcnow().strftime('%Y-%m-%d')

    return date_prefix, filename
```

**Examples:**
- `folder1/2025-12-23-file001.ndjson` → `("2025-12-23", "2025-12-23-file001.ndjson")`
- `data/file.ndjson` → `("2026-01-15", "file.ndjson")` (uses today's date)

### DistributedLock Class - Lines 49-97

Prevents race conditions when multiple Lambda instances run.

```python
class DistributedLock:
    def acquire(self) -> bool:
        # Uses DynamoDB conditional write
        # Only succeeds if lock doesn't exist OR TTL expired
        self.table.put_item(
            Item={'date_prefix': f'LOCK#{self.lock_key}', ...},
            ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now'
        )

    def release(self):
        # Deletes lock (only if we own it)
        self.table.delete_item(
            ConditionExpression='lock_id = :lock_id'
        )
```

### _create_batches() - Lines 296-317

Groups files into batches up to MAX_BATCH_SIZE_GB.

```python
def _create_batches(files: List[Dict]) -> List[List[Dict]]:
    batches = []
    current_batch = []
    current_size = 0
    max_size = int(MAX_BATCH_SIZE_GB * (1024**3))

    for file_info in files:
        if current_size + file_info['size_bytes'] > max_size and current_batch:
            batches.append(current_batch)
            current_batch = [file_info]
            current_size = file_info['size_bytes']
        else:
            current_batch.append(file_info)
            current_size += file_info['size_bytes']

    # Keep partial batch if >50% full
    if current_batch and (current_size >= max_size * 0.5 or len(batches) == 0):
        batches.append(current_batch)

    return batches
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MANIFEST_BUCKET` | Bucket for manifest files | Required |
| `TRACKING_TABLE` | DynamoDB tracking table | Required |
| `QUARANTINE_BUCKET` | Bucket for invalid files | Optional |
| `MAX_BATCH_SIZE_GB` | Threshold for batch creation | 0.7 |
| `EXPECTED_FILE_SIZE_MB` | Center of validation range | 10 |
| `SIZE_TOLERANCE_PERCENT` | Validation tolerance | 99 |
| `LOCK_TTL_SECONDS` | Lock expiration time | 300 |

## DynamoDB Schema

### Tracking Table Entry

```json
{
  "date_prefix": "2025-12-23",
  "file_name": "2025-12-23-file001.ndjson",
  "file_path": "s3://ndjson-input-bucket/folder1/2025-12-23-file001.ndjson",
  "file_size_mb": 3.5,
  "status": "pending",
  "created_at": "2025-12-23T10:00:00.000Z"
}
```

### Lock Entry

```json
{
  "date_prefix": "LOCK#manifest-2025-12-23",
  "file_name": "LOCK",
  "lock_id": "lambda1_1703332800100",
  "ttl": 1703333100,
  "created_at": "2025-12-23T10:00:00.000Z"
}
```

## Manifest Format

```json
{
  "fileLocations": [
    {
      "URIPrefixes": [
        "s3://ndjson-input-bucket/folder1/2025-12-23-file001.ndjson",
        "s3://ndjson-input-bucket/folder1/2025-12-23-file002.ndjson",
        ...
        "s3://ndjson-input-bucket/folder1/2025-12-23-file200.ndjson"
      ]
    }
  ]
}
```

**S3 Path:** `s3://{MANIFEST_BUCKET}/manifests/{date}/batch-{idx}-{timestamp}.json`

## Concurrency Handling

When multiple Lambda instances process files simultaneously:

1. **File Tracking:** Each Lambda tracks its files independently (no conflict)
2. **Batch Check:** Each Lambda checks if threshold reached
3. **Lock Acquisition:** Only ONE Lambda acquires the lock
4. **Manifest Creation:** Lock owner creates manifest
5. **Lock Release:** Lock released after status updates
6. **Other Lambdas:** Skip manifest creation, continue processing next files
