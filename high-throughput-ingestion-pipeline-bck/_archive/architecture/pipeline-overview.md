# Pipeline Architecture Overview

## High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NDJSON to Parquet Pipeline                         │
└─────────────────────────────────────────────────────────────────────────────┘

     ┌──────────┐     ┌──────────┐     ┌──────────────────┐     ┌──────────┐
     │   S3     │     │   SQS    │     │     Lambda       │     │    S3    │
     │  Input   │────▶│  Queue   │────▶│ Manifest Builder │────▶│ Manifest │
     │  Bucket  │     │          │     │                  │     │  Bucket  │
     └──────────┘     └──────────┘     └──────────────────┘     └──────────┘
          │                                     │                     │
          │                                     ▼                     │
          │                              ┌──────────────┐             │
          │                              │   DynamoDB   │             │
          │                              │   Tracking   │             │
          │                              └──────────────┘             │
          │                                     ▲                     │
          │                                     │                     │
          ▼                                     │                     ▼
     ┌──────────┐                               │              ┌──────────┐
     │    S3    │                               │              │   Glue   │
     │  Output  │◀──────────────────────────────┼──────────────│   Job    │
     │  Bucket  │                               │              │          │
     └──────────┘                               │              └──────────┘
                                                │
                                                │
                                         ┌──────────────────┐
                                         │     Lambda       │
                                         │ State Manager    │
                                         │ (Admin/Ops)      │
                                         └──────────────────┘
```

## Components

### 1. S3 Input Bucket
- Receives NDJSON files (3-4 MB each)
- S3 Event Notification triggers SQS
- Lifecycle policy: 3 days (dev), 7 days (prod)

### 2. SQS Queue
- Batches S3 events (batch_size=10)
- Triggers Lambda Manifest Builder
- Dead Letter Queue for failed messages
- Visibility timeout: 360 seconds

### 3. Lambda Manifest Builder
- **Validates** incoming files (0.1-20 MB range)
- **Tracks** files in DynamoDB (status: pending)
- **Creates manifests** when 200 files (700 MB) accumulated
- **Quarantines** invalid files
- Uses distributed locking for concurrency safety

### 4. DynamoDB Tracking Table
- Partition key: `date_prefix` (e.g., "2025-12-23")
- Sort key: `file_name`
- GSI on `status` for queries
- Tracks file lifecycle: pending → manifested → processing → completed

### 5. S3 Manifest Bucket
- Stores manifest JSON files
- Each manifest lists ~200 NDJSON file paths
- Triggers Glue job via EventBridge

### 6. Glue Batch Job
- Reads manifest file
- Processes NDJSON files in parallel (Spark)
- Converts to Parquet with Snappy compression
- Writes to output bucket with date partitioning

### 7. S3 Output Bucket
- Stores Parquet files
- Partition structure: `merged-parquet-{date}/`
- Files ~128 MB each (optimal for analytics)

### 8. Lambda State Manager (Optional)
- Admin/operations utility
- Scheduled health checks (prod only)
- Manual queries and maintenance
- NOT part of main data flow

## File Status Lifecycle

```
                    ┌─────────────┐
                    │   pending   │ File tracked, waiting for batch
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         ▼
       ┌─────────────┐          ┌─────────────┐
       │  manifested │          │ quarantined │ Invalid file
       └──────┬──────┘          └─────────────┘
              │
              ▼
       ┌─────────────┐
       │  processing │ Glue job running
       └──────┬──────┘
              │
      ┌───────┴───────┐
      │               │
      ▼               ▼
┌─────────────┐ ┌─────────────┐
│  completed  │ │   failed    │
└─────────────┘ └─────────────┘
```

## Configuration Summary

| Setting | Dev | Prod |
|---------|-----|------|
| Files per manifest | 200 | 200 |
| Batch size threshold | 700 MB | 700 MB |
| File validation range | 0.1-20 MB | 0.1-20 MB |
| Lambda concurrency | 2 | 50 |
| Glue workers | 2 (G.1X) | 20 (G.2X) |
| Max concurrent Glue jobs | 1 | 30 |

## Security

- **No API Gateway** - Pipeline is completely private
- **S3 Encryption** - AES256 (SSE-S3) on all buckets
- **IAM Least Privilege** - Role-based access control
- **VPC** - Optional, not required for current design
