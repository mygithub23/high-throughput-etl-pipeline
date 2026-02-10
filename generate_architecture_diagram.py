"""
Generate AWS Architecture Diagram for the NDJSON-to-Parquet ETL Pipeline.

Requires: pip install diagrams (and graphviz system package)
Usage:    python generate_architecture_diagram.py
Output:   aws_architecture_diagram.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.storage import S3
from diagrams.aws.integration import SQS, Eventbridge
from diagrams.aws.compute import Lambda
from diagrams.aws.database import DynamodbTable
from diagrams.aws.analytics import Glue
from diagrams.aws.integration import StepFunctions
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SNS

with Diagram(
    "NDJSON-to-Parquet ETL Pipeline",
    filename="/home/ali/Documents/_Dev/claude/high-throughput-etl-pipeline-RELEASE/aws_architecture_diagram",
    show=False,
    direction="TB",
    outformat="png",
    graph_attr={
        "fontsize": "28",
        "bgcolor": "white",
        "pad": "1.2",
        "nodesep": "1.0",
        "ranksep": "1.4",
        "dpi": "150",
    },
    node_attr={"fontsize": "12"},
    edge_attr={"fontsize": "10"},
):

    # ── Ingestion ────────────────────────────────────────────────────────

    with Cluster("Ingestion", graph_attr={"bgcolor": "#e8f5e9"}):
        s3_input = S3("S3 Input Bucket\nlanding/ndjson/\nYYYY-MM-DD/*.ndjson")
        sqs_main = SQS("SQS Queue\nndjson-parquet-file-events\nbatch=10, visibility=360s")
        sqs_dlq = SQS("Dead Letter Queue\nretention=14d")

        s3_input >> Edge(label="S3 Event Notification", color="darkgreen") >> sqs_main
        sqs_main >> Edge(label="max 3 retries", style="dashed", color="red") >> sqs_dlq

    # ── Lambda Processing ────────────────────────────────────────────────

    with Cluster("Lambda Processing", graph_attr={"bgcolor": "#fff3e0"}):
        lambda_manifest = Lambda("manifest_builder\nvalidate, track, batch,\nclaim files, create manifests")
        s3_quarantine = S3("S3 Quarantine\ninvalid files")
        s3_manifest = S3("S3 Manifest Bucket\nmanifests/YYYY-MM-DD/\nbatch-*.json")

        lambda_manifest >> Edge(label="invalid files", style="dashed", color="orange") >> s3_quarantine
        lambda_manifest >> Edge(label="write manifest JSON", color="darkgreen") >> s3_manifest

    # ── State Tracking ───────────────────────────────────────────────────

    with Cluster("State Tracking", graph_attr={"bgcolor": "#e3f2fd"}):
        dynamodb = DynamodbTable("DynamoDB: file-tracking\nPK=date_prefix  SK=file_key\nGSI: status-index (10 shards)\nStatus: pending#N -> manifested#N\n-> completed#N / failed#N\nTTL=30 days")

    # ── Orchestration ────────────────────────────────────────────────────

    with Cluster("Orchestration & Conversion", graph_attr={"bgcolor": "#f3e5f5"}):
        step_fn = StepFunctions("Step Functions\nndjson-parquet-processor\nStandard workflow (8 states)")
        glue_job = Glue("Glue Spark Job\nGlue 4.0 / PySpark\nNDJSON -> Parquet + Snappy\nG.1X (dev) / G.2X (prod)")
        lambda_batch = Lambda("batch_status_updater\nbatch update file records\npreserves shard suffix")

        step_fn >> Edge(label="startJobRun.sync\n(wait for completion)", color="darkgreen") >> glue_job
        step_fn >> Edge(label="invoke on\nsuccess/failure", color="purple") >> lambda_batch

    # ── Output ───────────────────────────────────────────────────────────

    with Cluster("Output", graph_attr={"bgcolor": "#e8f5e9"}):
        s3_output = S3("S3 Output Bucket\npipeline/output/\nmerged-parquet-YYYY-MM-DD/\n*.parquet (Snappy)")

    # ── Monitoring ───────────────────────────────────────────────────────

    with Cluster("Monitoring & Alerting", graph_attr={"bgcolor": "#fce4ec"}):
        cloudwatch = Cloudwatch("CloudWatch\nDashboard + 15 Alarms\nLambda, DynamoDB, Glue,\nStep Functions, SQS")
        sns_alerts = SNS("SNS Topic\nndjson-parquet-alerts\nemail notifications")

        cloudwatch >> Edge(label="alarm actions", color="crimson") >> sns_alerts

    # ── Phase 3 Optional ─────────────────────────────────────────────────

    with Cluster("Phase 3 - Optional (feature flags)", graph_attr={"style": "dashed", "bgcolor": "#fafafa", "fontcolor": "grey"}):
        eventbridge = Eventbridge("EventBridge Bus\nManifestReady event\n+ circuit breaker")
        lambda_stream = Lambda("stream_manifest_creator\nDynamoDB Streams trigger\nevent-driven manifests")

    # ── Cross-cluster connections ────────────────────────────────────────

    # SQS -> Lambda
    sqs_main >> Edge(label="trigger Lambda\n(batch of 10 msgs)", color="darkgreen") >> lambda_manifest

    # Lambda -> DynamoDB (track files)
    lambda_manifest >> Edge(label="PutItem\nstatus=pending#N", color="blue") >> dynamodb

    # Lambda -> Step Functions (start workflow)
    lambda_manifest >> Edge(label="start execution\n(manifest_path, date_prefix)", color="purple") >> step_fn

    # Step Functions -> DynamoDB (MANIFEST status)
    step_fn >> Edge(label="UpdateItem\nMANIFEST -> processing/completed/failed", color="blue") >> dynamodb

    # Glue reads manifest from S3
    glue_job >> Edge(label="read manifest\n+ NDJSON files", style="dashed", color="grey") >> s3_manifest

    # Glue writes Parquet
    glue_job >> Edge(label="write Parquet", color="darkgreen") >> s3_output

    # Batch updater -> DynamoDB
    lambda_batch >> Edge(label="files -> completed#N\nor failed#N", color="blue") >> dynamodb

    # Step Functions -> SNS on failure
    step_fn >> Edge(label="SNS publish\non failure", color="red") >> sns_alerts

    # Phase 3 connections
    lambda_manifest >> Edge(label="ManifestReady\nevent (Phase 3)", style="dashed", color="grey") >> eventbridge
    eventbridge >> Edge(label="trigger\nworkflow", style="dashed", color="grey") >> step_fn
    dynamodb >> Edge(label="DynamoDB\nStreams", style="dashed", color="grey") >> lambda_stream
