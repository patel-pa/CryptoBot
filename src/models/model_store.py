"""Save and load the trained model: Amazon S3 on AWS, a local file otherwise.

With MODEL_S3_BUCKET set (Kubernetes on AWS), the retrain job uploads every new
model to a versioned S3 bucket, and the API downloads it, keeps it in memory,
and checks at most every MODEL_CHECK_INTERVAL_SECONDS whether a newer version
exists. Without a bucket (docker compose, kind) the model is a local file, and
the API reloads it when the file changes. Either way no restart is needed
after a retrain.

The model is a pickle (joblib), and loading a pickle can run code, so it must
only ever come from storage that only our own retrain job can write to.
"""
import io
import os
import tempfile
import threading
import time
from functools import lru_cache

import boto3
import joblib
from botocore.exceptions import BotoCoreError, ClientError

from src.config import model_settings


class ModelUnavailable(Exception):
    """No trained model can be loaded: none saved yet, or its storage is unreachable."""


def _to_bytes(model):
    buffer = io.BytesIO()
    joblib.dump(model, buffer)
    return buffer.getvalue()


def _from_bytes(data):
    return joblib.load(io.BytesIO(data))


class ModelStore:
    """One model location (an S3 object or a local file) plus an in-memory cache.

    `s3_client` and `clock` can be replaced in tests; by default the S3 client
    is created on first use and time comes from time.monotonic (a clock that
    never jumps when the system time is changed).
    """

    def __init__(self, settings, s3_client=None, clock=time.monotonic):
        self.settings = settings
        self._s3 = s3_client
        self._clock = clock
        self._lock = threading.Lock()    # the API serves requests in several threads
        self._model = None               # the loaded model, or None
        self._version = None             # S3 version id, or the local file's (mtime, size)
        self._checked_at = None          # clock time of the last look at the storage

    @property
    def s3(self):
        if self._s3 is None:
            self._s3 = boto3.client("s3")   # credentials: EKS Pod Identity on AWS
        return self._s3

    def location(self):
        s = self.settings
        return f"s3://{s.s3_bucket}/{s.s3_key}" if s.s3_bucket else str(s.local_path)

    def save(self, model):
        """Store a newly trained model; return where it went (for the log)."""
        data = _to_bytes(model)
        if self.settings.s3_bucket:
            response = self.s3.put_object(
                Bucket=self.settings.s3_bucket, Key=self.settings.s3_key, Body=data)
            version = response.get("VersionId") or response["ETag"]
            return f"{self.location()} (version {version})"

        path = self.settings.local_path
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write a temporary file next to the target, then rename it over the
        # target in one step: the API never sees a half-written model.
        with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".tmp", delete=False) as tmp:
            tmp.write(data)
        # Temporary files are created private (0600); the model is not a secret and
        # must stay readable if the API and the retrain job run as different users.
        os.chmod(tmp.name, 0o644)
        os.replace(tmp.name, path)
        return str(path)

    def get(self):
        """Return the current model, downloading or reloading it only when it changed.

        Raises ModelUnavailable if there is no model yet. If the storage cannot
        be reached but a model is already loaded, that model is kept.
        """
        with self._lock:
            now = self._clock()
            if (self._model is not None
                    and now - self._checked_at < self.settings.check_interval_seconds):
                return self._model                      # checked recently: use the cache
            try:
                if self._model is None or self._current_version() != self._version:
                    self._model, self._version = self._load()
                    print(f"Loaded model from {self.location()} (version {self._version})",
                          flush=True)
            except (ClientError, BotoCoreError, OSError) as exc:
                if self._model is None:
                    raise ModelUnavailable(f"no model at {self.location()}: {exc!r}") from exc
                print(f"Model check failed, keeping the loaded model: {exc!r}", flush=True)
            self._checked_at = now
            return self._model

    def _current_version(self):
        """A cheap look at what is stored now, without downloading it."""
        s = self.settings
        if s.s3_bucket:
            head = self.s3.head_object(Bucket=s.s3_bucket, Key=s.s3_key)
            return head.get("VersionId") or head["ETag"]
        stat = s.local_path.stat()
        return (stat.st_mtime_ns, stat.st_size)

    def _load(self):
        """Download (S3) or read (local file) the model; return (model, version)."""
        s = self.settings
        if s.s3_bucket:
            obj = self.s3.get_object(Bucket=s.s3_bucket, Key=s.s3_key)
            return _from_bytes(obj["Body"].read()), obj.get("VersionId") or obj["ETag"]
        version = self._current_version()
        return _from_bytes(s.local_path.read_bytes()), version


@lru_cache(maxsize=1)
def get_store():
    """The process-wide store, created on first use (settings are read then, not at import)."""
    return ModelStore(model_settings())


def load_model():
    return get_store().get()


def save_model(model):
    return get_store().save(model)
