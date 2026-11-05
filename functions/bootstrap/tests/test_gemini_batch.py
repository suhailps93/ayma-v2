"""Gemini Batch API — DISABLED (founder rule 2026-11-04): submit/poll raise
instead of calling Vertex, and the cron sweep reports ``disabled``."""

import pytest

import gemini_batch
import llm_routing


def test_submit_json_batch_is_disabled():
    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        gemini_batch.submit_json_batch(
            ["a"], "sys", {"type": "object"}, job_tag="x"
        )


def test_poll_json_batch_is_disabled():
    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        gemini_batch.poll_json_batch("batches/fake-1")


def test_batch_submission_shape_is_kept():
    sub = gemini_batch.BatchSubmission(
        job_name="batches/fake-1", dest_prefix="gs://b/dest", count=2
    )
    assert (sub.job_name, sub.dest_prefix, sub.count) == (
        "batches/fake-1", "gs://b/dest", 2)
