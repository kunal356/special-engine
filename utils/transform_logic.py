"""
Pure transformation logic for the order-cleaning ETL job.

Deliberately has zero AWS/Glue imports so it can be unit tested with plain
pytest + a local PySpark session, with no Glue runtime required. All
Glue-specific orchestration (reading from the catalog, writing to S3,
job bookmarking) lives in transform_orders.py, which imports transform()
from here.
"""

from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType

DATE_FORMATS = [
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
    "dd/MM/yyyy HH:mm",
    "MM-dd-yyyy",
]


def validate_not_empty(df: DataFrame, database: str, table: str) -> None:
    """Raise loudly if the source table produced zero rows.

    An empty source is usually a real upstream problem (raw crawler found
    nothing, or the table doesn't exist yet) and deserves an actionable
    error, not a quiet no-op that looks identical to success in the logs.
    """
    if df.rdd.isEmpty():
        raise SystemExit(
            f"RAW_DATA_EMPTY: no records found in {database}.{table}. Check "
            "that raw files have been uploaded and the raw crawler completed "
            "successfully before this job runs."
        )


def deduplicate_orders(df: DataFrame) -> DataFrame:
    """Drop duplicate order_id rows created by retried uploads."""
    before_count = df.count()
    df = df.dropDuplicates(["order_id"])
    after_count = df.count()
    print(
        f"Deduplication: {before_count} -> {after_count} rows ({before_count - after_count} duplicates removed)")
    return df


def parse_order_dates(df: DataFrame, date_formats=None) -> DataFrame:
    """Try each known date format in turn, flagging rows that match none.

    Source stores send dates as "2026-09-22T09:51:44", "2026-09-22 09:51:44",
    "22/09/2026 09:51", or just "09-22-2026".
    """
    formats = date_formats if date_formats is not None else DATE_FORMATS
    parsed_date = F.lit(None).cast("timestamp")
    for fmt in formats:
        parsed_date = F.coalesce(
            parsed_date, F.to_timestamp(F.col("order_date"), fmt))
    df = df.withColumn("order_date_parsed", parsed_date)
    df = df.withColumn("date_parse_failed", F.col(
        "order_date_parsed").isNull())
    return df


def normalize_currency(df: DataFrame) -> DataFrame:
    """Normalize currency codes: uppercase, strip non-letters, flag invalid/blank."""
    df = df.withColumn(
        "currency_clean",
        F.when(F.col("currency").isNull() | (
            F.trim(F.col("currency")) == ""), None)
         .otherwise(F.upper(F.regexp_replace(F.col("currency"), r"[^A-Za-z]", "")))
    )
    df = df.withColumn("currency_invalid", F.col("currency_clean").isNull())
    return df


def handle_missing_price(df: DataFrame) -> DataFrame:
    """Cast unit_price to double; flag rows with a missing/uncastable price
    rather than silently dropping them."""
    df = df.withColumn("unit_price", F.col("unit_price").cast(DoubleType()))
    df = df.withColumn("price_missing", F.col("unit_price").isNull())
    return df


def compute_line_total(df: DataFrame) -> DataFrame:
    """Derive line_total = unit_price * quantity, left null when price is missing."""
    return df.withColumn(
        "line_total",
        F.when(F.col("unit_price").isNotNull(), F.col(
            "unit_price") * F.col("quantity")).otherwise(None)
    )


def derive_partition_columns(df: DataFrame) -> DataFrame:
    """Derive year/month partition columns from the parsed order date."""
    return df.withColumn("year", F.year("order_date_parsed")) \
             .withColumn("month", F.month("order_date_parsed"))


def transform(df: DataFrame) -> DataFrame:
    """Run the full cleaning pipeline, in order, on a raw orders DataFrame."""
    df = deduplicate_orders(df)
    df = parse_order_dates(df)
    df = normalize_currency(df)
    df = handle_missing_price(df)
    df = compute_line_total(df)
    df = derive_partition_columns(df)
    return df
