"""
AWS Glue Batch Job: NDJSON to Parquet Converter (Batch-Only Mode)
===================================================================

This Glue job processes manifest files containing batches of NDJSON files,
converts them to Parquet format with date-based partitioning, and writes to S3.

BATCH MODE ONLY - Requires --MANIFEST_PATH parameter
This version removes streaming to prevent accidental 24/7 execution.

Author: Data Engineering Team
Version: 1.2.0 (Batch-only for cost optimization)
"""

import sys
import json
import logging
from datetime import datetime
from typing import List, Dict, Optional

import boto3
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

# Initialize logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# AWS clients
s3_client = boto3.client('s3')
cloudwatch = boto3.client('cloudwatch')


class ManifestProcessor:
    """Process manifest files and convert NDJSON to Parquet."""

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

        logger.info(
            f"Initialized processor - Manifests: {manifest_bucket}, "
            f"Output: {output_bucket}, Compression: {compression}"
        )

    def _configure_spark(self):
        """Configure Spark settings for optimal performance."""
        self.spark.conf.set("spark.sql.adaptive.enabled", "true")
        self.spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
        self.spark.conf.set("spark.sql.parquet.compression.codec", self.compression)
        self.spark.conf.set("spark.sql.parquet.mergeSchema", "false")
        self.spark.conf.set("spark.sql.parquet.filterPushdown", "true")
        self.spark.conf.set("spark.sql.files.maxPartitionBytes", "134217728")
        self.spark.conf.set("spark.sql.shuffle.partitions", "100")
        self.spark.conf.set("spark.hadoop.fs.s3a.fast.upload", "true")
        self.spark.conf.set("spark.hadoop.fs.s3a.multipart.size", "104857600")
        logger.info("Spark configuration completed")

    def process_manifest(self, manifest_path: str):
        """Process a single manifest file."""
        logger.info(f"Processing manifest: {manifest_path}")

        try:
            bucket, key = self._parse_s3_path(manifest_path)
            response = s3_client.get_object(Bucket=bucket, Key=key)
            manifest = json.loads(response['Body'].read().decode('utf-8'))

            path_parts = key.split('/')
            date_prefix = path_parts[1] if len(path_parts) > 1 else datetime.utcnow().strftime('%Y-%m-%d')

            self._process_manifest_content(manifest, date_prefix)

        except Exception as e:
            logger.error(f"Error processing manifest {manifest_path}: {str(e)}")
            raise

    def _process_manifest_content(self, manifest: Dict, date_prefix: str):
        """Process manifest content and convert to Parquet."""
        try:
            file_paths = []
            for location in manifest.get('fileLocations', []):
                for uri in location.get('URIPrefixes', []):
                    file_paths.append(uri)

            if not file_paths:
                logger.warning(f"No files in manifest for {date_prefix}")
                return

            logger.info(f"Processing {len(file_paths)} files for {date_prefix}")

            df = self._read_and_merge_ndjson(file_paths)

            if df is None or df.isEmpty():
                logger.warning(f"No data read from files for {date_prefix}")
                return

            df = self._cast_all_to_string(df)
            output_path = self._generate_output_path(date_prefix)
            record_count = self._write_parquet(df, output_path)

            self.stats['records_processed'] += record_count
            self.stats['batches_processed'] += 1

            logger.info(f"Completed {date_prefix}: {record_count} records -> {output_path}")

        except Exception as e:
            logger.error(f"Error processing manifest for {date_prefix}: {str(e)}")
            self.stats['errors'] += 1
            raise

    def _read_and_merge_ndjson(self, file_paths: List[str]) -> Optional[DataFrame]:
        """Read multiple NDJSON files and merge."""
        try:
            logger.info(f"Reading {len(file_paths)} NDJSON files")
            df = self.spark.read.json(file_paths, multiLine=False)
            df = df.withColumn("_processing_timestamp", F.current_timestamp())
            df = df.withColumn("_source_file", F.input_file_name())
            record_count = df.count()
            logger.info(f"Successfully read {record_count} records")
            return df
        except Exception as e:
            logger.error(f"Failed to read NDJSON files: {str(e)}")
            raise

    def _cast_all_to_string(self, df: DataFrame) -> DataFrame:
        """Cast all DataFrame columns to string type."""
        logger.info("Casting all columns to string type")
        string_columns = [
            F.col(col_name).cast(StringType()).alias(col_name)
            for col_name in df.columns
        ]
        return df.select(string_columns)

    def _generate_output_path(self, date_prefix: str) -> str:
        """Generate output S3 path with partition structure."""
        partition_dir = f"merged-parquet-{date_prefix}"
        return f"s3://{self.output_bucket}/{partition_dir}/"

    def _write_parquet(self, df: DataFrame, output_path: str) -> int:
        """Write DataFrame to Parquet format."""
        try:
            df.cache()
            record_count = df.count()
            logger.info(f"Writing {record_count} records to {output_path}")

            estimated_size_mb = record_count / 1024
            num_partitions = max(int(estimated_size_mb / 128), 1)
            logger.info(f"Using {num_partitions} output partitions")

            df_coalesced = df.coalesce(num_partitions)
            df_coalesced.write.mode('append').parquet(
                output_path,
                compression=self.compression
            )
            df.unpersist()

            logger.info(f"Successfully wrote {record_count} records")
            return record_count
        except Exception as e:
            logger.error(f"Failed to write Parquet: {str(e)}")
            raise

    @staticmethod
    def _parse_s3_path(s3_path: str) -> tuple:
        """Parse S3 path into bucket and key."""
        path_parts = s3_path.replace('s3://', '').split('/', 1)
        return path_parts[0], path_parts[1]


def main():
    """Main entry point - BATCH MODE ONLY."""

    # Parse ALL required arguments (including MANIFEST_PATH)
    args = getResolvedOptions(
        sys.argv,
        [
            'JOB_NAME',
            'MANIFEST_BUCKET',
            'OUTPUT_BUCKET',
            'COMPRESSION_TYPE',
            'MANIFEST_PATH'  # NOW REQUIRED
        ]
    )

    manifest_path = args['MANIFEST_PATH']

    # Initialize Glue context
    sc = SparkContext()
    glue_context = GlueContext(sc)
    spark = glue_context.spark_session
    job = Job(glue_context)
    job.init(args['JOB_NAME'], args)

    logger.info(f"Starting job: {args['JOB_NAME']}")
    logger.info(f"Processing manifest: {manifest_path}")

    try:
        processor = ManifestProcessor(
            spark=spark,
            glue_context=glue_context,
            manifest_bucket=args['MANIFEST_BUCKET'],
            output_bucket=args['OUTPUT_BUCKET'],
            compression=args.get('COMPRESSION_TYPE', 'snappy')
        )

        processor.process_manifest(manifest_path)

        logger.info("Job completed successfully")
        logger.info(f"Final stats: {json.dumps(processor.stats)}")

        job.commit()

    except Exception as e:
        logger.error(f"Job failed: {str(e)}", exc_info=True)
        raise
    finally:
        sc.stop()


if __name__ == "__main__":
    main()
