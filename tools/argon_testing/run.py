#!/usr/bin/env python3
"""Argon — Gemini Computer-Use harness for driving an Android emulator.

Usage:
    python run.py --list
    python run.py --scenario login
    python run.py --scenario open_models --device emulator-5554 --max-steps 20

The Gemini credential is read from Google Secret Manager at runtime; nothing is
hardcoded. See README.md.
"""
from __future__ import annotations

import argparse
import os
import sys

# Make the tool dir importable (config.py + argon package).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import yaml  # noqa: E402

import config  # noqa: E402
from argon import credentials  # noqa: E402
from argon.device import Device  # noqa: E402
from argon import loop, report  # noqa: E402


def list_scenarios() -> list[str]:
    if not os.path.isdir(config.SCENARIOS_DIR):
        return []
    return sorted(
        os.path.splitext(f)[0]
        for f in os.listdir(config.SCENARIOS_DIR)
        if f.endswith((".yaml", ".yml"))
    )


def load_scenario(name: str) -> dict:
    for ext in (".yaml", ".yml"):
        path = os.path.join(config.SCENARIOS_DIR, name + ext)
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                data = yaml.safe_load(fh) or {}
            data.setdefault("name", name)
            return data
    raise SystemExit(f"[argon] scenario '{name}' not found in {config.SCENARIOS_DIR}")


def resolve_device(requested: str | None) -> Device:
    serials = Device.list_serials()
    if requested:
        if requested not in serials:
            raise SystemExit(
                f"[argon] device '{requested}' not connected. "
                f"Connected: {serials or 'none'}")
        return Device(requested)
    if not serials:
        raise SystemExit("[argon] no connected devices (adb devices is empty)")
    if len(serials) > 1:
        print(f"[argon] multiple devices {serials}; using {serials[0]}. "
              "Pass --device to choose.", file=sys.stderr)
    return Device(serials[0])


def resolve_credentials(scenario: dict) -> tuple[dict, list[str]]:
    """Fill a scenario's template values. Returns (values, secrets_to_redact)."""
    creds = scenario.get("credentials", {}) or {}
    values: dict[str, str] = {}
    secrets: list[str] = []
    for key, val in creds.items():
        if isinstance(val, str) and val.strip().upper() == "FROM_SECRET_MANAGER":
            if "password" in key.lower():
                pw = credentials.get_test_password()
                if not pw:
                    raise SystemExit(
                        f"[argon] scenario needs '{key}' but secret "
                        f"'{config.SECRET_TEST_PASSWORD}' is absent and no "
                        "interactive prompt available. See README.")
                values[key] = pw
                secrets.append(pw)
            else:
                raise SystemExit(
                    f"[argon] no Secret-Manager mapping for '{key}'")
        else:
            values[key] = str(val)
    return values, secrets


def main() -> int:
    ap = argparse.ArgumentParser(description="Argon Computer-Use emulator harness")
    ap.add_argument("--scenario", help="scenario name (see --list)")
    ap.add_argument("--device", help="ADB serial (default: first connected)")
    ap.add_argument("--max-steps", type=int, default=config.DEFAULT_MAX_STEPS)
    ap.add_argument("--list", action="store_true", help="list scenarios and exit")
    ap.add_argument("--no-safety-ack", action="store_true",
                    help="halt instead of auto-acknowledging safety gates")
    args = ap.parse_args()

    if args.list or not args.scenario:
        print("Available scenarios:")
        for s in list_scenarios():
            print(f"  - {s}")
        if not args.scenario:
            return 0
        return 0

    scenario = load_scenario(args.scenario)
    values, secrets = resolve_credentials(scenario)

    goal = (scenario.get("goal", "") or "").format(**values)
    success = (scenario.get("success_condition", "") or "").format(**values)

    device = resolve_device(args.device)
    device_info = device.describe()
    print(f"[argon] device: {device_info.get('serial')} "
          f"({device_info.get('model')}, {device_info.get('resolution')})")
    print(f"[argon] scenario: {scenario['name']} | max_steps={args.max_steps}")

    result = loop.run_scenario(
        device, goal, success, max_steps=args.max_steps,
        auto_ack_safety=not args.no_safety_ack)

    scenario_meta = {
        "description": scenario.get("description", ""),
        "goal": goal,
        "success_condition": success,
    }
    out = report.write_report(
        scenario["name"], scenario_meta, device_info, result, secrets)

    print(f"[argon] verdict: {'PASS' if out['passed'] else 'FAIL'} "
          f"({result.stopped_reason})")
    if result.error:
        # Error text is already secret-scrubbed inside the report; print as-is
        # only after the same redaction pass.
        safe = result.error
        for s in secrets:
            safe = safe.replace(s, "<REDACTED>")
        print(f"[argon] note: {safe}", file=sys.stderr)
    print(f"[argon] report: {out['report']}")
    if out["gif"]:
        print(f"[argon] gif:    {out['gif']}")
    return 0 if out["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
