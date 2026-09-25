"""
Glue Python Shell job: validates the cleaned/processed order data with
Great Expectations before it's considered ready for the processed crawler.

Runs as a Python Shell job (not a Spark ETL job) deliberately - this step
doesn't need distributed compute, and Python Shell jobs start in seconds
rather than the minute-plus cold start of a Spark job, which matters for
a validation gate that runs on every pipeline execution.

Severity model:
  - "critical" expectations (e.g. order_id present & unique, at least one
    row exists) - a failure here fails the Glue job, which the Step
    Functions Catch block routes to the pipeline's existing NotifyFailure
    state. The processed crawler never runs on bad data.
  - "warning" expectations (e.g. currency/date parse failure rate) - a
    failure here is written to the report and optionally raises a
    separate, non-fatal SNS notice, but does not fail the job. Some
    messiness is expected in real data and shouldn't halt the pipeline.

A JSON report is always written to S3, pass or fail, for later review or
trending, since a single boolean isn't enough to see whether data quality
is improving or degrading over time.
"""

import sys
import json
import re
from datetime import datetime, timezone

import boto3
import pandas as pd
import great_expectations as gx
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, [
    "target_path", "report_bucket", "report_prefix", "sns_topic_arn",
])

TARGET_PATH = args["target_path"]                # s3://.../orders/
REPORT_BUCKET = args["report_bucket"]
REPORT_PREFIX = args["report_prefix"].rstrip("/")  # e.g. quality-reports
SNS_TOPIC_ARN = args["sns_topic_arn"]

s3 = boto3.client("s3")
sns = boto3.client("sns")


def load_processed_data(path: str) -> pd.DataFrame:
    # Check explicitly rather than letting pandas/pyarrow raise whatever
    # exception it happens to throw on a missing prefix - that exception
    # still fails the job either way, but this gives a specific, readable
    # cause that actually reaches the SNS alert instead of a buried
    # pyarrow/fsspec stack trace.
    bucket, _, prefix = path.replace("s3://", "").partition("/")
    listing = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1)
    if listing.get("KeyCount", 0) == 0:
        raise SystemExit(
            f"PROCESSED_DATA_EMPTY: no objects found at {path}. The transform "
            "job may not have produced output, or hasn't run yet - check its "
            "execution before assuming this is a data quality issue."
        )

    # Reads the partitioned Parquet output (region/year/month) directly;
    # pandas + pyarrow resolve the Hive-style partition columns automatically.
    return pd.read_parquet(path, engine="pyarrow")


def build_expectations():
    return [
        gx.expectations.ExpectColumnValuesToNotBeNull(
            column="order_id", meta={"severity": "critical"}),
        gx.expectations.ExpectColumnValuesToBeUnique(
            column="order_id", meta={"severity": "critical"}),
        gx.expectations.ExpectTableRowCountToBeBetween(
            min_value=1, meta={"severity": "critical"}),
        gx.expectations.ExpectColumnValuesToBeBetween(
            column="quantity", min_value=1, mostly=0.99,
            meta={"severity": "critical"}),
        gx.expectations.ExpectColumnValuesToNotBeNull(
            column="unit_price", mostly=0.90, meta={"severity": "warning"}),
        gx.expectations.ExpectColumnValuesToMatchRegex(
            column="currency_clean", regex=r"^[A-Z]{3}$", mostly=0.90,
            meta={"severity": "warning"}),
        gx.expectations.ExpectColumnValuesToNotBeNull(
            column="order_date_parsed", mostly=0.90, meta={"severity": "warning"}),
    ]


def run_validation(df: pd.DataFrame):
    context = gx.get_context()
    data_source = context.data_sources.add_pandas("processed_orders_source")
    data_asset = data_source.add_dataframe_asset(name="processed_orders")
    batch_def = data_asset.add_batch_definition_whole_dataframe("batch")
    batch = batch_def.get_batch(batch_parameters={"dataframe": df})

    outcomes = []
    for expectation in build_expectations():
        result = batch.validate(expectation)
        outcomes.append({
            "expectation_type": expectation.__class__.__name__,
            "column": getattr(expectation, "column", None),
            "severity": expectation.meta.get("severity"),
            "success": bool(result.success),
            "result": result.result,
        })
    return outcomes


def write_report(outcomes, row_count) -> str:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = {
        "timestamp_utc": timestamp,
        "target_path": TARGET_PATH,
        "row_count": row_count,
        "overall_success": all(o["success"] for o in outcomes if o["severity"] == "critical"),
        "results": outcomes,
    }
    key = f"{REPORT_PREFIX}/quality_report_{timestamp}.json"
    s3.put_object(
        Bucket=REPORT_BUCKET,
        Key=key,
        Body=json.dumps(report, indent=2, default=str).encode("utf-8"),
        ContentType="application/json",
    )
    print(f"Quality report written to s3://{REPORT_BUCKET}/{key}")
    return key


def notify_warnings(warning_failures):
    if not warning_failures or not SNS_TOPIC_ARN:
        return
    lines = [
        f"  - {w['expectation_type']} on '{w['column']}'" for w in warning_failures
    ]
    message = (
        "Data quality WARNING (non-fatal) - pipeline continued.\n\n"
        "The following checks fell below their acceptable threshold:\n"
        + "\n".join(lines)
    )
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="ecommerce-etl data quality warning",
        Message=message,
    )


def main():
    df = load_processed_data(TARGET_PATH)
    row_count = len(df)
    print(f"Loaded {row_count} processed rows from {TARGET_PATH}")

    outcomes = run_validation(df)
    write_report(outcomes, row_count)

    critical_failures = [o for o in outcomes if not o["success"] and o["severity"] == "critical"]
    warning_failures = [o for o in outcomes if not o["success"] and o["severity"] == "warning"]

    for o in outcomes:
        status = "PASS" if o["success"] else "FAIL"
        print(f"[{o['severity']:>8}] {status} - {o['expectation_type']} ({o['column']})")

    notify_warnings(warning_failures)

    if critical_failures:
        # Non-zero exit -> Glue job run fails -> Step Functions Catch fires,
        # routing to the pipeline's existing NotifyFailure state.
        failed_names = ", ".join(f"{f['expectation_type']}({f['column']})" for f in critical_failures)
        raise SystemExit(f"Data quality CRITICAL failure: {failed_names}")

    print("Data quality check passed (critical checks). Proceeding to processed crawler.")


if __name__ == "__main__":
    main()
