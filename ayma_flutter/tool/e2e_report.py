#!/usr/bin/env python3
"""Assemble build/e2e/REPORT.md from a flutter-drive run log + screenshots.

Usage: e2e_report.py <run.log> <screenshots_dir> <out_report.md>

Parses the streaming `E2E_RESULT <bug> PASS|FAIL <detail>` markers the harness
prints and embeds the per-behaviour screenshot captured by the driver.
"""
import os
import re
import sys
from datetime import datetime, timezone

# Behaviour letter -> human description (the 8 fixes shipped in build 2237).
BUGS = {
    "B": "Explore excludes profiles violating gender/age/location dealbreakers; hard-dealbreaker report scores 0%",
    "C": 'Web research shows "No web research yet" + "Run report" when never run (error+Retry only on real failure)',
    "D": 'Non-mutual pair reads "Compatibility"; only a mutual like reads "Match"',
    "E": "Practice personas (demo_practice_*) never appear in Explore",
    "F": "Re-opening an already-opened report is instant (cache); Recalculate forces a recompute",
    "G": "Taste card only shows domains BOTH people stated as shared",
    "H": "Compatibility report shows the FULL dimension breakdown, not a score-only lite doc",
    "P": 'Share "Send to a user" sheet: profile photos + per-row Send + search + matched-users-first',
}
ORDER = ["B", "C", "D", "E", "F", "G", "H", "P"]

# Corner-case scenarios beyond the 8 shipped fixes (seeded demo-edge-* fixtures,
# signed-out auth, host-driven offline). Any result key not in BUGS or here is
# still rendered generically.
EXTRA = {
    "GATES": "Explore includes valid edge profiles and excludes hard-dealbreaker ones (age/orientation/location)",
    "NOPHOTO": "A 0-photo but valid profile appears in Explore and its report opens",
    "ZERO": "A hard-dealbreaker pair's report scores 0%",
    "MATCH": 'A mutual-like pair\'s report AppBar reads "Match" (vs non-mutual "Compatibility")',
    "AUTH": "Signed-out boot lands on the sign-in / welcome screen",
    "OFFLINE": 'Offline splash shows "Couldn\'t connect" + Retry (adb-driven)',
    "RECOVER": "Network restored + Retry recovers to the signed-in shell",
}
EXTRA_ORDER = ["GATES", "NOPHOTO", "ZERO", "MATCH", "AUTH", "OFFLINE", "RECOVER"]


def main() -> int:
    log_path, shots_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    log = ""
    if os.path.exists(log_path):
        with open(log_path, encoding="utf-8", errors="ignore") as f:
            log = f.read()

    results: dict[str, tuple[str, str]] = {}
    for letter, status, detail in re.findall(
        r"E2E_RESULT (\w+) (PASS|FAIL) (.*)", log
    ):
        results[letter] = (status, detail.strip())

    def shot_for(letter: str) -> list[str]:
        out = []
        for name in (letter, f"{letter}_FAIL"):
            p = os.path.join(shots_dir, f"{name}.png")
            if os.path.exists(p):
                out.append(os.path.relpath(p, os.path.dirname(out_path)))
        return out

    passed = sum(1 for k in results if results[k][0] == "PASS")
    failed = sum(1 for k in results if results[k][0] == "FAIL")
    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    def badge(status: str) -> str:
        return {"PASS": "✅ PASS", "FAIL": "❌ FAIL"}.get(status, "➖ NOT RUN")

    lines = [
        "# Ayma E2E regression report",
        "",
        f"_Generated {when} — driven on a real device against the live backend._",
        "",
        f"**{passed} passed, {failed} failed** "
        f"(of {len(BUGS)} shipped-fix behaviours + {len(EXTRA)} corner cases).",
        "",
        "## Shipped-fix behaviours (build 2237)",
        "",
        "| Bug | Behaviour | Result |",
        "|-----|-----------|--------|",
    ]
    for letter in ORDER:
        st = results.get(letter, ("NOT RUN", ""))[0]
        lines.append(f"| {letter} | {BUGS[letter]} | {badge(st)} |")
    lines.append("")

    # Corner-case scenarios table (only those that actually ran, plus any
    # unknown keys the harness emitted).
    extra_keys = [k for k in EXTRA_ORDER if k in results]
    extra_keys += [k for k in results if k not in BUGS and k not in EXTRA]
    if extra_keys:
        lines += [
            "## Corner-case scenarios",
            "",
            "| Scenario | Checks | Result |",
            "|----------|--------|--------|",
        ]
        for k in extra_keys:
            st = results.get(k, ("NOT RUN", ""))[0]
            lines.append(f"| {k} | {EXTRA.get(k, k)} | {badge(st)} |")
        lines.append("")

    # Per-scenario detail + screenshots.
    lines += ["## Details", ""]
    desc = {**BUGS, **EXTRA}
    for key in ORDER + extra_keys:
        status, detail = results.get(key, ("NOT RUN", ""))
        lines.append(f"### {key} — {desc.get(key, key)}")
        lines.append("")
        lines.append(f"**{badge(status)}**" + (f" — {detail}" if detail else ""))
        lines.append("")
        shots = shot_for(key)
        if shots:
            for s in shots:
                lines.append(f"![{key}]({s})")
                lines.append("")
        else:
            lines.append("_(no screenshot captured)_")
            lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {out_path} ({passed} pass / {failed} fail)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
