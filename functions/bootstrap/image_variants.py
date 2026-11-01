"""Cloud-side profile-photo variants (Perf Phase 2 PREP, staging-only).

Founder directive (binding): ALL image compression / variant generation
happens IN THE CLOUD, asynchronously after upload. The client upload path
gains no compression step and no latency — users upload the original exactly
as today.

How it fits together
--------------------
1. The client uploads a profile photo to the staging bucket exactly as
   today (``uploads/{uid}/profile_*``, ``photo_*`` or ``ig_*``).
2. A GCS ``OBJECT_FINALIZE`` notification on the staging bucket (prefix
   ``uploads/``, staging project only) publishes to a Pub/Sub topic, whose
   push subscription POSTs the envelope to
   ``POST /internal/storage/image-finalized`` on ``ayma-api-staging``.
3. This module downloads the original, renders ``thumb`` (~400px wide) and
   ``medium`` (~1080px wide) variants, and stores them alongside the
   original. The original object is never modified.
4. ``POST /cron/image-variants-backfill`` (``X-Cron-Secret`` authed, manual
   trigger per the no-staging-cron convention) re-runs generation over a
   prefix for backfill / recovery; generation is idempotent.

Naming convention (the contract future client work reads against)
---------------------------------------------------------------
Original:  ``uploads/{uid}/photo_169999_0.jpg``
Variants:  ``uploads/{uid}/photo_169999_0__thumb_400.jpg``
           ``uploads/{uid}/photo_169999_0__medium_1080.jpg``

i.e. ``{stem}__{spec}_{width}px{ext}`` in the SAME directory as the original.
``ext`` follows the variant's output encoding (JPEG/PNG/WebP preserved from
the source; anything else normalises to ``.jpg``). Variants inherit the
``uploads/{uid}/`` storage rules (owner-only read) automatically.

Fallback contract: surfaces MUST treat variants as optional. Until a variant
exists (or when generation is skipped — tiny originals, undecodable bytes),
clients keep using the original URL. A missing variant is never an error.

Loop safety: variant objects themselves emit ``OBJECT_FINALIZE`` on write.
Any object whose name matches the variant pattern is skipped, so generation
can never re-trigger itself.

Idempotency: each variant blob carries ``variant_of=<source md5>`` metadata.
A re-run whose source bytes are unchanged skips the re-render. Overwrites
are byte-identical for identical input.

Staging-only gating (defence in depth — this code must be inert on prod):
  * ``IMAGE_VARIANTS_ENABLED=true`` env (set ONLY on ``ayma-api-staging``);
    both routes refuse when unset.
  * The push route verifies the Pub/Sub OIDC token AND pins the ``email``
    claim to ``IMAGE_VARIANTS_PUSH_SA`` (fail-closed when unset).
  * The envelope's bucket must equal ``CONFIG.storage_bucket``.
  * Only ``OBJECT_FINALIZE`` on profile-photo paths is processed; everything
    else is acked-and-skipped (HTTP 200) so Pub/Sub never redelivers it.
    Only transient GCS/network failures raise :class:`TransientError`
    (HTTP 500 → redeliver, safe because generation is idempotent).
"""

from __future__ import annotations

import io
import logging
import re
from dataclasses import dataclass

from PIL import Image, ImageOps

logger = logging.getLogger(__name__)

# Profile-photo basenames the clients actually write (see photo_service.dart,
# profile_service.dart, instagram.py): grid photos, preboarding photos, and IG
# imports (which land on the profile grid via the same pipeline). Chat
# (``chat_*``), DM (``dm/...``) and verification selfies (``verification/``)
# are deliberately out of scope for this chunk.
PROFILE_PREFIXES = ("profile_", "photo_", "ig_")

# (spec name, target width px, jpeg quality)
VARIANT_SPECS: tuple[tuple[str, int, int], ...] = (
    ("thumb", 400, 82),
    ("medium", 1080, 85),
)

_VARIANT_RE = re.compile(r"__(thumb_400|medium_1080)\.[A-Za-z0-9]+$")
_PROFILE_PATH_RE = re.compile(r"^uploads/[^/]+/[^/]+$")

