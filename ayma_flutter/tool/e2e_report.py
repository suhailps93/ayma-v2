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
    total = len(BUGS)
    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = [
        "# Ayma E2E regression report",
        "",
        f"_Generated {when} — build 2237 behaviours, driven on a real device "
        f"against the live backend._",
        "",
        f"**{passed} passed, {failed} failed, "
        f"{total - len(results)} not run** of {total}.",
        "",
        "| Bug | Behaviour | Result |",
        "|-----|-----------|--------|",
    ]
    for letter in ORDER:
        status = results.get(letter, ("NOT RUN", ""))[0]
        badge = {"PASS": "✅ PASS", "FAIL": "❌ FAIL"}.get(status, "➖ NOT RUN")
        lines.append(f"| {letter} | {BUGS[letter]} | {badge} |")
    lines.append("")

    for letter in ORDER:
        status, detail = results.get(letter, ("NOT RUN", ""))
        badge = {"PASS": "✅ PASS", "FAIL": "❌ FAIL"}.get(status, "➖ NOT RUN")
        lines.append(f"## {letter} — {BUGS[letter]}")
        lines.append("")
        lines.append(f"**{badge}**" + (f" — {detail}" if detail else ""))
        lines.append("")
        shots = shot_for(letter)
        if shots:
            for s in shots:
                lines.append(f"![{letter}]({s})")
                lines.append("")
        else:
            lines.append("_(no screenshot captured)_")
            lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {out_path} ({passed} pass / {failed} fail / "
          f"{total - len(results)} not run)")
    return 1 if failed or len(results) < total else 0


if __name__ == "__main__":
    sys.exit(main())
