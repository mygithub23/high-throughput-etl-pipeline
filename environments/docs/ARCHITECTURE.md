# NDJSON to Parquet Pipeline Architecture

## Overview

This pipeline converts NDJSON files to Parquet format using AWS serverless services.

## Architecture Diagram (Mermaid)

```mermaid
flowchart LR
    subgraph Input["1. Data Ingestion"]
        S3_IN[("S3 Input Bucket<br/>NDJSON files")]
    end

    subgraph Events["2. Event Processing"]
        SQS[["SQS Queue"]]
        DLQ[["Dead Letter Queue"]]
    end

    subgraph Lambda["3. Manifest Builder"]
        LMB["Lambda Function"]
        DDB[("DynamoDB<br/>File Tracking")]
    end

    subgraph Orchestration["4. Orchestration"]
        SFN{{"Step Functions"}}
    end

    subgraph ETL["5. ETL Processing"]
        GLUE["Glue Job<br/>(Spark)"]
        MANIFEST[("S3 Manifest<br/>Bucket")]
    end

    subgraph Output["6. Output"]
        S3_OUT[("S3 Output Bucket<br/>Parquet files")]
    end

    subgraph Monitor["7. Monitoring"]
        CW["CloudWatch"]
        SNS["SNS Alerts"]
    end

    S3_IN -->|"S3 Event"| SQS
    SQS -->|"Trigger"| LMB
    SQS -.->|"Failed msgs"| DLQ
    LMB -->|"Track files"| DDB
    LMB -->|"Create manifest"| MANIFEST
    LMB -->|"Start workflow"| SFN
    SFN -->|"Update status"| DDB
    SFN -->|"Start job"| GLUE
    GLUE -->|"Read manifest"| MANIFEST
    GLUE -->|"Read data"| S3_IN
    GLUE -->|"Write parquet"| S3_OUT
    SFN -.->|"On failure"| SNS
    LMB -.-> CW
    GLUE -.-> CW
    SFN -.-> CW
```

## Data Flow Diagram (Mermaid)

```mermaid
sequenceDiagram
    participant User as Data Producer
    participant S3In as S3 Input Bucket
    participant SQS as SQS Queue
    participant Lambda as Lambda (Manifest Builder)
    participant DDB as DynamoDB
    participant S3Man as S3 Manifest Bucket
    participant SFN as Step Functions
    participant Glue as Glue Job
    participant S3Out as S3 Output Bucket

    User->>S3In: Upload NDJSON file
    S3In->>SQS: S3 ObjectCreated event
    SQS->>Lambda: Trigger (batch of 10)

    loop For each file
        Lambda->>DDB: Track file (status=pending)
    end

    Lambda->>DDB: Query pending files

    alt 10+ files pending
        Lambda->>S3Man: Create manifest.json
        Lambda->>SFN: Start execution
        SFN->>DDB: Update status=processing
        SFN->>Glue: StartJobRun.sync
        Glue->>S3Man: Read manifest
        Glue->>S3In: Read NDJSON files
        Glue->>S3Out: Write Parquet files
        Glue-->>SFN: Job completed
        SFN->>DDB: Update status=completed
    else Less than 10 files
        Lambda-->>Lambda: Wait for more files
    end
```

## Component Details

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| Input Bucket | S3 | Receives NDJSON files |
| Event Queue | SQS | Buffers S3 events, enables batching |
| Dead Letter Queue | SQS | Captures failed messages |
| Manifest Builder | Lambda | Tracks files, creates manifests |
| File Tracking | DynamoDB | Stores file metadata and status |
| Manifest Bucket | S3 | Stores manifest JSON files |
| Workflow | Step Functions | Orchestrates Glue job execution |
| ETL Job | Glue | Converts NDJSON to Parquet |
| Output Bucket | S3 | Stores Parquet files |
| Monitoring | CloudWatch | Logs and metrics |
| Alerts | SNS | Failure notifications |

## File Flow

```
Input:  s3://input-bucket/pipeline/input/2025-01-17-file001.ndjson
                    ↓
Manifest: s3://manifest-bucket/manifests/2025-01-17/batch-0001.json
                    ↓
Output: s3://output-bucket/pipeline/output/year=2025/month=01/day=17/part-00000.snappy.parquet
```

## How to Generate PNG Diagrams

### Option 1: Python Diagrams Library

```bash
# Install
pip install diagrams

# Generate
cd docs
python architecture_diagram.py
python data_flow_diagram.py
```

### Option 2: Mermaid Live Editor

1. Go to https://mermaid.live
2. Paste the Mermaid code from above
3. Export as PNG or SVG

### Option 3: Draw.io / Diagrams.net

1. Go to https://app.diagrams.net
2. Use AWS icon shapes library
3. Manually create the diagram

### Option 4: AWS Architecture Icons

Download official icons from:
https://aws.amazon.com/architecture/icons/
