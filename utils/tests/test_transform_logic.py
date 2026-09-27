import pytest
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, IntegerType
from transform_logic import (
    deduplicate_orders,
    parse_order_dates,
    normalize_currency,
    handle_missing_price,
    compute_line_total,
    derive_partition_columns,
    validate_not_empty,
    transform,
)


def test_deduplicate_orders_removes_duplicate_order_id(spark):
    df = spark.createDataFrame(
        [("o1", "usd"), ("o1", "usd"), ("o2", "eur")],
        ["order_id", "currency"],
    )
    result = deduplicate_orders(df)
    assert result.count() == 2
    assert sorted(r.order_id for r in result.collect()) == ["o1", "o2"]


@pytest.mark.parametrize("raw_date,expected_ymd", [
    ("2026-09-22T09:51:44", "2026-09-22"),
    ("2026-09-22 09:51:44", "2026-09-22"),
    ("22/09/2026 09:51", "2026-09-22"),
    ("09-22-2026", "2026-09-22"),
])
def test_parse_order_dates_handles_all_known_formats(spark, raw_date, expected_ymd):
    df = spark.createDataFrame([(raw_date,)], ["order_date"])
    result = parse_order_dates(df).collect()[0]
    assert result.date_parse_failed is False
    assert result.order_date_parsed.strftime("%Y-%m-%d") == expected_ymd


def test_parse_order_dates_flags_unparseable_date(spark):
    df = spark.createDataFrame([("not-a-date",)], ["order_date"])
    result = parse_order_dates(df).collect()[0]
    assert result.order_date_parsed is None
    assert result.date_parse_failed is True


@pytest.mark.parametrize("raw_currency,expected_clean", [
    ("usd", "USD"),
    ("USD$", "USD"),
    (" eur ", "EUR"),
])
def test_normalize_currency_cleans_valid_values(spark, raw_currency, expected_clean):
    df = spark.createDataFrame([(raw_currency,)], ["currency"])
    result = normalize_currency(df).collect()[0]
    assert result.currency_clean == expected_clean
    assert result.currency_invalid is False


@pytest.mark.parametrize("raw_currency", [None, "", "   "])
def test_normalize_currency_flags_blank_and_null_as_invalid(spark, raw_currency):
    schema = StructType([StructField("currency", StringType(), True)])
    df = spark.createDataFrame([(raw_currency,)], schema=schema)
    result = normalize_currency(df).collect()[0]
    assert result.currency_clean is None
    assert result.currency_invalid is True


def test_handle_missing_price_flags_null_price(spark):
    df = spark.createDataFrame([("9.99",), (None,)], ["unit_price"])
    result = handle_missing_price(df).collect()
    prices = {r.unit_price: r.price_missing for r in result}
    assert prices[9.99] is False
    assert prices[None] is True


def test_compute_line_total_multiplies_price_and_quantity(spark):
    schema = StructType([
        StructField("unit_price", DoubleType(), True),
        StructField("quantity", IntegerType(), True),
    ])
    df = spark.createDataFrame([(10.0, 3)], schema=schema)
    result = compute_line_total(df).collect()[0]
    assert result.line_total == 30.0


def test_compute_line_total_is_null_when_price_missing(spark):
    schema = StructType([
        StructField("unit_price", DoubleType(), True),
        StructField("quantity", IntegerType(), True)
    ])
    df = spark.createDataFrame([(None, 3)], schema=schema)
    df = df.withColumn("unit_price", df.unit_price.cast("double"))
    result = compute_line_total(df).collect()[0]
    assert result.line_total is None


def test_derive_partition_columns_from_parsed_date(spark):
    df = spark.createDataFrame([("2026-09-22T09:51:44",)], ["order_date"])
    df = parse_order_dates(df)
    result = derive_partition_columns(df).collect()[0]
    assert result.year == 2026
    assert result.month == 9


def test_validate_not_empty_raises_on_empty_dataframe(spark):
    df = spark.createDataFrame([], "order_id string")
    with pytest.raises(SystemExit, match="RAW_DATA_EMPTY"):
        validate_not_empty(df, "ecommerce_raw_db", "raw")


def test_validate_not_empty_passes_on_nonempty_dataframe(spark):
    df = spark.createDataFrame([("o1",)], ["order_id"])
    validate_not_empty(df, "ecommerce_raw_db", "raw")  # should not raise


def test_transform_end_to_end_on_representative_raw_batch(spark):
    """A small batch covering dedup, one clean row, and one messy row."""
    df = spark.createDataFrame(
        [
            ("o1", "2026-09-22T09:51:44", "usd", "9.99", 2, "north"),
            ("o1", "2026-09-22T09:51:44", "usd", "9.99", 2, "north"),   # duplicate
            ("o2", "garbage-date", None, None, 1, "south"),             # messy row
        ],
        ["order_id", "order_date", "currency", "unit_price", "quantity", "region"],
    )
    result = transform(df)

    assert result.count() == 2  # duplicate collapsed

    rows = {r.order_id: r for r in result.collect()}
    assert rows["o1"].currency_clean == "USD"
    assert rows["o1"].line_total == pytest.approx(19.98)
    assert rows["o1"].date_parse_failed is False

    assert rows["o2"].date_parse_failed is True
    assert rows["o2"].currency_invalid is True
    assert rows["o2"].price_missing is True
    assert rows["o2"].line_total is None
