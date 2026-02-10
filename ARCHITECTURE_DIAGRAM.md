# AWS Architecture Diagram

## NDJSON-to-Parquet High-Throughput ETL Pipeline

```
 INGESTION LAYER                    ORCHESTRATION LAYER                    PROCESSING LAYER
 ==================                 =======================                ==================

                                                                          +------------------+
                                                                          | CloudWatch       |
                                                                          | Dashboard        |
                                                                          | Alarms & Metrics |
                                                                          +--------+---------+
                                                                                   |
                                                                          +--------+---------+
                                                                          | SNS Topic        |
                                                                          | (alerts)         |
                                                                          | Email notif.     |
                                                                          +--------+---------+
                                                                                   ^
                                                                                   | failure alerts
                                                                                   |
 +----------------+    +------------------+    +----------------------+    +--------+---------+
 |                |    |                  |    |                      |    |                  |
 | S3 Bucket      |    | SQS Queue        |    | Lambda              |    | Step Functions   |
 | (input)        +--->| (file-events)    +--->| (manifest_builder)  +--->| (processor)      |
 |                |    |                  |    |                      |    | Standard         |
 | landing/       |    | visibility: 360s |    | - validate files     |    |                  |
 |  ndjson/       |    | batch size: 10   |    | - track in DynamoDB  |    | 1. UpdateStatus  |
 |   YYYY-MM-DD/  |    | long poll: 20s   |    | - create manifests   |    |    Processing    |
 |    *.ndjson    |    | retention: 4d    |    | - claim files atomic |    | 2. StartGlueJob  |
 |                |    |                  |    | - orphan flush       |    |    (.sync wait)  |
 +----------------+    +--------+---------+    | - circuit breaker    |    | 3. UpdateStatus  |
       |                        |              |                      |    |    Completed     |
       | S3 Event               | max 3        +---+--+---+----------+    | 4. BatchUpdate   |
       | Notification           | retries          |  |   |               |    Completed     |
       v                        v                  |  |   |               | 5. Succeed       |
 +----------------+    +------------------+        |  |   |               +--------+---------+
 | S3 Bucket      |    | SQS DLQ          |        |  |   |                        |
 | (quarantine)   |    | (dead-letter)    |        |  |   |                        |
 |                |    | retention: 14d   |        |  |   |                        v
 | Invalid files  |    | Failed messages  |        |  |   |               +--------+---------+
 +----------------+    +------------------+        |  |   |               |                  |
                                                   |  |   |               | Glue Job         |
                                                   |  |   |               | (batch)          |
                                                   |  |   |               |                  |
                       +---------------------------+  |   |               | - Spark/PySpark  |
                       |                              |   |               | - Glue 4.0       |
                       v                              |   |               | - Read manifest  |
              +--------+---------+                    |   |               | - Read NDJSON    |
              |                  |                    |   |               | - Cast to string |
              | S3 Bucket        |                    |   |               | - Write Parquet  |
              | (manifest)       |                    |   |               |   + Snappy       |
              |                  |                    |   |               +--------+---------+
              | manifests/       |                    |   |                        |
              |  YYYY-MM-DD/     |                    |   |                        v
              |   batch-*.json   |                    |   |               +--------+---------+
              | logs/            |                    |   |               |                  |
              |  lambda/*.json   |                    |   |               | S3 Bucket        |
              |  glue/*.json     |                    |   |               | (output)         |
              +------------------+                    |   |               |                  |
                                                      |   |               | pipeline/output/ |
                       +------------------------------+   |               |  merged-parquet- |
                       |                                  |               |   YYYY-MM-DD/    |
                       v                                  |               |    *.parquet     |
              +--------+---------+                        |               +------------------+
              |                  |                        |
              | DynamoDB         |                        |
              | (file-tracking)  |<---------+             |
              |                  |          |             |
              | PK: date_prefix  |          |             |
              | SK: file_key     |          |             |
              |                  |          |             |
              | GSI: status-index|     +----+-------------+------+
              |  (10 shards)     |     |                         |
              |                  |     | Lambda                  |
              | TTL: 30 days     |     | (batch_status_updater)  |
              +--------+---------+     |                         |
                       |               | Invoked by Step         |
                       |               | Functions after Glue    |
                       |               | completes (success or   |
                       |               | failure). Batch-updates |
                       |               | individual file records.|
                       |               +-------------------------+
                       |
                       | DynamoDB Streams (Phase 3, feature flag)
                       |
                       v
              +--------+---------+
              |                  |
              | Lambda           |
              | (stream_manifest |
              |  _creator)       |
              |                  |
              | Event-driven     |
              | manifest creation|
              | (alternative to  |
              |  polling-based)  |
              +------------------+


    OPTIONAL: EventBridge Decoupling (Phase 3, feature flag)
    =========================================================

              +----------------------+        +------------------+
              | Lambda               |        | EventBridge      |
              | (manifest_builder)   +------->| (etl bus)        |
              |                      |        |                  |
              | publishes            |        | ManifestReady    +--------> Step Functions
              | ManifestReady event  |        | event routing    |          (processor)
              | with circuit breaker |        |                  |
              +----------------------+        +------------------+
```

