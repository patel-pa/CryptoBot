# One image, shared by every Python service: API, streamer, dashboard, and the
# one-shot init/backfill jobs. Each docker-compose service just runs a different
# command against this same image.

FROM python:3.11-slim

# PYTHONUNBUFFERED → print() / logs appear immediately in `docker compose logs`.
# PYTHONDONTWRITEBYTECODE → don't litter the image with .pyc files.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies FIRST so Docker caches this layer and only re-installs
# when requirements-docker.txt changes (not on every code edit).
COPY requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt

# Copy the rest of the project (source code). The trained model is NOT baked in
# (.dockerignore): it comes from S3 on AWS, or the shared models volume locally.
COPY . .

# Default command — overridden per service in docker-compose.yml.
CMD ["python", "-m", "src.collection.stream_live"]
