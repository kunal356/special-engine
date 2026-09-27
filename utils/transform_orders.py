"""
Glue ETL job: cleans and standardizes raw e-commerce order data.

Thin orchestration layer only - all transformation logic lives in
transform_logic.py so it can be unit tested without a Glue runtime.
"""

import sys
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

from transform_logic import transform, validate_not_empty


def main():
    args = getResolvedOptions(sys.argv, [
        "JOB_NAME", "source_database", "source_table", "target_path"
    ])

    sc = SparkContext()
    glueContext = GlueContext(sc)
    spark = glueContext.spark_session
    job = Job(glueContext)
    job.init(args["JOB_NAME"], args)

    # Dynamic (not static) partition overwrite: mode("overwrite") only
    # replaces the specific partitions present in this run's output, rather
    # than wiping the entire target path first.
    spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

    # transformation_ctx is required for --job-bookmark-option to do
    # anything - without it, every run reprocesses the full raw history.
    dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=args["source_database"],
        table_name=args["source_table"],
        transformation_ctx="raw_orders_source",
    )
    df = dynamic_frame.toDF()

    validate_not_empty(df, args["source_database"], args["source_table"])

    df = transform(df)

    df.write.mode("overwrite") \
        .partitionBy("region", "year", "month") \
        .parquet(args["target_path"])

    job.commit()


if __name__ == "__main__":
    main()
