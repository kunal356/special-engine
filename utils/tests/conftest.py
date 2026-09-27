from pyspark.sql import SparkSession
import pytest
import os
import sys
# Must run before SparkSession is created. On Windows, Spark spawning a
# Python worker subprocess can resolve `python` to the Microsoft Store's
# app-execution-alias stub instead of the real interpreter, even though
# `python` works fine when typed directly in an activated venv shell.
# Pointing both driver and worker explicitly at sys.executable (the exact
# interpreter currently running this file) removes that ambiguity entirely.
os.environ["PYSPARK_PYTHON"] = sys.executable
os.environ["PYSPARK_DRIVER_PYTHON"] = sys.executable


# Makes `import transform_logic` work when pytest is run from anywhere,
# without needing utils/ installed as a package.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


@pytest.fixture(scope="session")
def spark():
    session = (
        SparkSession.builder
        .appName("transform_logic-tests")
        .master("local[2]")
        .config("spark.sql.shuffle.partitions", "2")
        .config("spark.sql.ansi.enabled", "false")
        .getOrCreate()
    )
    session.sparkContext.setLogLevel("ERROR")
    yield session
    session.stop()