## Data Flow Summary

```
  *.ndjson ──> S3 ──> SQS ──> Lambda ──> DynamoDB (pending#N)
                                 |
                                 +--> S3 manifest JSON
                                 |
                                 +--> Step Functions ──> Glue ──> S3 (*.parquet)
                                                           |
                                                           +--> Lambda (batch_status_updater)
                                                                  |
                                                                  +--> DynamoDB (completed#N)
```

## Status Lifecycle

```
  File Record:      pending#N ────> manifested#N ────> completed#N
                                         |
                                         +────────────> failed#N

  MANIFEST Record:  pending ──> processing ──> completed
                                     |
                                     +────────> failed ──> SNS Alert
```

## DynamoDB Table Design

```
  ndjson-parquet-sqs-file-tracking-{env}
  ============================================================

  Partition Key: date_prefix (S)     Sort Key: file_key (S)
  ────────────────────────────────────────────────────────────
  2026-02-01     data-001.ndjson     status=pending#3, file_path=s3://..., shard_id=3
  2026-02-01     data-002.ndjson     status=manifested#7, manifest_path=s3://...
  2026-02-01     data-003.ndjson     status=completed#1, glue_job_run_id=jr_xxx
  2026-02-01     MANIFEST#batch-0001-20260201-120000.json    status=processing
  LOCK#2026-02-01  LOCK              lock_id=..., ttl=...  (legacy)
  ────────────────────────────────────────────────────────────

  GSI: status-index
    Hash Key: status (S)   Range Key: date_prefix (S)
    Projection: ALL
    10 shards: pending#0 .. pending#9, manifested#0 .. manifested#9, etc.
```

## Step Functions State Machine

```
                        +---------------------------+
                        |    UpdateStatusProcessing  |
                        |    (DynamoDB: MANIFEST     |
                        |     -> "processing")       |
                        +-------------+-------------+
                                      |
                                      v
                        +-------------+-------------+
                        |       StartGlueJob        |
                        |    (glue:startJobRun.sync) |
                        |                           |
                        | Retry: ConcurrentRuns x3  |
                        | Wait: 60s, backoff 2x     |
                        +------+------------+-------+
                               |            |
                          success        failure
                               |            |
                               v            v
                   +-----------+--+  +------+------------+
                   | UpdateStatus |  | UpdateStatus      |
                   | Completed    |  | Failed            |
                   | (MANIFEST -> |  | (MANIFEST ->      |
                   |  "completed")|  |  "failed")        |
                   +------+-------+  +------+------------+
                          |                 |
                          v                 v
                   +------+-------+  +------+------------+
                   | BatchUpdate  |  | BatchUpdate       |
                   | Completed    |  | Failed            |
                   | (Lambda:     |  | (Lambda:          |
                   |  files ->    |  |  files ->         |
                   |  completed#N)|  |  failed#N)        |
                   +------+-------+  +------+------------+
                          |                 |
                          v                 v
                   +------+-------+  +------+------------+
                   | Pipeline     |  | SendFailure       |
                   | Succeeded    |  | Alert (SNS)       |
                   +-- (Succeed) -+  +---- (End) --------+
```

## Resource Naming Convention

```
  Pattern: ndjson-parquet-{component}-{environment}

  S3:              ndjson-parquet-{input|manifest|output|quarantine|scripts}-{env}-{account_id}
  SQS:             ndjson-parquet-{file-events|dlq}-{env}
  Lambda:          ndjson-parquet-{manifest-builder|batch-status-updater|stream-manifest-creator}-{env}
  DynamoDB:        ndjson-parquet-sqs-{file-tracking|metrics}-{env}
  Step Functions:  ndjson-parquet-processor-{env}
  Glue:            ndjson-parquet-batch-job-{env}
  EventBridge:     ndjson-parquet-etl-{env}
  SNS:             ndjson-parquet-alerts-{env}
  CloudWatch:      ndjson-parquet-pipeline-{env}   (dashboard)
```
