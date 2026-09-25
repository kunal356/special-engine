"""
Glue ETL job: cleans and standardizes raw e-commerce order data.

Handles:
  - Deduplication (retried uploads created duplicate order_id records)
  - Date standardization (stores send dates in inconsistent formats)
  - Currency normalization (lowercase, trailing symbols, blanks/nulls)
  - Flagging records with missing critical fields, rather than silently dropping them
"""

import sys
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType

args = getResolvedOptions(sys.argv, [
    "JOB_NAME", "source_database", "source_table", "target_path"
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# Dynamic (not static) partition overwrite: mode("overwrite") only replaces
# the specific partitions present in this run's output, rather than wiping
# the entire target path first. Without this, a run that produces zero rows
# (e.g. no new raw files since the last crawl) would silently delete every
# previously processed partition while still reporting job success.
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

# --- Read from the Glue Catalog (raw zone) ---
# transformation_ctx is required for --job-bookmark-option to actually do
# anything - without it, bookmarks are enabled as a job parameter but have
# nothing to track against, and every run reprocesses the full raw history.
dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args["source_database"],
    table_name=args["source_table"],
    transformation_ctx="raw_orders_source",
)
df = dynamic_frame.toDF()

# Fail loudly and specifically if there's nothing to process, rather than
# silently writing (or overwriting) an empty result. An empty source is
# usually a real problem upstream - the raw crawler found nothing, or the
# raw table doesn't exist yet - and deserves an actionable error, not a
# quiet no-op that looks identical to a successful run in the logs.
if df.rdd.isEmpty():
    raise SystemExit(
        "RAW_DATA_EMPTY: no records found in "
        f"{args['source_database']}.{args['source_table']}. Check that raw "
        "files have been uploaded and the raw crawler completed successfully "
        "before this job runs."
    )

# --- 1. Deduplicate on order_id ---
# Retried uploads mean the same order can appear more than once identically.
before_count = df.count()
df = df.dropDuplicates(["order_id"])
after_count = df.count()
print(f"Deduplication: {before_count} -> {after_count} rows ({before_count - after_count} duplicates removed)")

# --- 2. Standardize order_date across multiple inconsistent formats ---
# Stores send dates as "2026-09-22T09:51:44", "2026-09-22 09:51:44",
# "22/09/2026 09:51", or just "09-22-2026". Try each known format in turn.
date_formats = [
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
    "dd/MM/yyyy HH:mm",
    "MM-dd-yyyy",
]

parsed_date = F.lit(None).cast("timestamp")
for fmt in date_formats:
    parsed_date = F.coalesce(parsed_date, F.to_timestamp(F.col("order_date"), fmt))

df = df.withColumn("order_date_parsed", parsed_date)
df = df.withColumn("date_parse_failed", F.col("order_date_parsed").isNull())

# --- 3. Normalize currency codes ---
# Handles lowercase ("usd"), trailing symbols ("USD$"), and blank/null values.
df = df.withColumn(
    "currency_clean",
    F.when(F.col("currency").isNull() | (F.trim(F.col("currency")) == ""), None)
     .otherwise(F.upper(F.regexp_replace(F.col("currency"), r"[^A-Za-z]", "")))
)
df = df.withColumn("currency_invalid", F.col("currency_clean").isNull())

# --- 4. Handle null unit_price ---
# Don't silently drop these - flag them so downstream consumers (and the
# data quality check that runs after this job) can decide what to do.
df = df.withColumn("unit_price", F.col("unit_price").cast(DoubleType()))
df = df.withColumn("price_missing", F.col("unit_price").isNull())

# --- 5. Compute a derived field useful for analytics: line total ---
df = df.withColumn(
    "line_total",
    F.when(F.col("unit_price").isNotNull(), F.col("unit_price") * F.col("quantity")).otherwise(None)
)

# --- 6. Re-derive partition columns for the processed zone ---
df = df.withColumn("year", F.year("order_date_parsed")) \
       .withColumn("month", F.month("order_date_parsed"))

# --- Write out as Parquet, partitioned for efficient downstream querying ---
df.write.mode("overwrite") \
    .partitionBy("region", "year", "month") \
    .parquet(args["target_path"])

job.commit()
