import boto3
import json
import os
import time
import random
import tempfile
from datetime import datetime

# ======================
# Configuration
# ======================
BUCKET = "your-bucket-name"
PREFIX = "input/"
TARGET_MB = 3.5
ROWS = 5000
DRY_RUN = True   # <<< ENABLE / DISABLE HERE

# Burst pattern: (files_per_second, duration_seconds)
RATES = [
    (50, 600),
    (150, 300),
    (30, 600)
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
                "ts": datetime.utcnow().isoformat(),
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
# Upload Function
# ======================
def upload_file():
    if DRY_RUN:
        # Simulate work without touching disk or S3
        time.sleep(0.002)  # approximate JSON + IO overhead
        return 0

    with tempfile.NamedTemporaryFile(delete=False, suffix=".ndjson") as tmp:
        local_path = tmp.name

    try:
        generate_ndjson_file(local_path)

        filename = (
            datetime.utcnow().strftime("%Y-%m-%d") +
            f"-loadtest-{int(time.time() * 1000)}.ndjson"
        )

        s3.upload_file(
            local_path,
            BUCKET,
            f"{PREFIX}{filename}"
        )

        return os.path.getsize(local_path)

    finally:
        os.remove(local_path)

# ======================
# Load Generator
# ======================
total_files_sent = 0
total_bytes_sent = 0
start_time = time.time()

for rate, duration in RATES:
    interval = 1 / rate
    total_files = rate * duration

    print(f"\n=== {'DRY RUN' if DRY_RUN else 'LIVE'}: "
          f"{total_files} files @ {rate} files/sec ===")

    for _ in range(total_files):
        print("range(total_files)")
        t0 = time.time()
        bytes_sent = upload_file()
        total_files_sent += 1
        print(f"total_files_sent: {total_files_sent}")
        total_bytes_sent += bytes_sent
        print(f"total_bytes_sent: {total_bytes_sent}")

        elapsed = time.time() - t0
        time.sleep(max(0, interval - elapsed))

# ======================
# Summary
# ======================
elapsed_total = time.time() - start_time
files_per_sec = total_files_sent / elapsed_total
mb_per_sec = (total_bytes_sent / (1024 * 1024)) / elapsed_total

print("\n=== Load Test Summary ===")
print(f"Mode: {'DRY RUN' if DRY_RUN else 'LIVE'}")
print(f"Elapsed time: {elapsed_total:.2f} sec")
print(f"Files sent: {total_files_sent}")
print(f"Files/sec: {files_per_sec:.2f}")
print(f"Files/min: {files_per_sec * 60:.0f}")
print(f"Files/hour: {files_per_sec * 3600:.0f}")
print(f"MB/sec: {mb_per_sec:.2f}")
print(f"GB/hour: {mb_per_sec * 3600 / 1024:.2f}")



'''
How to use this safely
Dry-run (default)
DRY_RUN = True


Validates velocity math

No AWS calls

No cost

Live test
DRY_RUN = False


Real S3 PUTs

Real SQS events

Real Glue pressure

On-call best practice

Always run dry-run first

Verify files/sec math

Then enable live mode for short windows (5–10 minutes)

Optional enhancements (next steps)

If you want, I can:

Add multi-threaded dry-run

Add CSV output for reports

Add CloudWatch custom metrics

Add automatic ramp-up/ramp-down

Integrate this directly into the on-call runbook
'''