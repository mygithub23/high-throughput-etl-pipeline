# Lambda State Manager

**File:** `environments/prod/lambda/lambda_state_manager.py`

## Purpose

Admin/operations utility Lambda that provides:
- Pipeline monitoring and queries
- Health checks and orphan detection
- Manual state management
- Troubleshooting tools

**Important:** This Lambda is NOT part of the main data flow. The pipeline works without it.

## Triggers

| Trigger | Frequency | Operation | Environment |
|---------|-----------|-----------|-------------|
| EventBridge Schedule | Every 6 hours | `find_orphans` | Prod only |
| EventBridge Schedule | Every 1 hour | `get_stats` | Prod only |
| Manual (CLI/Console) | On-demand | Any | All |

**Note:** Schedules controlled by `enable_schedules` variable in Terraform.

## Operations

### Query Operations (Read-Only)

| Operation | Description | Parameters |
|-----------|-------------|------------|
| `get_file_state` | Get state of specific file(s) | `date_prefix`, `file_key` (optional) |
| `query_by_status` | Find files by status | `status`, `limit`, `date_range` |
| `get_stats` | Count files by status | `date_prefix` (optional) |
| `get_processing_timeline` | Track file's journey | `date_prefix`, `file_key` |

### Maintenance Operations

| Operation | Description | Parameters |
|-----------|-------------|------------|
| `find_orphans` | Find stuck/inconsistent files | `max_processing_hours` |
| `reset_stuck_files` | Reset stuck files to pending | `max_processing_hours`, `dry_run` |
| `validate_consistency` | Check S3/DynamoDB sync | `date_prefix` |

### Admin Operations (Write)

| Operation | Description | Parameters |
|-----------|-------------|------------|
| `update_state` | Change single file's status | `date_prefix`, `file_key`, `new_status` |
| `batch_update` | Change multiple files' status | `files` (list) |

## Usage Examples

### Get Stats
```bash
aws lambda invoke \
  --function-name ndjson-parquet-state-management-prod \
  --payload '{"operation": "get_stats"}' \
  response.json
```

**Response:**
```json
{
  "stats": {
    "pending": 50,
    "manifested": 100,
    "processing": 5,
    "completed": 1000,
    "failed": 2,
    "quarantined": 10
  },
  "total": 1167
}
```

### Find Orphans
```bash
aws lambda invoke \
  --function-name ndjson-parquet-state-management-prod \
  --payload '{"operation": "find_orphans", "max_processing_hours": 2}' \
  response.json
```

**Response:**
```json
{
  "total_orphans": 3,
  "orphans": {
    "stuck_in_processing": [
      {"date_prefix": "2025-12-23", "file_key": "file001.ndjson", "hours_stuck": 4.5}
    ],
    "missing_manifests": [],
    "missing_outputs": []
  }
}
```

### Reset Stuck Files (Dry Run)
```bash
aws lambda invoke \
  --function-name ndjson-parquet-state-management-prod \
  --payload '{"operation": "reset_stuck_files", "max_processing_hours": 2, "dry_run": true}' \
  response.json
```

### Query Files by Status
```bash
aws lambda invoke \
  --function-name ndjson-parquet-state-management-prod \
  --payload '{"operation": "query_by_status", "status": "failed", "limit": 50}' \
  response.json
```

### Get Processing Timeline
```bash
aws lambda invoke \
  --function-name ndjson-parquet-state-management-prod \
  --payload '{"operation": "get_processing_timeline", "date_prefix": "2025-12-23", "file_key": "file001.ndjson"}' \
  response.json
```

**Response:**
```json
{
  "file": "2025-12-23/file001.ndjson",
  "current_status": "completed",
  "timeline": [
    {"event": "uploaded", "timestamp": "2025-12-23T10:00:00Z", "status": "pending"},
    {"event": "manifested", "timestamp": "2025-12-23T10:00:30Z", "status": "manifested"},
    {"event": "processing_started", "timestamp": "2025-12-23T10:01:00Z", "status": "processing"},
    {"event": "completed", "timestamp": "2025-12-23T10:05:00Z", "status": "completed"}
  ],
  "durations_seconds": {
    "uploaded_to_manifested": 30,
    "manifested_to_processing_started": 30,
    "processing_started_to_completed": 240
  },
  "total_processing_time": 300
}
```

## Modularity

### Independence

Each operation is completely independent. You can:
- Remove any function without affecting others
- Add new functions easily
- Modify existing functions

### To Remove Metrics (Example)

**Option 1: Disable schedules (no code change)**
```hcl
# In terraform/main.tf
enable_schedules = false
```

**Option 2: Remove get_stats function**
```python
# Delete lines 418-450 from lambda_state_manager.py
# Remove from handler (lines 91-92):
# elif operation == 'get_stats':
#     return get_stats(event)
```

### To Add Custom Function

```python
# Add to handler
elif operation == 'my_custom_operation':
    return my_custom_operation(event)

# Add function
def my_custom_operation(event: Dict[str, Any]) -> Dict[str, Any]:
    # Your implementation
    return {'statusCode': 200, 'body': json.dumps(result)}
```

## Architecture Position

```
┌─────────────────────────────────────────────────────────────┐
│                     MAIN PIPELINE                            │
│                                                              │
│  S3 → SQS → Lambda Manifest Builder → Manifest → Glue       │
│                      │                                       │
│                      ▼                                       │
│                  DynamoDB ◀───────────────────────┐         │
│                                                    │         │
└────────────────────────────────────────────────────┼─────────┘
                                                     │
                                              (reads/writes)
                                                     │
┌────────────────────────────────────────────────────┼─────────┐
│               OPERATIONS (SEPARATE)                │         │
│                                                    │         │
│  EventBridge ──▶ Lambda State Manager ◀── AWS CLI │         │
│  (scheduled)          │                 (manual)  │         │
│                       ▼                           │         │
│              CloudWatch Logs                      │         │
│              CloudWatch Metrics                   │         │
│              CloudWatch Dashboard                 │         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Key Point:** The State Manager is a **support service**, not a core pipeline component.
