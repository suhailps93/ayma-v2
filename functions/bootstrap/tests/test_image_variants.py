"""Perf Phase 2 PREP chunk A: cloud image variants (staging-only).

Unit tests for ``image_variants`` + its two routes. No network: GCS is an
in-memory fake, OIDC verification is stubbed.
"""

import base64
import dataclasses
import hashlib
import io

import pytest
from PIL import Image

import auth
import image_variants
import main
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)

BUCKET = "ayma-staging.firebasestorage.app"
ORIGINAL = "uploads/u-9/photo_169999_0.jpg"


class _NotFound(Exception):
    pass


# The module detects GCS 404s by exception class NAME so the fake needs no
# google-cloud imports — but name the class exactly like the real one.
_NotFound.__name__ = "NotFound"


class FakeBlob:
    def __init__(self, bucket, name):
        self._bucket = bucket
        self.name = name
        self.content_type = None
        self.size = 0
        self.md5_hash = None
        self.metadata = None

    def _load(self):
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            raise _NotFound(self.name)
        payload, ctype, meta = entry
        self.content_type = ctype
        self.size = len(payload)
        self.md5_hash = base64.b64encode(hashlib.md5(payload).digest()).decode()
        self.metadata = dict(meta)

    def reload(self):
        self._load()

    def download_as_bytes(self):
        self._load()
        return self._bucket._objects[self.name][0]

    def upload_from_string(self, payload, content_type=None):
        if isinstance(payload, str):
            payload = payload.encode()
        self._bucket._objects[self.name] = (payload, content_type, {})
        self._load()

    def patch(self):
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            raise _NotFound(self.name)
        payload, ctype, _meta = entry
        self._bucket._objects[self.name] = (payload, ctype, dict(self.metadata or {}))


class FakeBucket:
    name = BUCKET

    def __init__(self):
        self._objects = {}

    def blob(self, name):
        return FakeBlob(self, name)

    def seed(self, name, payload, content_type="image/jpeg"):
        self._objects[name] = (payload, content_type, {})

    def list_blobs(self, prefix="", max_results=None):
        out = []
        for name in sorted(self._bucket_names(prefix)):
            out.append(self.blob(name))
            if max_results and len(out) >= max_results:
                break
        return out

    def _bucket_names(self, prefix):
        return [n for n in self._objects if n.startswith(prefix)]


def _jpeg(width=1600, height=1200, color=(200, 30, 30)):
    buf = io.BytesIO()
    Image.new("RGB", (width, height), color).save(buf, format="JPEG")
    return buf.getvalue()


def _png(width=1600, height=1200):
    buf = io.BytesIO()
    Image.new("RGBA", (width, height), (10, 200, 10, 255)).save(buf, format="PNG")
    return buf.getvalue()


def _envelope(bucket=BUCKET, object_id=ORIGINAL, event="OBJECT_FINALIZE"):
    return {
        "message": {
            "attributes": {
                "bucketId": bucket,
                "objectId": object_id,
                "eventType": event,
            },
            "messageId": "1",
        },
        "subscription": "projects/p/subscriptions/s",
    }


# --- naming + gates -------------------------------------------------------


def test_variant_name_inserts_spec_before_extension():
    assert (
        image_variants.variant_name(ORIGINAL, "thumb", 400, ".jpg")
        == "uploads/u-9/photo_169999_0__thumb_400.jpg"
    )
    assert (
        image_variants.variant_name(ORIGINAL, "medium", 1080, ".jpg")
        == "uploads/u-9/photo_169999_0__medium_1080.jpg"
    )


def test_is_variant_path_matches_only_generated_names():
    assert image_variants.is_variant_path("uploads/u/photo_1__thumb_400.jpg")
    assert image_variants.is_variant_path("uploads/u/photo_1__medium_1080.png")
    assert not image_variants.is_variant_path(ORIGINAL)
    assert not image_variants.is_variant_path("uploads/u/photo_1__thumb_4000.jpg")


def test_is_profile_photo_path_scope():
    assert image_variants.is_profile_photo_path("uploads/u-9/profile_1.jpg")
    assert image_variants.is_profile_photo_path("uploads/u-9/photo_1_0.png")
    assert image_variants.is_profile_photo_path("uploads/u-9/ig_abc.jpg")
    assert not image_variants.is_profile_photo_path("uploads/u-9/chat_1.jpg")
    assert not image_variants.is_profile_photo_path("uploads/u-9/dm/t/1.jpg")
    assert not image_variants.is_profile_photo_path("verification/u-9/selfie.jpg")
    assert not image_variants.is_profile_photo_path("uploads/u-9/nested/x/photo_1.jpg")


