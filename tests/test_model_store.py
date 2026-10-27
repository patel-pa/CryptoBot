"""Tests for src/models/model_store.py: the model in S3 or in a local file.

S3 is replaced by a small in-memory fake and time by a fake clock, so the
tests need no AWS account and never wait.
"""
import io
import os
import stat
from pathlib import Path

import boto3
import pytest
from botocore.exceptions import ClientError, EndpointConnectionError

from src.config import ModelSettings
from src.models.model_store import ModelStore, ModelUnavailable

MODEL_1 = {"name": "model-1"}                 # any picklable object works as a "model"
MODEL_2 = {"name": "model-2", "trained_on": 1000}


class FakeS3:
    """In-memory stand-in for the boto3 S3 client: one versioned bucket."""

    def __init__(self):
        self.objects = {}        # (bucket, key) -> (version id, bytes)
        self.calls = []          # names of the calls made, in order
        self.fail_with = None    # an exception that head/get should raise
        self._versions = 0

    def put_object(self, Bucket, Key, Body):
        self.calls.append("put")
        self._versions += 1
        version = f"v{self._versions}"
        self.objects[(Bucket, Key)] = (version, bytes(Body))
        return {"VersionId": version}

    def _lookup(self, call, Bucket, Key):
        self.calls.append(call)
        if self.fail_with:
            raise self.fail_with
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "404", "Message": "Not Found"}}, call)
        return self.objects[(Bucket, Key)]

    def head_object(self, Bucket, Key):
        version, _ = self._lookup("head", Bucket, Key)
        return {"VersionId": version}

    def get_object(self, Bucket, Key):
        version, data = self._lookup("get", Bucket, Key)
        return {"VersionId": version, "Body": io.BytesIO(data)}


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def s3():
    return FakeS3()


@pytest.fixture
def s3_store(s3, clock):
    settings = ModelSettings(s3_bucket="models-bucket", s3_key="dev/model.pkl",
                             local_path=Path("unused.pkl"), check_interval_seconds=60)
    return ModelStore(settings, s3_client=s3, clock=clock)


@pytest.fixture
def local_store(tmp_path, clock, monkeypatch):
    def no_aws(*args, **kwargs):
        raise AssertionError("local mode must not create an S3 client")
    monkeypatch.setattr(boto3, "client", no_aws)
    settings = ModelSettings(s3_bucket=None, s3_key="model.pkl",
                             local_path=tmp_path / "models" / "model.pkl",
                             check_interval_seconds=60)
    return ModelStore(settings, clock=clock)


# ----------------------------------------------------------------- S3 mode

def test_s3_save_uploads_the_model(s3_store, s3):
    location = s3_store.save(MODEL_1)
    assert location == "s3://models-bucket/dev/model.pkl (version v1)"
    assert ("models-bucket", "dev/model.pkl") in s3.objects


def test_s3_first_get_downloads_once(s3_store, s3):
    s3_store.save(MODEL_1)
    assert s3_store.get() == MODEL_1
    assert s3.calls == ["put", "get"]           # first load: no extra head call


def test_s3_cached_model_is_used_within_the_interval(s3_store, s3, clock):
    s3_store.save(MODEL_1)
    s3_store.get()
    clock.now += 30                              # less than the 60 s interval
    assert s3_store.get() == MODEL_1
    assert s3.calls == ["put", "get"]            # no S3 call at all


def test_s3_unchanged_model_is_not_downloaded_again(s3_store, s3, clock):
    s3_store.save(MODEL_1)
    s3_store.get()
    clock.now += 61
    assert s3_store.get() == MODEL_1
    assert s3.calls == ["put", "get", "head"]    # only the cheap version check


def test_s3_newer_model_is_picked_up(s3_store, s3, clock):
    s3_store.save(MODEL_1)
    s3_store.get()
    s3_store.save(MODEL_2)                       # the retrain job uploads a new version
    clock.now += 61
    assert s3_store.get() == MODEL_2
    assert s3.calls[-2:] == ["head", "get"]


def test_s3_no_model_yet_raises_unavailable(s3_store):
    with pytest.raises(ModelUnavailable, match="s3://models-bucket/dev/model.pkl"):
        s3_store.get()


def test_s3_outage_keeps_the_loaded_model(s3_store, s3, clock):
    s3_store.save(MODEL_1)
    s3_store.get()
    s3.fail_with = EndpointConnectionError(endpoint_url="https://s3.example")
    clock.now += 61
    assert s3_store.get() == MODEL_1             # keeps serving instead of failing


def test_s3_outage_without_a_loaded_model_raises_unavailable(s3_store, s3):
    s3.fail_with = EndpointConnectionError(endpoint_url="https://s3.example")
    with pytest.raises(ModelUnavailable):
        s3_store.get()


# -------------------------------------------------------- local file mode

def test_local_save_writes_the_file_and_get_reads_it(local_store):
    location = local_store.save(MODEL_1)
    path = local_store.settings.local_path
    assert location == str(path)
    assert path.is_file()
    assert local_store.get() == MODEL_1


def test_local_save_leaves_no_temporary_file(local_store):
    local_store.save(MODEL_1)
    local_store.save(MODEL_2)
    assert [p.name for p in local_store.settings.local_path.parent.iterdir()] == ["model.pkl"]


@pytest.mark.skipif(os.name != "posix", reason="Unix file permissions")
def test_local_model_file_is_readable_by_other_users(local_store):
    local_store.save(MODEL_1)
    assert stat.S_IMODE(local_store.settings.local_path.stat().st_mode) == 0o644


def test_local_replaced_file_is_reloaded_after_the_interval(local_store, clock):
    local_store.save(MODEL_1)
    assert local_store.get() == MODEL_1
    local_store.save(MODEL_2)                    # e.g. the retrain job in docker compose
    clock.now += 30
    assert local_store.get() == MODEL_1          # still cached
    clock.now += 31
    assert local_store.get() == MODEL_2          # file changed: reloaded


def test_local_missing_file_raises_unavailable(local_store):
    with pytest.raises(ModelUnavailable, match="model.pkl"):
        local_store.get()
