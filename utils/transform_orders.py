"""
Glue ETL job: cleans and standardizes raw e-commerce order data.

Handles:
  - Deduplication (retried uploads created duplicate order_id records)
  - Date standardization (stores send dates in inconsistent formats)
  - Currency normalization (lowercase, trailing symbols, blanks/nulls)
  - Flagging records with missing critical fields, rather than silently dropping them
"""

import sys
from awsglue.transforms import *
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

# --- Read from the Glue Catalog (raw zone) ---
dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database=args["source_database"],
    table_name=args["source_table"],
)
df = dynamic_frame.toDF()

# --- 1. Deduplicate on order_id ---
# Retried uploads mean the same order can appear more than once identically.
before_count = df.count()
df = df.dropDuplicates(["order_id"])
after_count = df.count()
print(
    f"Deduplication: {before_count} -> {after_count} rows ({before_count - after_count} duplicates removed)")

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
    parsed_date = F.coalesce(
        parsed_date, F.to_timestamp(F.col("order_date"), fmt))

df = df.withColumn("order_date_parsed", parsed_date)
df = df.withColumn("date_parse_failed", F.col("order_date_parsed").isNull())

# --- 3. Normalize currency codes ---
# Handles lowercase ("usd"), trailing symbols ("USD$"), and blank/null values.
df = df.withColumn(
    "currency_clean",
    F.when(F.col("currency").isNull() | (
        F.trim(F.col("currency")) == ""), None)
     .otherwise(F.upper(F.regexp_replace(F.col("currency"), r"[^A-Za-z]", "")))
)
df = df.withColumn("currency_invalid", F.col("currency_clean").isNull())

# --- 4. Handle null unit_price ---
# Don't silently drop these - flag them so downstream consumers (and your
# data quality dashboard, once you build one) can decide what to do.
df = df.withColumn("unit_price", F.col("unit_price").cast(DoubleType()))
df = df.withColumn("price_missing", F.col("unit_price").isNull())

# --- 5. Compute a derived field useful for analytics: line total ---
df = df.withColumn(
    "line_total",
    F.when(F.col("unit_price").isNotNull(), F.col(
        "unit_price") * F.col("quantity")).otherwise(None)
)

# --- 6. Re-derive partition columns for the processed zone ---
df = df.withColumn("year", F.year("order_date_parsed")) \
       .withColumn("month", F.month("order_date_parsed"))

# --- Write out as Parquet, partitioned for efficient downstream querying ---
df.write.mode("overwrite") \
    .partitionBy("region", "year", "month") \
    .parquet(args["target_path"])

job.commit()