# Extensions we will at least TRY to decode even when the content-type is
# missing/generic (Firebase sometimes stores octet-stream). Pillow is the
# final arbiter — undecodable bytes are skipped, never retried.
_IMAGE_EXTENSIONS = frozenset(
    {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tiff", ".tif"}
)

# Safety cap: refuse to pull objects bigger than this into the 512Mi
# Cloud Run container. Phone photos never come close.
MAX_INPUT_BYTES = 25 * 1024 * 1024


class TransientError(Exception):
    """A GCS / network failure worth redelivering (the push route maps this
    to HTTP 500; generation is idempotent so a retry is safe)."""


@dataclass(frozen=True)
class GateDecision:
    process: bool
    reason: str


def variant_name(object_name: str, spec: str, width: int, extension: str) -> str:
    """``uploads/u/photo_1.jpg`` → ``uploads/u/photo_1__thumb_400.jpg``."""
    stem, _dot, _old_ext = object_name.rpartition(".")
    base = stem if _dot else object_name
    return f"{base}__{spec}_{width}{extension}"


def is_variant_path(object_name: str) -> bool:
    """True for objects this module generated (loop guard)."""
    return _VARIANT_RE.search(object_name) is not None


def is_profile_photo_path(object_name: str) -> bool:
    """True for single-level ``uploads/{uid}/{profile,photo,ig}_*`` paths."""
    if not _PROFILE_PATH_RE.match(object_name):
        return False
    basename = object_name.rsplit("/", 1)[1]
    return basename.startswith(PROFILE_PREFIXES)


def should_process(
    bucket_name: str,
    object_name: str,
    content_type: str | None,
    expected_bucket: str,
) -> GateDecision:
    """Fail-closed gate: only staging-bucket profile photos pass."""
    if bucket_name != expected_bucket:
        return GateDecision(False, f"bucket {bucket_name!r} != expected")
    if is_variant_path(object_name):
        return GateDecision(False, "already a variant (loop guard)")
    if not is_profile_photo_path(object_name):
        return GateDecision(False, "not a profile-photo path")
    ctype = (content_type or "").lower()
    if ctype.startswith("image/"):
        return GateDecision(True, "image content-type")
    ext = "." + object_name.rpartition(".")[2].lower() if "." in object_name else ""
    if ext in _IMAGE_EXTENSIONS:
        return GateDecision(True, "image extension (content-type %r)" % (content_type,))
    return GateDecision(False, f"non-image content-type {content_type!r}")


def _output_format(source_format: str | None) -> tuple[str, str, str]:
    """(PIL format, file extension, content-type) for a variant."""
    fmt = (source_format or "").upper()
    if fmt == "PNG":
        return ("PNG", ".png", "image/png")
    if fmt == "WEBP":
        return ("WEBP", ".webp", "image/webp")
    return ("JPEG", ".jpg", "image/jpeg")


def render_variant(image_bytes: bytes, target_width: int, quality: int) -> tuple[bytes, str, str] | None:
    """Render one variant. Returns ``(bytes, extension, content_type)``, or
    ``None`` when the source is undecodable or already narrower than the
    target (no upscaling — the fallback contract covers it)."""
    try:
        with Image.open(io.BytesIO(image_bytes)) as img:
            source_format = img.format  # exif_transpose returns a copy w/o format
            img = ImageOps.exif_transpose(img)
            if img.width <= target_width:
                return None
            scale = target_width / img.width
            new_size = (target_width, max(1, round(img.height * scale)))
            resized = img.resize(new_size, Image.LANCZOS)
            fmt, ext, ctype = _output_format(source_format)
            if fmt == "JPEG" and resized.mode in ("RGBA", "LA", "P"):
                bg = Image.new("RGB", resized.size, (255, 255, 255))
                if resized.mode == "P":
                    resized = resized.convert("RGBA")
                if "A" in resized.getbands():
                    bg.paste(resized, mask=resized.split()[-1])
                    resized = bg
                else:
                    resized = resized.convert("RGB")
            elif fmt == "JPEG" and resized.mode != "RGB":
                resized = resized.convert("RGB")
            buf = io.BytesIO()
            save_kwargs: dict = {"format": fmt, "optimize": True}
            if fmt in ("JPEG", "WEBP"):
                save_kwargs["quality"] = quality
            resized.save(buf, **save_kwargs)
            return (buf.getvalue(), ext, ctype)
    except Exception:
        logger.warning("variant render failed (undecodable source)", exc_info=True)
        return None


def _is_not_found(exc: BaseException) -> bool:
    return exc.__class__.__name__ == "NotFound"


def process_object(bucket, object_name: str, expected_bucket: str) -> dict:
    """Generate missing variants for one object. Never mutates the original.

    ``bucket`` is a GCS bucket handle (duck-typed: ``.blob(name)`` with
    ``reload/download_as_bytes/exists/upload_from_string`` + ``name``).
    Returns a JSON-able result dict with ``status``: ``processed``,
    ``skipped`` or ``failed``. Raises :class:`TransientError` on GCS /
    network failures (safe to retry); every other outcome is final.
    """
    bucket_name = getattr(bucket, "name", expected_bucket)
    blob = bucket.blob(object_name)
    try:
        blob.reload()
    except Exception as exc:
        if _is_not_found(exc):
            return {"status": "skipped", "reason": "object gone (404 on reload)"}
        raise TransientError(f"reload failed for {object_name}: {exc}") from exc

    decision = should_process(
        bucket_name, object_name, getattr(blob, "content_type", None), expected_bucket
    )
    if not decision.process:
        return {"status": "skipped", "reason": decision.reason}

    size = getattr(blob, "size", 0) or 0
    if size > MAX_INPUT_BYTES:
        return {"status": "skipped", "reason": f"too large ({size} bytes)"}
    source_md5 = getattr(blob, "md5_hash", None)

    try:
        original = blob.download_as_bytes()
    except Exception as exc:
        if _is_not_found(exc):
            return {"status": "skipped", "reason": "object gone (404 on download)"}
        raise TransientError(f"download failed for {object_name}: {exc}") from exc

    made: list[str] = []
    skipped: list[str] = []
    for spec, width, quality in VARIANT_SPECS:
        rendered = render_variant(original, width, quality)
        if rendered is None:
            skipped.append(f"{spec}: source narrower than {width}px or undecodable")
            continue
        payload, ext, ctype = rendered
        vname = variant_name(object_name, spec, width, ext)
        vblob = bucket.blob(vname)
        try:
            if source_md5:
                try:
                    vblob.reload()
                    meta = getattr(vblob, "metadata", None) or {}
                    if meta.get("variant_of") == source_md5:
                        skipped.append(f"{spec}: up to date")
                        continue
                except Exception as exc:
                    if not _is_not_found(exc):
                        raise
            vblob.upload_from_string(
                payload,
                content_type=ctype,
            )
            try:
                vblob.metadata = {
                    "variant_of": source_md5 or "",
                    "variant_spec": f"{spec}_{width}",
                }
                vblob.patch()
            except Exception:
                logger.warning("variant metadata patch failed for %s", vname)
            made.append(vname)
        except TransientError:
            raise
        except Exception as exc:
            raise TransientError(f"upload failed for {vname}: {exc}") from exc

    if not made and not skipped:
        return {"status": "skipped", "reason": "no variant applicable"}
    if not made:
        return {"status": "skipped", "reason": "; ".join(skipped)}
    return {"status": "processed", "variants": made, "skipped": skipped}


def process_pubsub_envelope(envelope: dict, bucket, expected_bucket: str) -> dict:
    """Handle one Pub/Sub push envelope carrying a GCS notification.

    Returns a JSON-able result (the route answers HTTP 200 — ack). Raises
    :class:`TransientError` for retryable GCS failures, ``ValueError`` for a
    malformed envelope (the route answers HTTP 400 — drop).
    """
    if not isinstance(envelope, dict):
        raise ValueError("envelope must be an object")
    message = envelope.get("message")
    if not isinstance(message, dict):
        raise ValueError("envelope has no message")
    attrs = message.get("attributes") or {}
    if not isinstance(attrs, dict):
        raise ValueError("message has no attributes")
    event_type = attrs.get("eventType", "")
    if event_type and event_type != "OBJECT_FINALIZE":
        return {"status": "skipped", "reason": f"event {event_type} ignored"}
    bucket_id = attrs.get("bucketId", "")
    object_id = attrs.get("objectId", "")
    if not bucket_id or not object_id:
        raise ValueError("notification missing bucketId/objectId")
    return process_object(bucket, object_id, expected_bucket) | {
        "bucket": bucket_id,
        "object": object_id,
    }


def verify_push_token(token: str, audience: str) -> str:
    """Verify a Pub/Sub push OIDC token. Returns the ``email`` claim.

    Raises ``ValueError`` when the token is invalid (the route answers
    HTTP 403). The caller must additionally pin the email to the expected
    push service account — any Google-signed token with this audience would
    otherwise pass.
    """
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token

    try:
        claims = id_token.verify_oauth2_token(
            token, google_requests.Request(), audience=audience
        )
    except Exception as exc:
        raise ValueError(f"bad OIDC token: {exc}") from exc
    email = str(claims.get("email", ""))
    if not email:
        raise ValueError("OIDC token has no email claim")
    return email
