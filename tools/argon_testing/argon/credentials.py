"""Runtime credential loading. Never writes a secret to disk or logs.

The Gemini/Computer-Use key is read from Google Secret Manager on every run
via `gcloud secrets versions access`. ADC must already be authenticated
(the harness does not handle interactive login).
"""
from __future__ import annotations

import getpass
import subprocess
import sys

import config


class CredentialError(RuntimeError):
    pass


def _access_secret(secret: str, project: str) -> str | None:
    """Return a secret's latest version, or None if it does not exist.

    Raises CredentialError only for auth/permission failures (not 'not found').
    """
    try:
        proc = subprocess.run(
            ["gcloud", "secrets", "versions", "access", "latest",
             f"--secret={secret}", f"--project={project}"],
            capture_output=True, text=True, timeout=60,
        )
    except FileNotFoundError as exc:  # gcloud not installed
        raise CredentialError("gcloud CLI not found on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise CredentialError(f"timed out reading secret '{secret}'") from exc

    if proc.returncode == 0:
        return proc.stdout.strip()

    stderr = (proc.stderr or "").strip()
    if "NOT_FOUND" in stderr or "not found" in stderr.lower():
        return None
    raise CredentialError(
        f"could not read secret '{secret}' (exit {proc.returncode}): "
        f"{stderr[-300:]}"
    )


def get_api_key() -> str:
    """Load the Gemini/Computer-Use API key from Secret Manager."""
    key = _access_secret(config.SECRET_API_KEY, config.GCP_PROJECT)
    if not key:
        raise CredentialError(
            f"secret '{config.SECRET_API_KEY}' not found in project "
            f"'{config.GCP_PROJECT}'"
        )
    return key


def get_test_password(prompt_if_missing: bool = True) -> str | None:
    """Load the seeded test-account password.

    Order: Secret Manager, then an interactive prompt (never stored). Returns
    None if unavailable and prompting is disabled or skipped.
    """
    pw = _access_secret(config.SECRET_TEST_PASSWORD, config.GCP_PROJECT)
    if pw:
        return pw
    if prompt_if_missing and sys.stdin.isatty():
        print(
            f"[argon] Secret '{config.SECRET_TEST_PASSWORD}' not found. "
            "Enter the test-account password (not stored):",
            file=sys.stderr,
        )
        entered = getpass.getpass("password: ")
        return entered or None
    return None
