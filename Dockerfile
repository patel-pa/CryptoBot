# One image, shared by every Python service: API, streamer, dashboard, and the
# one-shot init/backfill jobs. Each docker-compose service just runs a different
# command against this same image.
#
# Stages (a multi-stage build: each stage starts FROM an earlier one):
#   base     the app's packages, shared by the two stages below
#   test     base + development tools (ruff, pytest), for checks only, never deployed:
#              docker build --target test -t cryptobot-test .
#              docker run --rm cryptobot-test
#   runtime  base + the code: the production image (the last stage, so a plain
#            `docker build .` produces it)

FROM python:3.11-slim AS base

# PYTHONUNBUFFERED → print() / logs appear immediately in `docker compose logs`.
# PYTHONDONTWRITEBYTECODE → don't litter the image with .pyc files.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies FIRST so Docker caches this layer and only re-installs
# when requirements-docker.txt changes (not on every code edit).
COPY requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt


FROM base AS test

# Before the code, so a code edit does not reinstall the tools.
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt

COPY . .

# Lint + tests. The caches are off so this also works with the repo mounted
# read-only over /app (to check uncommitted code without rebuilding).
CMD ["sh", "-c", "ruff check . --no-cache && pytest -q -p no:cacheprovider"]


FROM base AS runtime

# Copy the rest of the project (source code). The trained model is NOT baked in
# (.dockerignore): it comes from S3 on AWS, or the shared models volume locally.
COPY . .

# Default command — overridden per service in docker-compose.yml.
CMD ["python", "-m", "src.collection.stream_live"]
