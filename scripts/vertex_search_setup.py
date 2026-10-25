#!/usr/bin/env python3
"""Create / sync the Vertex AI Search (Discovery Engine) public-website data store.

Idempotent. Uses the caller's gcloud identity (no credentials in the repo).
Usage: python3 scripts/vertex_search_setup.py [--project ayma-ai] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DATA_STORE_ID = "ayma-public-web"
ENGINE_ID = "ayma-public-web-engine"
DOMAINS = Path(__file__).with_name("vertex_search_domains.txt")
MAX_PATTERNS = 50


def _token() -> str:
    return subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True
    ).strip()


def _call(method: str, url: str, project: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {_token()}",
            "x-goog-user-project": project,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        err = json.loads(exc.read() or b"{}").get("error", {"code": exc.code})
        return {"error": err}


def patterns() -> list[str]:
    out = [
        ln.strip()
        for ln in DOMAINS.read_text().splitlines()
        if ln.strip() and not ln.startswith("#")
    ]
    if len(out) > MAX_PATTERNS:
        raise SystemExit(f"{len(out)} patterns > {MAX_PATTERNS}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="ayma-ai")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    pats = patterns()
    if args.dry_run:
        print(json.dumps(pats, indent=1))
        return 0
    base = (
        "https://discoveryengine.googleapis.com/v1/projects/"
        f"{args.project}/locations/global/collections/default_collection"
    )
    store = f"{base}/dataStores/{DATA_STORE_ID}"
    if "error" in _call("GET", store, args.project):
        created = _call(
            "POST",
            f"{base}/dataStores?dataStoreId={DATA_STORE_ID}",
            args.project,
            {
                "displayName": "Ayma public web (deep-dive discovery)",
                "industryVertical": "GENERIC",
                "solutionTypes": ["SOLUTION_TYPE_SEARCH"],
                "contentConfig": "PUBLIC_WEBSITE",
            },
        )
        print("create:", json.dumps(created)[:300])
    if "error" in _call("GET", f"{base}/engines/{ENGINE_ID}", args.project):
        # Website search needs the Enterprise tier, which exists only on an engine.
        created = _call(
            "POST",
            f"{base}/engines?engineId={ENGINE_ID}",
            args.project,
            {
                "displayName": "Ayma public web search",
                "solutionType": "SOLUTION_TYPE_SEARCH",
                "industryVertical": "GENERIC",
                "dataStoreIds": [DATA_STORE_ID],
                "searchEngineConfig": {"searchTier": "SEARCH_TIER_ENTERPRISE"},
                "commonConfig": {"companyName": "Ayma"},
            },
        )
        print("engine:", json.dumps(created)[:300])
    engine = f"{store}/siteSearchEngine"
    have: set[str] = set()
    token = ""
    while True:
        listed = _call(
            "GET",
            f"{engine}/targetSites?pageSize=100&pageToken={token}",
            args.project,
        )
        have |= {t.get("rootDomainUri") for t in listed.get("targetSites", [])}
        token = listed.get("nextPageToken", "")
        if not token:
            break
    missing = [
        p for p in pats if ".".join(p.split("/")[0].split(".")[-2:]) not in have
    ]
    for i in range(0, len(missing), 20):
        chunk = missing[i : i + 20]
        res = _call(
            "POST",
            f"{engine}/targetSites:batchCreate",
            args.project,
            {
                "requests": [
                    {
                        "targetSite": {
                            "providedUriPattern": p,
                            "type": "INCLUDE",
                            "exactMatch": False,
                        },
                    }
                    for p in chunk
                ]
            },
        )
        print("batchCreate:", json.dumps(res)[:600])
    print(f"target sites: {len(have)} existing, {len(missing)} requested")
    return 0


if __name__ == "__main__":
    sys.exit(main())
