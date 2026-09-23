"""
Generates sample e-commerce order data simulating multiple regional stores
dropping raw JSON files into S3. Data is intentionally messy to mirror
real-world raw data: duplicates, nulls, inconsistent currency codes,
malformed dates, and inconsistent field casing.

Output layout (mirrors an S3 raw zone partitioned by region and date):
    output/raw/region=US/date=2026-09-20/orders.json
    output/raw/region=EU/date=2026-09-20/orders.json
    ...

Each file is in JSON Lines format.
"""

import json
import random
import uuid
import os
from datetime import datetime, timedelta

random.seed(42)  # reproducible output

REGIONS = {
    "US": {"currency": "USD", "store_ids": ["US-STORE-01", "US-STORE-02"]},
    "EU": {"currency": "EUR", "store_ids": ["EU-STORE-01"]},
    "UK": {"currency": "GBP", "store_ids": ["UK-STORE-01"]},
    "IN": {"currency": "INR", "store_ids": ["IN-STORE-01", "IN-STORE-02"]},
}

PRODUCTS = [
    ("P1001", "Wireless Mouse", 19.99),
    ("P1002", "Mechanical Keyboard", 79.99),
    ("P1003", "USB-C Hub", 34.50),
    ("P1004", "27in Monitor", 249.99),
    ("P1005", "Laptop Stand", 45.00),
    ("P1006", "Noise Cancelling Headphones", 199.99),
    ("P1007", "Webcam 1080p", 59.99),
    ("P1008", "Desk Lamp", 29.99),
    ("P1009", "External SSD 1TB", 109.99),
    ("P1010", "Ergonomic Chair", 329.00),
]

PAYMENT_METHODS = ["credit_card", "debit_card",
                   "paypal", "gift_card", None]  # None = messy/missing
STATUSES = ["completed", "completed", "completed",
            "cancelled", "refunded", "pending"]

# Date-format inconsistency pool, to simulate different store systems
DATE_FORMATS = [
    "%Y-%m-%dT%H:%M:%S",   # ISO-ish
    "%Y-%m-%d %H:%M:%S",   # space separated
    "%d/%m/%Y %H:%M",      # UK-style
    "%m-%d-%Y",            # US-style, no time
]


def random_date_str(base_date):
    fmt = random.choice(DATE_FORMATS)
    dt = base_date + timedelta(hours=random.randint(0, 23),
                               minutes=random.randint(0, 59))
    return dt.strftime(fmt)


def make_order(region, base_date, force_currency_typo=False):
    product_id, product_name, unit_price = random.choice(PRODUCTS)
    quantity = random.randint(1, 5)
    currency = REGIONS[region]["currency"]

    # Intentionally inject messy currency codes sometimes (lowercase, wrong code, etc.)
    if force_currency_typo or random.random() < 0.08:
        currency = random.choice([currency.lower(), "USD$", "", None])

    order = {
        "order_id": str(uuid.uuid4()),
        "customer_id": f"CUST-{random.randint(1000, 9999)}",
        "product_id": product_id,
        "product_name": product_name,
        "quantity": quantity,
        "unit_price": unit_price,
        "currency": currency,
        "order_date": random_date_str(base_date),
        "store_id": random.choice(REGIONS[region]["store_ids"]),
        "payment_method": random.choice(PAYMENT_METHODS),
        "status": random.choice(STATUSES),
    }

    # Randomly drop a field entirely, to simulate inconsistent upstream schemas
    if random.random() < 0.05:
        drop_field = random.choice(
            ["payment_method", "customer_id", "quantity"])
        order.pop(drop_field, None)

    # Randomly null out unit_price to simulate bad data
    if random.random() < 0.03:
        order["unit_price"] = None

    return order


def generate():
    out_root = os.path.join(os.path.dirname(__file__), "output", "raw")
    today = datetime.now()
    days = [today - timedelta(days=i) for i in range(2)]  # 2 days of data

    total_files = 0
    total_orders = 0

    for region in REGIONS:
        for day in days:
            orders = [make_order(region, day)
                      for _ in range(random.randint(40, 80))]

            # Inject duplicates (same order appearing twice, as if a store's
            # upload job retried and re-sent the same batch)
            dup_count = random.randint(2, 5)
            orders.extend(random.sample(orders, min(dup_count, len(orders))))
            random.shuffle(orders)

            partition_dir = os.path.join(
                out_root, f"region={region}", f"date={day.strftime('%Y-%m-%d')}"
            )
            os.makedirs(partition_dir, exist_ok=True)
            file_path = os.path.join(partition_dir, "orders.jsonl")

            with open(file_path, "w") as f:
                for order in orders:
                    f.write(json.dumps(order) + "\n")

            total_files += 1
            total_orders += len(orders)
            print(f"Wrote {len(orders)} orders -> {file_path}")

    print(
        f"\nDone. {total_files} files, {total_orders} total order records (including intentional duplicates).")


if __name__ == "__main__":
    generate()
