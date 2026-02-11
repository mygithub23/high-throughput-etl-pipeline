"""
Generate AWS Architecture Diagram for the NDJSON-to-Parquet ETL Pipeline.

This module creates a comprehensive visual representation of an AWS-based ETL pipeline
for converting NDJSON files to Parquet format, including monitoring and phase 3 features.

Requirements:
    - diagrams: pip install diagrams
    - graphviz: system package (brew install graphviz on macOS, apt-get install graphviz on Linux)

Usage:
    python generate_architecture_diagram.py
    # Output: aws_architecture_diagram.png in the current directory

Example:
    $ python generate_architecture_diagram.py
    $ open aws_architecture_diagram.png  # View the generated diagram
"""

from pathlib import Path
from typing import Dict, Any

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.storage import S3
from diagrams.aws.integration import SQS, Eventbridge, StepFunctions, SNS
from diagrams.aws.compute import Lambda
from diagrams.aws.database import DynamodbTable
from diagrams.aws.analytics import Glue
from diagrams.aws.management import Cloudwatch


# ─── Configuration ──────────────────────────────────────────────────────

class DiagramConfig:
    """Configuration for diagram styling and layout."""

    # Output settings
    OUTPUT_FILENAME = "aws_architecture_diagram"
    OUTPUT_FORMAT = "png"
    SHOW_DIAGRAM = False

    # Layout settings
    DIRECTION = "TB"
    DPI = 120

    # Graph styling
    GRAPH_ATTRIBUTES = {
        "fontsize": "52",
        "bgcolor": "white",
        "pad": "2.5",
        "nodesep": "2.8",
        "ranksep": "3.2",
        "dpi": str(DPI),
    }

    NODE_ATTRIBUTES = {"fontsize": "28", "width": "2.5", "height": "2.0"}
    EDGE_ATTRIBUTES = {"fontsize": "22", "minlen": "2"}

    # Cluster colors
    CLUSTER_COLORS = {
        "ingestion": "#e8f5e9",
        "processing": "#fff3e0",
        "state_tracking": "#e3f2fd",
        "orchestration": "#f3e5f5",
        "output": "#e8f5e9",
        "monitoring": "#fce4ec",
        "phase3": "#fafafa",
    }

    # Edge colors
    EDGE_COLORS = {
        "success": "darkgreen",
        "error": "red",
        "warning": "orange",
        "info": "blue",
        "processing": "purple",
        "disabled": "grey",
    }


