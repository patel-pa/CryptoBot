"""
DAG: cryptobot_ingest
=====================
Every 15 minutes, fetch the latest historical candles into PostgreSQL by running
`python -m src.collection.fetch_historical` inside the cryptobot-app container.

fetch_historical is idempotent (it resumes from the last stored candle), so
running it on a schedule simply keeps Postgres up to date — this is what removes
the "stale data" gap you saw earlier, automatically.

NOTE: this task runs the src/ code BAKED INTO the cryptobot-app image (a fresh
DockerOperator container), NOT the ./src bind mount the compose services use.
After editing fetch_historical.py, run `docker compose build` or this DAG keeps
running the OLD code.
"""
import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator

# DB credentials the task container needs. Host is the Docker SERVICE NAME
# (not localhost); user/password/db come from the .env loaded by the airflow
# service. The task container joins the same network so "postgres" resolves.
TASK_ENV = {
    "POSTGRES_HOST": "postgres",
    "POSTGRES_PORT": "5432",
    "POSTGRES_USER": os.environ.get("POSTGRES_USER"),
    "POSTGRES_PASSWORD": os.environ.get("POSTGRES_PASSWORD"),
    "POSTGRES_DB": os.environ.get("POSTGRES_DB"),
}

default_args = {"retries": 2, "retry_delay": timedelta(minutes=2)}

with DAG(
    dag_id="cryptobot_ingest",
    description="Fetch the latest historical candles into PostgreSQL",
    schedule="*/15 * * * *",          # every 15 minutes
    start_date=datetime(2026, 1, 1),
    catchup=False,                    # don't backfill every missed 15-min slot
    default_args=default_args,
    tags=["cryptobot"],
) as dag:
    DockerOperator(
        task_id="fetch_historical",
        image="cryptobot-app",                       # the app image compose builds
        command="python -m src.collection.fetch_historical",
        environment=TASK_ENV,
        network_mode="cryptobot_network",            # same network as the databases
        auto_remove="success",                       # clean up the container when done
        mount_tmp_dir=False,
    )