def test_should_process_gate():
    ok = image_variants.should_process(BUCKET, ORIGINAL, "image/jpeg", BUCKET)
    assert ok.process
    assert not image_variants.should_process(
        "other-bucket", ORIGINAL, "image/jpeg", BUCKET
    ).process
    assert not image_variants.should_process(
        BUCKET, "uploads/u/photo_1__thumb_400.jpg", "image/jpeg", BUCKET
    ).process
    assert not image_variants.should_process(
        BUCKET, "uploads/u/chat_1.jpg", "image/jpeg", BUCKET
    ).process
    assert not image_variants.should_process(
        BUCKET, "uploads/u/photo_1.bin", "application/octet-stream", BUCKET
    ).process
    # Missing/generic content-type falls back to the extension, Pillow arbiter.
    assert image_variants.should_process(
        BUCKET, ORIGINAL, None, BUCKET
    ).process


# --- rendering ------------------------------------------------------------


def test_render_variant_widths_and_no_upscale():
    src = _jpeg(1600, 1200)
    thumb = image_variants.render_variant(src, 400, 82)
    assert thumb is not None
    payload, ext, ctype = thumb
    assert ext == ".jpg" and ctype == "image/jpeg"
    with Image.open(io.BytesIO(payload)) as img:
        assert img.size == (400, 300)
    medium = image_variants.render_variant(src, 1080, 85)
    assert medium is not None
    with Image.open(io.BytesIO(medium[0])) as img:
        assert img.size == (1080, 810)
    # No upscaling: a 300px source yields no 400px variant.
    assert image_variants.render_variant(_jpeg(300, 200), 400, 82) is None


def test_render_variant_preserves_png_and_rejects_garbage():
    out = image_variants.render_variant(_png(), 400, 82)
    assert out is not None and out[1] == ".png" and out[2] == "image/png"
    assert image_variants.render_variant(b"not-an-image", 400, 82) is None


# --- process_object -------------------------------------------------------


def test_render_variant_flattens_transparency_to_jpeg():
    buf = io.BytesIO()
    Image.new("RGBA", (1600, 1200), (10, 20, 200, 128)).save(buf, format="GIF")
    out = image_variants.render_variant(buf.getvalue(), 400, 82)
    assert out is not None and out[1] == ".jpg" and out[2] == "image/jpeg"
    with Image.open(io.BytesIO(out[0])) as img:
        assert img.size == (400, 300) and img.mode == "RGB"


def test_process_object_writes_variants_and_leaves_original():
    bucket = FakeBucket()
    src = _jpeg()
    bucket.seed(ORIGINAL, src)
    result = image_variants.process_object(bucket, ORIGINAL, BUCKET)
    assert result["status"] == "processed"
    assert result["variants"] == [
        "uploads/u-9/photo_169999_0__thumb_400.jpg",
        "uploads/u-9/photo_169999_0__medium_1080.jpg",
    ]
    # Original byte-identical.
    assert bucket._objects[ORIGINAL][0] == src
    # Variants are real, smaller images with idempotency metadata.
    for vname in result["variants"]:
        payload, ctype, meta = bucket._objects[vname]
        assert ctype == "image/jpeg"
        assert len(payload) < len(src)
        with Image.open(io.BytesIO(payload)) as img:
            img.verify()
        assert meta["variant_spec"] in ("thumb_400", "medium_1080")
        assert meta["variant_of"]
    # Idempotent re-run: up-to-date variants are skipped, bytes unchanged.
    before = dict(bucket._objects)
    again = image_variants.process_object(bucket, ORIGINAL, BUCKET)
    assert again["status"] == "skipped"
    assert bucket._objects == before


def test_process_object_skips():
    bucket = FakeBucket()
    assert image_variants.process_object(bucket, ORIGINAL, BUCKET)["status"] == "skipped"  # gone
    bucket.seed("uploads/u/chat_1.jpg", _jpeg())
    r = image_variants.process_object(bucket, "uploads/u/chat_1.jpg", BUCKET)
    assert (r["status"], "profile-photo" in r["reason"]) == ("skipped", True)
    bucket.seed("uploads/u/photo_1__thumb_400.jpg", _jpeg())
    r = image_variants.process_object(bucket, "uploads/u/photo_1__thumb_400.jpg", BUCKET)
    assert (r["status"], "variant" in r["reason"]) == ("skipped", True)
    bucket.seed("uploads/u/photo_2.jpg", b"junk-bytes")
    r = image_variants.process_object(bucket, "uploads/u/photo_2.jpg", BUCKET)
    assert r["status"] == "skipped"  # undecodable: final, never retried
    bucket.seed("uploads/u/photo_3.jpg", _jpeg(100, 100))
    r = image_variants.process_object(bucket, "uploads/u/photo_3.jpg", BUCKET)
    assert r["status"] == "skipped"  # narrower than thumb: fallback covers it


# --- envelope -------------------------------------------------------------


def test_envelope_routes_finalize_and_ignores_other_events():
    bucket = FakeBucket()
    bucket.seed(ORIGINAL, _jpeg())
    r = image_variants.process_pubsub_envelope(_envelope(), bucket, BUCKET)
    assert r["status"] == "processed"
    r = image_variants.process_pubsub_envelope(
        _envelope(event="OBJECT_DELETE"), bucket, BUCKET
    )
    assert r["status"] == "skipped"
    with pytest.raises(ValueError):
        image_variants.process_pubsub_envelope({"nope": True}, bucket, BUCKET)


