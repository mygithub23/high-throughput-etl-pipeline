"""
NDJSON to Parquet Pipeline - Architecture Diagram
==================================================

Generates AWS architecture diagram using the 'diagrams' library.

Installation:
    pip install diagrams

Usage:
    python architecture_diagram.py

Output:
    ndjson_parquet_pipeline.png
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.storage import S3
from diagrams.aws.compute import Lambda
from diagrams.aws.integration import SQS, StepFunctions
from diagrams.aws.analytics import Glue
from diagrams.aws.database import Dynamodb
from diagrams.aws.management import Cloudwatch
from diagrams.aws.integration import SimpleNotificationServiceSns as SNS

# Diagram settings
graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "spline",
}

with Diagram(
    "NDJSON to Parquet Pipeline",
    show=False,
    filename="ndjson_parquet_pipeline",
    outformat="png",
    direction="LR",
    graph_attr=graph_attr
):

    # Data Sources
    with Cluster("1. Data Ingestion"):
        input_bucket = S3("Input Bucket\n(NDJSON files)")

    # Event Processing
    with Cluster("2. Event Processing"):
        sqs_queue = SQS("File Events\nQueue")
        dlq = SQS("Dead Letter\nQueue")

    # Lambda Processing
    with Cluster("3. Manifest Builder"):
        lambda_fn = Lambda("Manifest\nBuilder")
        dynamodb = Dynamodb("File Tracking\nTable")

    # Orchestration
    with Cluster("4. Orchestration"):
        step_fn = StepFunctions("Step Functions\nWorkflow")

    # Data Processing
    with Cluster("5. ETL Processing"):
        glue_job = Glue("Glue ETL\nJob")
        manifest_bucket = S3("Manifest\nBucket")

    # Output
    with Cluster("6. Output"):
        output_bucket = S3("Output Bucket\n(Parquet files)")

    # Monitoring
    with Cluster("7. Monitoring"):
        cloudwatch = Cloudwatch("CloudWatch\nLogs & Metrics")
        sns = SNS("Alert\nNotifications")

    # Data Flow Connections
    input_bucket >> Edge(label="S3 Event") >> sqs_queue
    sqs_queue >> Edge(label="Trigger") >> lambda_fn
    sqs_queue >> Edge(label="Failed", style="dashed", color="red") >> dlq

    lambda_fn >> Edge(label="Track Files") >> dynamodb
    lambda_fn >> Edge(label="Create Manifest") >> manifest_bucket
    lambda_fn >> Edge(label="Start Workflow") >> step_fn

    step_fn >> Edge(label="Update Status") >> dynamodb
    step_fn >> Edge(label="Start Job") >> glue_job
    step_fn >> Edge(label="On Failure", style="dashed", color="red") >> sns

    glue_job >> Edge(label="Read Manifest") >> manifest_bucket
    glue_job >> Edge(label="Read NDJSON") >> input_bucket
    glue_job >> Edge(label="Write Parquet") >> output_bucket

    # Monitoring connections
    lambda_fn >> Edge(style="dotted", color="gray") >> cloudwatch
    glue_job >> Edge(style="dotted", color="gray") >> cloudwatch
    step_fn >> Edge(style="dotted", color="gray") >> cloudwatch


print("Diagram generated: ndjson_parquet_pipeline.png")
