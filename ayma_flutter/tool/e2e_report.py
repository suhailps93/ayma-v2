#!/usr/bin/env python3
"""Assemble build/e2e/REPORT.md from a flutter-drive run log + screenshots.

Usage: e2e_report.py <run.log> <screenshots_dir> <out_report.md>

Parses the streaming `E2E_RESULT <bug> PASS|FAIL <detail>` markers the harness
prints and embeds the per-behaviour screenshot captured by the driver.
"""
import base64
import os
import re
import sys
from datetime import datetime, timezone

# Behaviour letter -> human description (the 8 fixes shipped in build 2237).
BUGS = {
    "B": "A dealbreaker profile appears in Explore (not hidden) and its report shows 0% with the \"Why this is 0%\" reasons",
    "C": 'Web research never-run shows "No web research yet" + "Run web search" (no error); tapping it starts the search',
    "D": 'A NON-mutual pair is presented as a compatibility report ("Match report"), with no false "matched" claim',
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
    "GATES": "Bypass viewer (demo-e2e-viewer) sees valid + orientation/location dealbreaker profiles (not hidden); age-over-max filtered by the saved age range",
    "HIDDEN": "A demo/judge account (Daniel) has a CLEAN Explore — demo-edge-* fixtures hidden, curated shown (judge guarantee)",
    "NOPHOTO": "A 0-photo but valid profile appears in Explore and its report opens",
    "ZERO": "A hard-dealbreaker pair's report scores 0% and lists the dealbreaker reason(s)",
    "MATCH": 'A MUTUAL pair is recognised (report opens + Messages shows "You matched — say hello")',
    "GIF": "A GIF message renders as an inline animated-gif bubble in a DM thread (§6.6)",
    "WEBRESEARCH": 'The web-research icon opens the report page ("No web research yet" + "Run web search") and starts no search on tap',
    "AUTH": "Signed-out boot lands on the sign-in / welcome screen",
    "OFFLINE": 'Offline splash shows "Couldn\'t connect" + Retry (adb-driven)',
    "RECOVER": "Network restored + Retry recovers to the signed-in shell",
}
EXTRA_ORDER = ["GATES", "HIDDEN", "NOPHOTO", "ZERO", "MATCH", "WEBRESEARCH", "GIF",
               "AUTH", "OFFLINE", "RECOVER"]


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

    # Self-contained HTML (screenshots base64-embedded) for a shareable link.
    html_path = os.path.join(os.path.dirname(out_path), "REPORT.html")
    rows = []
    for key in ORDER + extra_keys:
        status, detail = results.get(key, ("NOT RUN", ""))
        pngs = []
        for name in (key, f"{key}_FAIL"):
            p = os.path.join(shots_dir, f"{name}.png")
            if os.path.exists(p):
                pngs.append(p)
        rows.append((key, desc.get(key, key), status, detail, pngs))
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(_render_html(when, passed, failed, rows))

    print(f"Wrote {out_path} + {html_path} ({passed} pass / {failed} fail)")
    return 1 if failed else 0


def _data_uri(path: str) -> str:
    with open(path, "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode("ascii")


def _render_html(when: str, passed: int, failed: int, rows) -> str:
    import html as _h

    def esc(s: str) -> str:
        return _h.escape(str(s))

    cards = []
    for key, desc, status, detail, pngs in rows:
        pill = {"PASS": "pass", "FAIL": "fail"}.get(status, "skip")
        label = {"PASS": "PASS", "FAIL": "FAIL"}.get(status, "NOT RUN")
        imgs = "".join(
            f'<img loading="lazy" alt="{esc(key)}" src="{_data_uri(p)}">'
            for p in pngs
        ) or '<div class="noshot">no screenshot captured</div>'
        cards.append(
            f'''<section class="card {pill}">
      <header><span class="key">{esc(key)}</span>
        <span class="pill {pill}">{label}</span></header>
      <p class="desc">{esc(desc)}</p>
      <p class="detail">{esc(detail)}</p>
      <div class="shots">{imgs}</div>
    </section>'''
        )

    total = len(rows)
    summary = (f'{passed} passed, {failed} failed'
               f' &middot; {total} scenarios')
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ayma E2E report</title>
<style>
  :root {{ color-scheme: light dark;
    --bg:#f6f6f4; --fg:#1a1a18; --mute:#6b6b66; --card:#ffffff; --line:#e3e3df;
    --pass:#1a7f4b; --passbg:#e4f4ea; --fail:#b42318; --failbg:#fbe9e7;
    --skip:#6b6b66; --skipbg:#ececea; }}
  @media (prefers-color-scheme: dark) {{ :root {{
    --bg:#131210; --fg:#ece9e3; --mute:#9a968d; --card:#1d1b18; --line:#2e2b27;
    --pass:#5fd39a; --passbg:#14301f; --fail:#f1a79c; --failbg:#3a1714;
    --skip:#9a968d; --skipbg:#26241f; }} }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg);
    font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    padding:24px 16px; }}
  .wrap {{ max-width:960px; margin:0 auto; }}
  h1 {{ font-size:22px; margin:0 0 4px; }}
  .meta {{ color:var(--mute); margin:0 0 20px; }}
  .totals {{ font-weight:600; }}
  .grid {{ display:grid; gap:16px; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); }}
  .card {{ background:var(--card); border:1px solid var(--line); border-radius:14px;
    padding:14px; }}
  .card.fail {{ border-color:var(--fail); }}
  header {{ display:flex; align-items:center; justify-content:space-between; gap:8px; }}
  .key {{ font-weight:700; letter-spacing:.02em; }}
  .pill {{ font-size:12px; font-weight:700; padding:3px 9px; border-radius:999px; }}
  .pill.pass {{ color:var(--pass); background:var(--passbg); }}
  .pill.fail {{ color:var(--fail); background:var(--failbg); }}
  .pill.skip {{ color:var(--skip); background:var(--skipbg); }}
  .desc {{ margin:8px 0 2px; font-weight:600; }}
  .detail {{ margin:0 0 10px; color:var(--mute); font-size:13.5px; }}
  .shots {{ display:flex; flex-wrap:wrap; gap:8px; }}
  .shots img {{ width:100%; max-width:220px; border:1px solid var(--line);
    border-radius:8px; background:#000; }}
  .noshot {{ color:var(--mute); font-size:13px; font-style:italic; }}
</style></head>
<body><div class="wrap">
  <h1>Ayma E2E regression report</h1>
  <p class="meta">Generated {esc(when)} &middot; real device, live backend</p>
  <p class="totals">{summary}</p>
  <div class="grid">
    {"".join(cards)}
  </div>
</div></body></html>
'''


if __name__ == "__main__":
    sys.exit(main())