# --- routes ---------------------------------------------------------------


def _enabled(monkeypatch, **over):
    cfg = dataclasses.replace(
        CONFIG,
        image_variants_enabled=True,
        image_variants_push_sa="pusher@ayma-staging.iam.gserviceaccount.com",
        storage_bucket=BUCKET,
        cron_secret="cron-secret",
        **over,
    )
    monkeypatch.setattr(main, "CONFIG", cfg)
    monkeypatch.setattr(auth, "CONFIG", cfg)
    return cfg


def test_push_route_disabled_is_404(monkeypatch):
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(CONFIG, image_variants_enabled=False)
    )
    r = client.post("/internal/storage/image-finalized", json=_envelope())
    assert r.status_code == 404


def test_push_route_rejects_bad_credentials(monkeypatch):
    _enabled(monkeypatch)
    assert client.post("/internal/storage/image-finalized", json=_envelope()).status_code == 403
    monkeypatch.setattr(
        image_variants, "verify_push_token", lambda _t, _a: (_ for _ in ()).throw(ValueError("bad"))
    )
    r = client.post(
        "/internal/storage/image-finalized",
        json=_envelope(),
        headers={"Authorization": "Bearer [REDACTED]"},
    )
    assert r.status_code == 403


def test_push_route_rejects_wrong_service_account(monkeypatch):
    _enabled(monkeypatch)
    monkeypatch.setattr(image_variants, "verify_push_token", lambda _t, _a: "evil@x.iam.gserviceaccount.com")
    r = client.post(
        "/internal/storage/image-finalized",
        json=_envelope(),
        headers={"Authorization": "Bearer [REDACTED]"},
    )
    assert r.status_code == 403


def test_push_route_processes_finalize(monkeypatch):
    _enabled(monkeypatch)
    monkeypatch.setattr(
        image_variants,
        "verify_push_token",
        lambda _t, _a: "pusher@ayma-staging.iam.gserviceaccount.com",
    )
    bucket = FakeBucket()
    src = _jpeg()
    bucket.seed(ORIGINAL, src)
    monkeypatch.setattr(main, "_bucket", lambda: bucket)
    r = client.post(
        "/internal/storage/image-finalized",
        json=_envelope(),
        headers={"Authorization": "Bearer [REDACTED]"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "processed"
    assert bucket._objects[ORIGINAL][0] == src


def test_backfill_route(monkeypatch):
    _enabled(monkeypatch)
    bucket = FakeBucket()
    bucket.seed(ORIGINAL, _jpeg())
    bucket.seed("uploads/u/chat_1.jpg", _jpeg())
    monkeypatch.setattr(main, "_bucket", lambda: bucket)
    headers = {"X-Cron-Secret": "cron-secret"}
    assert client.post("/cron/image-variants-backfill").status_code == 403  # no secret
    r = client.post("/cron/image-variants-backfill", headers=headers)
    assert r.status_code == 200, r.text
    assert r.json() == {
        "scanned": 2,
        "processed": 1,
        "skipped": 1,
        "failed": [],
        "failed_count": 0,
    }
    r = client.post(
        "/cron/image-variants-backfill?prefix=verification/", headers=headers
    )
    assert r.status_code == 400
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(CONFIG, image_variants_enabled=False)
    )
    assert client.post("/cron/image-variants-backfill", headers=headers).status_code == 403


# --- variant_object_name: serve-time path derivation (no GCS call) ----------
# The backend mints variant URLs for OTHER users' photos (the client can't
# derive them); this is the pure path helper it uses.


def test_variant_object_name_ext_mapping():
    # jpg/jpeg/uppercase/no-ext all normalise to .jpg
    assert (
        image_variants.variant_object_name("uploads/u/photo_1.jpg", "thumb", 400)
        == "uploads/u/photo_1__thumb_400.jpg"
    )
    assert (
        image_variants.variant_object_name("uploads/u/photo_1.jpeg", "medium", 1080)
        == "uploads/u/photo_1__medium_1080.jpg"
    )
    assert (
        image_variants.variant_object_name("uploads/u/photo_1.JPG", "thumb", 400)
        == "uploads/u/photo_1__thumb_400.jpg"
    )
    assert (
        image_variants.variant_object_name("uploads/u/photo_1", "thumb", 400)
        == "uploads/u/photo_1__thumb_400.jpg"
    )
    # png/webp (any case) preserve their encoding
    assert (
        image_variants.variant_object_name("uploads/u/photo_1.png", "thumb", 400)
        == "uploads/u/photo_1__thumb_400.png"
    )
    assert (
        image_variants.variant_object_name("uploads/u/photo_1.WEBP", "medium", 1080)
        == "uploads/u/photo_1__medium_1080.webp"
    )
