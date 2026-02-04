# Glue Batch Job

**File:** `environments/prod/glue/glue_batch_job.py`

## Purpose

AWS Glue job that converts NDJSON files to Parquet format using Apache Spark.

## Trigger

- **Source:** Manifest file created in S3
- **Input:** `--MANIFEST_PATH` parameter (S3 path to manifest JSON)
- **Mode:** Batch only (no streaming to prevent 24/7 execution)

## Processing Flow

```
                    ┌─────────────────────────┐
                    │  Manifest JSON (S3)     │
                    │                         │
                    │  Contains: List of 200  │
                    │  NDJSON file paths      │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  ManifestProcessor      │
                    │  __init__()             │
                    │  - Configure Spark      │
                    │  - Initialize stats     │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  process_manifest()     │
                    │  - Download manifest    │
                    │  - Extract date prefix  │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  _read_and_merge_ndjson │
                    │  - Spark reads 200 files│
                    │  - Add metadata columns │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  _cast_all_to_string    │
                    │  - Schema consistency   │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  _write_parquet         │
                    │  - Coalesce partitions  │
                    │  - Write with Snappy    │
                    │  - ~128 MB per file     │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  Output: Parquet Files  │
                    │                         │
                    │  s3://output-bucket/    │
                    │  merged-parquet-{date}/ │
                    │  ├── part-00000.parquet │
                    │  ├── part-00001.parquet │
                    │  └── part-00002.parquet │
                    └─────────────────────────┘
```

## ManifestProcessor Class

### Initialization (Lines 45-71)

```python
def __init__(
    self,
    spark: SparkSession,
    glue_context: GlueContext,
    manifest_bucket: str,
    output_bucket: str,
    compression: str = 'snappy'
):
    self.spark = spark
    self.glue_context = glue_context
    self.manifest_bucket = manifest_bucket
    self.output_bucket = output_bucket
    self.compression = compression

    self._configure_spark()

    self.stats = {
        'batches_processed': 0,
        'records_processed': 0,
        'errors': 0,
        'start_time': datetime.utcnow().isoformat()
    }
```

### Spark Configuration (Lines 73-84)

```python
def _configure_spark(self):
    # Adaptive Query Execution
    self.spark.conf.set("spark.sql.adaptive.enabled", "true")
    self.spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")

    # Parquet settings
    self.spark.conf.set("spark.sql.parquet.compression.codec", self.compression)
    self.spark.conf.set("spark.sql.parquet.mergeSchema", "false")
    self.spark.conf.set("spark.sql.parquet.filterPushdown", "true")

    # File and partition settings
    self.spark.conf.set("spark.sql.files.maxPartitionBytes", "134217728")  # 128 MB
    self.spark.conf.set("spark.sql.shuffle.partitions", "100")

    # S3 optimization
    self.spark.conf.set("spark.hadoop.fs.s3a.fast.upload", "true")
    self.spark.conf.set("spark.hadoop.fs.s3a.multipart.size", "104857600")  # 100 MB
```

### Read NDJSON Files (Lines 138-150)

```python
def _read_and_merge_ndjson(self, file_paths: List[str]) -> Optional[DataFrame]:
    # Read all NDJSON files in parallel
    df = self.spark.read.json(file_paths, multiLine=False)

    # Add metadata columns for audit trail
    df = df.withColumn("_processing_timestamp", F.current_timestamp())
    df = df.withColumn("_source_file", F.input_file_name())

    return df
```

### Cast to String (Lines 152-159)

Ensures schema consistency by converting all columns to string.

```python
def _cast_all_to_string(self, df: DataFrame) -> DataFrame:
    string_columns = [
        F.col(col_name).cast(StringType()).alias(col_name)
        for col_name in df.columns
    ]
    return df.select(string_columns)
```

**Why cast to string?**
- NDJSON files may have inconsistent data types
- Prevents schema conflicts during merge
- Simplifies downstream processing

### Write Parquet (Lines 166-188)

```python
def _write_parquet(self, df: DataFrame, output_path: str) -> int:
    # Cache for count + write
    df.cache()
    record_count = df.count()

    # Calculate optimal partitions (~128 MB each)
    estimated_size_mb = record_count / 1024
    num_partitions = max(int(estimated_size_mb / 128), 1)

    # Coalesce to reduce output files
    df_coalesced = df.coalesce(num_partitions)
    df_coalesced.write.mode('append').parquet(
        output_path,
        compression=self.compression
    )

    # Release cache
    df.unpersist()

    return record_count
```

## Input/Output

### Input: Manifest JSON

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

### Output: Parquet Files

```
s3://ndjson-output-bucket/
└── merged-parquet-2025-12-23/
    ├── part-00000.snappy.parquet  (~128 MB)
    ├── part-00001.snappy.parquet  (~128 MB)
    └── part-00002.snappy.parquet  (~85 MB)
```

## Configuration

### Glue Job Parameters

| Parameter | Description |
|-----------|-------------|
| `JOB_NAME` | Glue job name |
| `MANIFEST_BUCKET` | S3 bucket containing manifests |
| `OUTPUT_BUCKET` | S3 bucket for Parquet output |
| `COMPRESSION_TYPE` | Compression codec (default: snappy) |
| `MANIFEST_PATH` | S3 path to specific manifest file |

### Terraform Configuration

| Setting | Dev | Prod |
|---------|-----|------|
| `glue_worker_type` | G.1X | G.2X |
| `glue_number_of_workers` | 2 | 20 |
| `glue_max_concurrent_runs` | 1 | 30 |
| `glue_timeout` | 2880 min | 2880 min |
| `glue_max_retries` | 0 | 2 |

## Performance Characteristics

### With 200 files (700 MB):

| Metric | Value |
|--------|-------|
| Input files | 200 NDJSON (~3.5 MB each) |
| Total input size | ~700 MB |
| Output files | 2-3 Parquet files |
| Output size | ~200-300 MB (after compression) |
| Processing time | ~5-7 minutes |

### Spark Optimizations Applied

1. **Adaptive Query Execution** - Dynamically optimizes query plans
2. **Partition Coalescing** - Reduces small partitions
3. **S3 Fast Upload** - Multipart uploads with 100 MB chunks
4. **Filter Pushdown** - Pushes filters to storage layer
5. **Snappy Compression** - Fast read/write with good compression ratio
