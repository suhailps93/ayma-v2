import json

import pytest

import gemini
import gemini_batch
from config import CONFIG


class _FakeBlob:
    def __init__(self, name):
        self.name = name
        self.uploaded = None
        self.content_type = None

    def upload_from_string(self, data, content_type=None):
        self.uploaded = data
        self.content_type = content_type

    def download_as_text(self):
        return self.uploaded or ""


class _FakeBucket:
    def __init__(self):
        self.blobs: dict[str, _FakeBlob] = {}

    def blob(self, path):
        return self.blobs.setdefault(path, _FakeBlob(path))

    def list_blobs(self, prefix=""):
        return [b for name, b in self.blobs.items() if name.startswith(prefix)]


class _FakeDest:
    def __init__(self, gcs_uri):
        self.gcs_uri = gcs_uri


class _FakeJob:
    def __init__(self, name, dest_uri):
        self.name = name
        self.dest = _FakeDest(dest_uri)


class _FakeBatches:
    def __init__(self):
        self.created = None

    def create(self, *, model, src):
        self.created = {"model": model, "src": src}
        return _FakeJob("batches/fake-1", src[: -len(".jsonl")] + "/dest")


class _FakeClient:
    def __init__(self):
        self.batches = _FakeBatches()


def test_schema_dict_uppercases_type_enums():
    out = gemini_batch._schema_dict(
        {"type": "object", "properties": {"x": {"type": "string"}}, "required": ["x"]}
    )
    assert out["type"] == "OBJECT"
    assert out["properties"]["x"]["type"] == "STRING"


def test_request_line_shape():
    line = gemini_batch._request_line(
        "hello", "be nice", {"type": "object", "properties": {}},
        temperature=0.5, max_output_tokens=100,
    )
    req = line["request"]
    assert req["contents"] == [{"role": "user", "parts": [{"text": "hello"}]}]
    assert req["systemInstruction"] == {"parts": [{"text": "be nice"}]}
    assert req["generationConfig"]["temperature"] == 0.5
    assert req["generationConfig"]["maxOutputTokens"] == 100
    assert req["generationConfig"]["responseMimeType"] == "application/json"


def test_request_line_omits_system_instruction_when_blank():
    line = gemini_batch._request_line(
        "hi", "", {"type": "object", "properties": {}},
        temperature=0.2, max_output_tokens=10,
    )
    assert "systemInstruction" not in line["request"]


def test_submit_json_batch_rejects_empty_items():
    with pytest.raises(ValueError):
        gemini_batch.submit_json_batch([], "sys", {"type": "object"}, job_tag="x")


def test_submit_json_batch_writes_jsonl_and_creates_the_job(monkeypatch):
    bucket = _FakeBucket()
    client = _FakeClient()
    monkeypatch.setattr(gemini_batch, "_bucket", lambda: bucket)
    monkeypatch.setattr(gemini, "_client", lambda: client)

    schema = {"type": "object", "properties": {"flags": {"type": "array"}}}
    sub = gemini_batch.submit_json_batch(["a", "b"], "sys", schema, job_tag="test_tag")

    assert sub.count == 2
    assert sub.job_name == "batches/fake-1"
    assert sub.dest_prefix.endswith("/dest")
    assert client.batches.created["model"] == CONFIG.gemini_model
    assert client.batches.created["src"].startswith(
        f"gs://{CONFIG.storage_bucket}/gemini_batches/test_tag/"
    )

    [path] = list(bucket.blobs.keys())
    lines = bucket.blobs[path].uploaded.splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0])["request"]["contents"][0]["parts"][0]["text"] == "a"
    assert json.loads(lines[1])["request"]["contents"][0]["parts"][0]["text"] == "b"
    assert bucket.blobs[path].content_type == "application/jsonl"


def _result_row(payload: dict) -> str:
    return json.dumps(
        {
            "response": {
                "candidates": [
                    {"content": {"parts": [{"text": json.dumps(payload)}]}}
                ]
            }
        }
    )


def test_fetch_json_batch_results_concatenates_shards_in_name_order(monkeypatch):
    bucket = _FakeBucket()
    bucket.blob("dest/predictions.jsonl-00001-of-00002").upload_from_string(
        _result_row({"ok": 2})
    )
    bucket.blob("dest/predictions.jsonl-00000-of-00002").upload_from_string(
        _result_row({"ok": 1})
    )
    monkeypatch.setattr(gemini_batch, "_bucket", lambda: bucket)

    out = gemini_batch.fetch_json_batch_results("gs://mybucket/dest", expected_count=2)
    assert out == [{"ok": 1}, {"ok": 2}]


def test_fetch_json_batch_results_raises_on_count_mismatch(monkeypatch):
    bucket = _FakeBucket()
    bucket.blob("dest/predictions.jsonl-00000-of-00001").upload_from_string(
        _result_row({"ok": 1})
    )
    monkeypatch.setattr(gemini_batch, "_bucket", lambda: bucket)

    with pytest.raises(RuntimeError):
        gemini_batch.fetch_json_batch_results("gs://mybucket/dest", expected_count=2)


def test_fetch_json_batch_results_tolerates_one_unparseable_row(monkeypatch):
    bucket = _FakeBucket()
    bucket.blob("dest/predictions.jsonl-00000-of-00001").upload_from_string(
        _result_row({"ok": 1}) + "\n" + "not json at all"
    )
    monkeypatch.setattr(gemini_batch, "_bucket", lambda: bucket)

    # the unparseable line is dropped rather than raising, so a job whose
    # only garbage is stray non-JSON noise (not a real result row) still
    # finalizes on its one genuine row
    out = gemini_batch.fetch_json_batch_results("gs://mybucket/dest", expected_count=1)
    assert out == [{"ok": 1}]
