#!/usr/bin/env python3
import json
import os
import random
import string
import argparse
from datetime import datetime, timezone
from pathlib import Path


def random_string(n=12):
    return "".join(random.choices(string.ascii_letters + string.digits, k=n))


def random_payload(size_in_bytes=3500000):
    """Generate a random payload of approx N bytes."""
    return random_string(max(1, size_in_bytes - 50))


def generate_record():
    """Define NDJSON record schema."""
    return {
        "id": random_string(16),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "category": random.choice(["alpha", "beta", "gamma", "delta"]),
        "value": random.randint(1, 999999),
        "payload": random_payload(500),
    }


def generate_file(output_dir, file_index, num_records, approx_mb, date_prefix):
    output_dir = Path(r"C:\Users\moula\Documents\generate-ndjson\test")
    # Normalize Windows/Linux paths
    output_dir = os.path.abspath(os.path.expanduser(output_dir))
    print(f"Output directory: {output_dir}")

    # Create directory safely
    os.makedirs(output_dir, exist_ok=True)

    # ALWAYS prefix filename with yyyy-mm-dd-
    # C:\Users\moula\OneDrive\Documents\_Dev\S3-SQS-Lambda\generate-ndjson-files.py
    # generate-ndjson-files.py

    filename = f"{date_prefix}-file{file_index}.ndjson"
    path = os.path.join(output_dir, filename)

    target_bytes = approx_mb * 1024 * 1024
    current_bytes = 0
    records_written = 0

    with open(path, "w", encoding="utf-8") as f:
        while records_written < num_records and current_bytes < target_bytes:
            record = generate_record()
            line = json.dumps(record) + "\n"
            f.write(line)
            current_bytes += len(line)
            records_written += 1

    return path, current_bytes, records_written


def main():
    parser = argparse.ArgumentParser(
        description="Generate NDJSON test files with date prefix."
    )
    parser.add_argument("--files", type=int, default=10, help="Number of NDJSON files")
    parser.add_argument(
        "--records", type=int, default=1000, help="Number of records per file"
    )
    parser.add_argument(
        "--size_mb", type=int, default=10, help="Approx NDJSON file size in MB"
    )
    parser.add_argument(
        "--output", type=str, default="./ndjson_test", help="Output directory"
    )
    parser.add_argument(
        "--date_prefix",
        type=str,
        default=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        help="Date prefix in yyyy-mm-dd (default: today's date)",
    )
    parser.add_argument("--seed", type=int, default=42)

    args = parser.parse_args()
    random.seed(args.seed)

    print(f"Generating NDJSON files with prefix: {args.date_prefix}-\n")

    for i in range(1, args.files + 1):
        path, size_bytes, count = generate_file(
            args.output, i, args.records, args.size_mb, args.date_prefix
        )
        print(f"✔ {path} | {size_bytes/1024/1024:.2f} MB | {count} records")

    print("\nDone.")


if __name__ == "__main__":
    main()
