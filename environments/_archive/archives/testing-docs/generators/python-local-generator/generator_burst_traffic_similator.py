import boto3
import json
import os
import time
import random
import tempfile
from datetime import datetime, timezone

# ======================
# Configuration
# ======================
BUCKET = "ndjson-input-sqs-<ACCOUNT>"
PREFIX = "input/"
TARGET_MB = 3.5
ROWS = 5000

# Burst pattern: (files_per_second, duration_seconds)
# RATES = [
#     (50, 600),   # steady
#     (150, 300),  # burst
#     (30, 600)    # cooldown
# ]
RATES = [
    (11, 21),   # steady

]
s3 = boto3.client("s3")

# ======================
# NDJSON Generator
# ======================
def generate_ndjson_file(path):
    with open(path, "w") as f:
        for i in range(ROWS):
            record = {
                "id": i,
                "ts": datetime.now(timezone.utc).isoformat(),
                "value": random.random(),
                "payload": "X" * 500
            }
            f.write(json.dumps(record) + "\n")

    # Pad file to target size
    current_mb = os.path.getsize(path) / (1024 * 1024)
    if current_mb < TARGET_MB:
        with open(path, "a") as f:
            padding = int((TARGET_MB - current_mb) * 1024 * 1024)
            f.write(" " * padding)

# ======================
# Upload Function (FIXED)
# ======================
def upload_file():
    with tempfile.NamedTemporaryFile(delete=False, suffix=".ndjson") as tmp:
        local_path = tmp.name

    try:
        generate_ndjson_file(local_path)

        filename = (
            datetime.now(timezone.utc).strftime("%Y-%m-%d") +
            f"-loadtest-{int(time.time() * 1000)}.ndjson"
        )

        s3.upload_file(
            local_path,
            BUCKET,
            f"{PREFIX}{filename}"
        )

    finally:
        os.remove(local_path)

# ======================
# Load Generator
# ======================
for rate, duration in RATES:
    
    interval = 1 / rate
    total_files = rate * duration

    print(f"\n=== Sending {total_files} files at {rate} files/sec ===")

    for _ in range(total_files):
        start = time.time()
        upload_file()
        elapsed = time.time() - start
        sleep_time = max(0, interval - elapsed)
        time.sleep(sleep_time)

'''
Why this is now correct
    ✅ upload_file() is explicitly defined
    Generates NDJSON
    Uploads to S3
    Cleans up temp files
    ✅ Rate control is accurate
    Compensates for upload time
    Maintains target files/sec
    ✅ Production-faithful behavior
    Real S3 PUT pressure
    Real SQS events
    Real Glue Streaming load
    
How to use this safely
    Dev environment only
    Use a dedicated dev bucket
    Shorten durations for quick tests
    Start with 10–20 files/sec
    Validate results with
    SQS ApproximateAgeOfOldestMessage
    Glue batch duration
    Parquet output size (~1 GB)
'''