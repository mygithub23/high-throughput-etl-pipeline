import boto3
import csv
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
DRY_RUN = True

# Traffic profile
RAMP_UP_SECONDS = 300
STEADY_SECONDS = 600
RAMP_DOWN_SECONDS = 300

MIN_RATE = 10    # files/sec
MAX_RATE = 200   # files/sec

CSV_REPORT = "velocity_report.csv"

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
        time.sleep(0.002)
        return TARGET_MB * 1024 * 1024

    with tempfile.NamedTemporaryFile(delete=False, suffix=".ndjson") as tmp:
        local_path = tmp.name

    try:
        generate_ndjson_file(local_path)
        filename = (
            datetime.utcnow().strftime("%Y-%m-%d") +
            f"-loadtest-{int(time.time() * 1000)}.ndjson"
        )
        s3.upload_file(local_path, BUCKET, f"{PREFIX}{filename}")
        return os.path.getsize(local_path)
    finally:
        os.remove(local_path)

# ======================
# Rate Calculator
# ======================
def calculate_rate(phase, elapsed):
    if phase == "ramp_up":
        return MIN_RATE + (MAX_RATE - MIN_RATE) * (elapsed / RAMP_UP_SECONDS)
    if phase == "ramp_down":
        return MAX_RATE - (MAX_RATE - MIN_RATE) * (elapsed / RAMP_DOWN_SECONDS)
    return MAX_RATE

# ======================
# CSV Setup
# ======================
with open(CSV_REPORT, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow([
        "timestamp",
        "phase",
        "target_rate_fps",
        "actual_rate_fps",
        "files_sent",
        "mb_sent",
        "cumulative_files",
        "cumulative_mb"
    ])

# ======================
# Load Generator
# ======================
total_files = 0
total_bytes = 0
start_time = time.time()

def run_phase(phase, duration):
    global total_files, total_bytes
    phase_start = time.time()

    while time.time() - phase_start < duration:
        elapsed = time.time() - phase_start
        rate = calculate_rate(phase, elapsed)
        interval = 1 / max(rate, 1)

        files_sent = 0
        bytes_sent = 0
        window_start = time.time()

        while time.time() - window_start < 1:
            t0 = time.time()
            size = upload_file()
            files_sent += 1
            bytes_sent += size
            total_files += 1
            total_bytes += size
            time.sleep(max(0, interval - (time.time() - t0)))

        actual_rate = files_sent / (time.time() - window_start)
        mb_sent = bytes_sent / (1024 * 1024)

        with open(CSV_REPORT, "a", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                datetime.utcnow().isoformat(),
                phase,
                round(rate, 2),
                round(actual_rate, 2),
                files_sent,
                round(mb_sent, 2),
                total_files,
                round(total_bytes / (1024 * 1024), 2)
            ])

# ======================
# Execute Traffic Pattern
# ======================
print("Starting load simulation...")
run_phase("ramp_up", RAMP_UP_SECONDS)
run_phase("steady", STEADY_SECONDS)
run_phase("ramp_down", RAMP_DOWN_SECONDS)

elapsed = time.time() - start_time

print("\n=== Test Complete ===")
print(f"Mode: {'DRY RUN' if DRY_RUN else 'LIVE'}")
print(f"Elapsed: {elapsed:.1f}s")
print(f"Files sent: {total_files}")
print(f"GB sent: {total_bytes / (1024**3):.2f}")
print(f"CSV report: {CSV_REPORT}")