def create_architecture_diagram(output_dir: str = ".") -> None:
    """
    Create and save the NDJSON-to-Parquet ETL architecture diagram.

    Args:
        output_dir: Directory where the diagram will be saved (default: current directory)

    Raises:
        FileNotFoundError: If output directory does not exist
        NotADirectoryError: If output path is not a directory
        PermissionError: If output directory is not writable
    """
    output_path = Path(output_dir) / DiagramConfig.OUTPUT_FILENAME

    # Validate output directory
    if not Path(output_dir).exists():
        raise FileNotFoundError(f"Output directory does not exist: {output_dir}")
    if not Path(output_dir).is_dir():
        raise NotADirectoryError(f"Output path is not a directory: {output_dir}")

    with Diagram(
        "NDJSON-to-Parquet ETL Pipeline",
        filename=str(output_path),
        show=DiagramConfig.SHOW_DIAGRAM,
        direction=DiagramConfig.DIRECTION,
        outformat=DiagramConfig.OUTPUT_FORMAT,
        graph_attr=DiagramConfig.GRAPH_ATTRIBUTES,
        node_attr=DiagramConfig.NODE_ATTRIBUTES,
        edge_attr=DiagramConfig.EDGE_ATTRIBUTES,
    ):
        # ── Ingestion ────────────────────────────────────────────────────────
        with Cluster("Ingestion", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["ingestion"], "fontsize": "34", "labeljust": "l"}):
            s3_input = S3("S3 Input Bucket\nlanding/ndjson/\nYYYY-MM-DD/*.ndjson")
            sqs_main = SQS("SQS Queue\nndjson-parquet-file-events\nbatch=10, visibility=360s")
            sqs_dlq = SQS("Dead Letter Queue\nretention=14d")

            s3_input >> Edge(label="S3 Event Notification", color=DiagramConfig.EDGE_COLORS["success"]) >> sqs_main
            sqs_main >> Edge(label="max 3 retries", style="dashed", color=DiagramConfig.EDGE_COLORS["error"]) >> sqs_dlq

        # ── Lambda Processing ────────────────────────────────────────────────
        with Cluster("Lambda Processing", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["processing"], "fontsize": "34", "labeljust": "l"}):
            lambda_manifest = Lambda("manifest_builder\nvalidate, track, batch,\nclaim files, create manifests")
            s3_quarantine = S3("S3 Quarantine\ninvalid files")
            s3_manifest = S3("S3 Manifest Bucket\nmanifests/YYYY-MM-DD/\nbatch-*.json")

            lambda_manifest >> Edge(label="invalid files", style="dashed", color=DiagramConfig.EDGE_COLORS["warning"]) >> s3_quarantine
            lambda_manifest >> Edge(label="write manifest JSON", color=DiagramConfig.EDGE_COLORS["success"]) >> s3_manifest

        # ── State Tracking ───────────────────────────────────────────────────
        with Cluster("State Tracking", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["state_tracking"], "fontsize": "34", "labeljust": "l"}):
            dynamodb = DynamodbTable(
                "DynamoDB: file-tracking\n"
                "PK=date_prefix  SK=file_key\n"
                "GSI: status-index (10 shards)\n"
                "Status: pending#N -> manifested#N\n"
                "-> completed#N / failed#N\n"
                "TTL=30 days"
            )

        # ── Orchestration & Conversion ───────────────────────────────────────
        with Cluster("Orchestration & Conversion", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["orchestration"], "fontsize": "34", "labeljust": "l"}):
            step_fn = StepFunctions("Step Functions\nndjson-parquet-processor\nStandard workflow (8 states)")
            glue_job = Glue(
                "Glue Spark Job\n"
                "Glue 4.0 / PySpark\n"
                "NDJSON -> Parquet + Snappy\n"
                "G.1X (dev) / G.2X (prod)"
            )
            lambda_batch = Lambda("batch_status_updater\nbatch update file records\npreserves shard suffix")

            step_fn >> Edge(label="startJobRun.sync\n(wait for completion)", color=DiagramConfig.EDGE_COLORS["success"]) >> glue_job
            step_fn >> Edge(label="invoke on\nsuccess/failure", color=DiagramConfig.EDGE_COLORS["processing"]) >> lambda_batch

        # ── Output ───────────────────────────────────────────────────────────
        with Cluster("Output", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["output"], "fontsize": "34", "labeljust": "l"}):
            s3_output = S3(
                "S3 Output Bucket\n"
                "pipeline/output/\n"
                "merged-parquet-YYYY-MM-DD/\n"
                "*.parquet (Snappy)"
            )

        # ── Monitoring & Alerting ────────────────────────────────────────────
        with Cluster("Monitoring & Alerting", graph_attr={"bgcolor": DiagramConfig.CLUSTER_COLORS["monitoring"], "fontsize": "34", "labeljust": "l"}):
            cloudwatch = Cloudwatch(
                "CloudWatch\n"
                "Dashboard + 15 Alarms\n"
                "Lambda, DynamoDB, Glue,\n"
                "Step Functions, SQS"
            )
            sns_alerts = SNS("SNS Topic\nndjson-parquet-alerts\nemail notifications")

            cloudwatch >> Edge(label="alarm actions", color="crimson") >> sns_alerts

        # ── Phase 3 - Optional (feature flags) ───────────────────────────────
        with Cluster(
            "Phase 3 - Optional (feature flags)",
            graph_attr={
                "style": "dashed",
                "bgcolor": DiagramConfig.CLUSTER_COLORS["phase3"],
                "fontcolor": DiagramConfig.EDGE_COLORS["disabled"],
                "fontsize": "40",
                "labeljust": "l",
            },
        ):
            eventbridge = Eventbridge("EventBridge Bus\nManifestReady event\n+ circuit breaker")
            lambda_stream = Lambda("stream_manifest_creator\nDynamoDB Streams trigger\nevent-driven manifests")

        # ── Cross-cluster Connections ────────────────────────────────────────
        # SQS -> Lambda
        sqs_main >> Edge(label="trigger Lambda\n(batch of 10 msgs)", color=DiagramConfig.EDGE_COLORS["success"]) >> lambda_manifest

        # Lambda -> DynamoDB (track files)
        lambda_manifest >> Edge(label="PutItem\nstatus=pending#N", color=DiagramConfig.EDGE_COLORS["info"]) >> dynamodb

        # Lambda -> Step Functions (start workflow)
        lambda_manifest >> Edge(label="start execution\n(manifest_path, date_prefix)", color=DiagramConfig.EDGE_COLORS["processing"]) >> step_fn

        # Step Functions -> DynamoDB (MANIFEST status)
        step_fn >> Edge(label="UpdateItem\nMANIFEST -> processing/completed/failed", color=DiagramConfig.EDGE_COLORS["info"]) >> dynamodb

        # Glue reads manifest from S3
        glue_job >> Edge(label="read manifest\n+ NDJSON files", style="dashed", color=DiagramConfig.EDGE_COLORS["disabled"]) >> s3_manifest

        # Glue writes Parquet
        glue_job >> Edge(label="write Parquet", color=DiagramConfig.EDGE_COLORS["success"]) >> s3_output

        # Batch updater -> DynamoDB
        lambda_batch >> Edge(label="files -> completed#N\nor failed#N", color=DiagramConfig.EDGE_COLORS["info"]) >> dynamodb

        # Step Functions -> SNS on failure
        step_fn >> Edge(label="SNS publish\non failure", color=DiagramConfig.EDGE_COLORS["error"]) >> sns_alerts

        # Phase 3 connections
        lambda_manifest >> Edge(label="ManifestReady\nevent (Phase 3)", style="dashed", color=DiagramConfig.EDGE_COLORS["disabled"]) >> eventbridge
        eventbridge >> Edge(label="trigger\nworkflow", style="dashed", color=DiagramConfig.EDGE_COLORS["disabled"]) >> step_fn
        dynamodb >> Edge(label="DynamoDB\nStreams", style="dashed", color=DiagramConfig.EDGE_COLORS["disabled"]) >> lambda_stream


if __name__ == "__main__":
    import sys
    import os

    try:
        # Determine output directory
        output_dir = os.getcwd()

        if len(sys.argv) > 1:
            output_dir = sys.argv[1]
            if not Path(output_dir).exists():
                print(f"Error: Output directory does not exist: {output_dir}")
                sys.exit(1)

        print(f"Generating architecture diagram...")
        print(f"Output directory: {output_dir}")

        create_architecture_diagram(output_dir)

        output_file = Path(output_dir) / f"{DiagramConfig.OUTPUT_FILENAME}.{DiagramConfig.OUTPUT_FORMAT}"
        print(f"✓ Diagram successfully created: {output_file}")

    except ImportError as e:
        print(f"Error: Missing required package - {e}")
        print("Install dependencies with: pip install diagrams")
        sys.exit(1)
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except PermissionError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error generating diagram: {e}")
        sys.exit(1)
