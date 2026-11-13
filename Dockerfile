# One image, shared by every Python service: API, streamer, dashboard, and the
# one-shot init/backfill jobs. Each docker-compose service just runs a different
# command against this same image.
#
# Stages (a multi-stage build: each stage starts FROM an earlier one):
#   base     the app's packages, shared by the two stages below
#   test     base + development tools (ruff, pytest), for checks only, never deployed:
#              docker build --target test -t cryptobot-test .
#              docker run --rm cryptobot-test
#   runtime  base + the AWS database CA bundle + the code, run as a non-root user:
#            the production image (the last stage, so a plain `docker build .`
#            produces it)

# Pinned by digest, so every build starts from exactly the same image: a tag such
# as 3.11-slim moves whenever it is rebuilt. The tag says what the digest is.
FROM python:3.11.18-slim-trixie@sha256:ffe4b0c76963e64f05484d74dbb3f67fad1effcf3c5c22c2235f0fafc8a9c98f AS base

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

# A non-root user with a fixed NUMERIC id: Kubernetes' runAsNonRoot can only
# check a numeric user. Writable for the app: /home/app (libraries that keep
# settings or caches there), /tmp, and /app/models (below); nothing else.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --create-home --home-dir /home/app \
    --shell /usr/sbin/nologin app

# AWS's CA bundle for Amazon RDS and DocumentDB (every region), so the app can
# check the databases' TLS certificates: on AWS, MONGO_TLS_CA_FILE and
# POSTGRES_SSLROOTCERT point to this file. The checksum pins the exact file: a
# build that downloads it (no cached layer, as in CI) fails if the file was
# changed or AWS published a new bundle; cached builds do not download it again.
# To update: download the file, check it, and put its new sha256 here.
# The folder is created first: ADD would create it with the file's mode 644
# (no "x"), and then the app user could not open it.
RUN mkdir -m 755 /etc/ssl/aws
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b --chmod=644 \
    https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/aws/global-bundle.pem

# Copy the rest of the project (source code). The trained model is NOT baked in
# (.dockerignore): it comes from S3 on AWS, or the shared models volume locally.
# The code stays owned by root, so the app can read it but never change it.
COPY . .

# The only folder under /app the app writes: the local model file (docker
# compose). A new volume mounted here starts as a copy of this folder, owner
# included.
RUN mkdir -p /app/models && chown app:app /app/models

USER 10001:10001

# Default command — overridden per service in docker-compose.yml.
CMD ["python", "-m", "src.collection.stream_live"]
