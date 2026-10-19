# CryptoBot — Real-Time & Batch Data Pipeline for Crypto Market Data

An end-to-end data engineering platform that ingests Binance BTC/USDT market data through **two independent pipelines** — a batch pipeline for historical candles and a real-time streaming pipeline for live ticks — stores each in a fit-for-purpose database, trains an ML model to forecast the next candle, and serves everything through a REST API and a live Streamlit dashboard. The full stack is containerized, orchestrated with Airflow, and covered by CI.

> Built solo as the capstone Data Engineering project for the DataScientest / Liora Data Engineer programme — designed, implemented, and delivered end-to-end.

## v2 in progress

The AWS/EKS deployment is being built on the `dev` branch. The finished Data Engineering version is release [v1.0-data-engineering](https://github.com/patel-pa/CryptoBot/releases/tag/v1.0-data-engineering).

---

## Architecture

Two pipelines that converge at a single serving layer (FastAPI + Streamlit):

```
Binance REST API   ──► clean ──► PostgreSQL (ohlcv_data) ──► ML training ──► model.pkl
                                                         └──► FastAPI /charts ──► dashboard

Binance WebSocket  ──► Path A (every tick) ─────────────────► FastAPI /stream ──► live chart
                   └─► Path B (on candle close) ──► MongoDB (closed_candles) ──► ML predict ──► FastAPI /predict
```

**Why two databases?** The two sources are fundamentally different, so they get different storage:

| | REST API (historical) | WebSocket (live) |
|---|---|---|
| Shape | Fixed 12-field candles, stable schema | High-frequency, semi-structured messages |
| Cadence | Batch (daily top-ups) | ~1 message/second, pushed |
| Store | **PostgreSQL** — schema enforcement, `NUMERIC(18,8)` exact prices, ordered time-series queries | **MongoDB** — high write throughput, flexible JSON, no migrations |

---

## Tech stack

**Languages & core:** Python 3.11
**Ingestion:** Binance REST API, Binance WebSocket (`websocket-client`, `websockets`)
**Storage:** PostgreSQL (SQLAlchemy 2.0, psycopg2), MongoDB (PyMongo)
**Serving:** FastAPI + Uvicorn
**Dashboard:** Streamlit + Plotly
**ML:** scikit-learn, pandas, joblib
**Orchestration:** Apache Airflow (DockerOperator)
**Infra & CI/CD:** Docker, docker-compose, GitHub Actions (flake8 + pytest + image build)
**Testing:** pytest

---

## Key engineering features

- **Idempotent ingestion** — the batch pipeline uses `ON CONFLICT (symbol, open_time) DO NOTHING`; the stream pipeline uses a unique index on `(symbol, kline_start_time)` + upsert. Re-runs and overlapping ranges never create duplicates.
- **Incremental / resumable loading** — before fetching, the collector reads `MAX(close_time)` from PostgreSQL and resumes 1 ms after the last stored candle, so the same script serves both the initial backfill and scheduled top-ups.
- **Pagination** — handles Binance's 1,000-candle-per-request limit by advancing `startTime` until a partial page signals the present has been reached.
- **Scheduled orchestration** — two Airflow DAGs keep the system current: `cryptobot_ingest` re-runs the idempotent collector every 15 minutes, and `cryptobot_train` catches the data up and retrains the model daily, publishing `model.pkl` to a shared volume the API reads live (no restart needed).
- **Verified data quality** — **~240,000+** one-minute BTC/USDT candles loaded with **0 gaps** (and growing — the ingest DAG tops up every 15 min), confirmed by a verification notebook (`open_time[n+1] == close_time[n] + 1 ms`).
- **Predicted-vs-actual tracking** — every `/predict` call is persisted, so `/predictions` can join each forecast against the candle's real close for later evaluation.
- **CI on every push** — GitHub Actions runs flake8 (fails on syntax/undefined-name errors), the pytest suite, and a Docker image build.

---

## Repository structure

```
src/
├── collection/     # fetch_historical.py (REST→PG), stream_live.py (WS→Mongo)
├── storage/        # postgres.py, mongo.py, schema.sql, init_db.py, *_writer.py
├── features/       # build_features.py
├── models/         # train_model.py, predict_model.py
├── api/            # main.py (FastAPI: /charts, /stream, /predict, /predictions, /health)
├── visualization/  # app.py (Streamlit dashboard: historical + live + predictions)
├── params/         # constants, enums
└── utils/          # time / url / dataframe helpers
airflow/            # Dockerfile + dags/ (cryptobot_ingest.py, cryptobot_train.py)
tests/              # pytest suite
notebooks/          # exploration + verification
.github/workflows/  # CI pipeline (python-app.yml)
docker-compose.yml  # full stack: postgres, mongo, init, historical, streamer, api, dashboard, airflow
```

---

## Getting started

**Prerequisites:** Docker and docker-compose.

### 1. Configure environment

Copy the template and set your own passwords (`.env.example` lists every variable):

```bash
cp .env.example .env
```

### 2. Launch the full stack

```bash
docker compose up --build
```

That single command brings up everything and wires the pipelines together automatically:

| Service | Role | URL |
|---|---|---|
| `postgres` / `mongodb` | Databases | — |
| `init` | One-shot: create the Postgres table + Mongo indexes, then exit | — |
| `historical` | One-shot: backfill / catch up historical candles (idempotent), then exit | — |
| `streamer` | Always-on: live Binance WebSocket → MongoDB | — |
| `api` | Always-on: FastAPI | http://localhost:8000/docs |
| `dashboard` | Always-on: Streamlit live chart + predictions | http://localhost:8501 |
| `airflow` | Orchestration UI (ingest + train DAGs) | http://localhost:8080 |

Because `historical` runs idempotently in the background, the dashboard is usable while the database catches up. To run a step manually instead of via the stack:

```bash
docker compose run --rm api python -m src.storage.init_db          # schema + indexes
docker compose run --rm api python -m src.collection.fetch_historical   # backfill
```

---

## API endpoints

| Endpoint | Type | Source | Purpose |
|---|---|---|---|
| `/health` | GET | — | Liveness: the API process is up (no database calls) |
| `/ready` | GET | PostgreSQL + MongoDB | Readiness: 200 if both databases answer, else 503 |
| `/charts` | GET | PostgreSQL | Historical OHLCV for charting |
| `/predict` | GET | MongoDB + model | Next-candle close forecast (also persisted) |
| `/predictions` | GET | MongoDB | Stored forecasts joined with actual closes (predicted-vs-actual) |
| `/stream` | WebSocket | Binance (live) | Real-time tick feed relayed to the browser |

Interactive docs: http://localhost:8000/docs

---

## Testing

```bash
pytest -v
```

CI runs the same suite plus flake8 linting and a Docker image build on every push (see `.github/workflows/python-app.yml`).
