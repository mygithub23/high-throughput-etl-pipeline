# AWS Management Console (Quick, High-Level)

## AWS CLI (Accurate, On-Demand)

### Total size of a bucket

```bash

aws s3 ls s3://my-bucket/my-prefix/ --recursive --summarize

```

### Breakdown by prefix (e.g., folders)

```bash
aws s3 ls s3://my-bucket/my-prefix/ --recursive --summarize

```

### All buckets

```bash
for b in $(aws s3api list-buckets --query "Buckets[].Name" --output text); do
  echo "Bucket: $b"
  aws s3 ls s3://$b --recursive --summarize \
    | grep "Total Size"
done


```

### All buckdets breakdown by prefix

```bash
aws s3 ls s3://bucket-name --recursive \
  | awk '{print $3}' \
  | awk -F/ '{print $1}' \
  | sort | uniq -c


```

### To automate per-top-level prefix

```bash
for p in $(aws s3 ls s3://my-bucket/ | awk '{print $2}'); do
  echo "Prefix: $p"
  aws s3 ls s3://my-bucket/$p --recursive --summarize
done

```

### S3 Inventory + Athena (Most Flexible & Detailed)

```sql
SELECT
  storage_class,
  SUM(size) / 1024 / 1024 / 1024 AS size_gb
FROM s3_inventory_table
GROUP BY storage_class;

```

### Per prefix

```sql
SELECT
  regexp_extract(key, '([^/]+)/', 1) AS prefix,
  SUM(size) AS total_bytes
FROM s3_inventory_table
GROUP BY prefix;

```
