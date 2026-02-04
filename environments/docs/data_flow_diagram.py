"""
NDJSON to Parquet Pipeline - Data Flow Diagram
===============================================

Shows the detailed data flow through the pipeline.

Installation:
    pip install diagrams

Usage:
    python data_flow_diagram.py

Output:
    data_flow_diagram.png
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.storage import S3
from diagrams.aws.compute import Lambda
from diagrams.aws.integration import SQS, StepFunctions
from diagrams.aws.analytics import Glue
from diagrams.aws.database import Dynamodb
from diagrams.custom import Custom

graph_attr = {
    "fontsize": "16",
    "bgcolor": "white",
    "pad": "0.5",
}

with Diagram(
    "Data Flow: NDJSON to Parquet Conversion",
    show=False,
    filename="data_flow_diagram",
    outformat="png",
    direction="TB",
    graph_attr=graph_attr
):

    with Cluster("Phase 1: File Arrival"):
        ndjson_files = S3("NDJSON Files\n(~100KB each)")

    with Cluster("Phase 2: Event Queue"):
        sqs = SQS("SQS Queue\n(batches of 10)")

    with Cluster("Phase 3: File Tracking & Batching"):
        lambda_fn = Lambda("Lambda\nManifest Builder")
        dynamodb = Dynamodb("DynamoDB\n(file_key, status)")

    with Cluster("Phase 4: Manifest Creation"):
        manifest = S3("Manifest JSON\n(10 file URIs)")

    with Cluster("Phase 5: Workflow Orchestration"):
        step_fn = StepFunctions("Step Functions")

    with Cluster("Phase 6: ETL Processing"):
        glue = Glue("Glue Job\n(Spark)")

    with Cluster("Phase 7: Output"):
        parquet = S3("Parquet Files\n(Snappy compressed)")

    # Flow
    ndjson_files >> Edge(label="1. S3 ObjectCreated event") >> sqs
    sqs >> Edge(label="2. Trigger (batch of 10 messages)") >> lambda_fn
    lambda_fn >> Edge(label="3. Track each file") >> dynamodb
    lambda_fn >> Edge(label="4. When 10 files pending") >> manifest
    lambda_fn >> Edge(label="5. Start execution") >> step_fn
    step_fn >> Edge(label="6. Update status='processing'") >> dynamodb
    step_fn >> Edge(label="7. StartJobRun.sync") >> glue
    glue >> Edge(label="8. Read file list") >> manifest
    glue >> Edge(label="9. Read NDJSON data") >> ndjson_files
    glue >> Edge(label="10. Write converted data") >> parquet
    step_fn >> Edge(label="11. Update status='completed'", style="dashed") >> dynamodb


print("Data flow diagram generated: data_flow_diagram.png")
