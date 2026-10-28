"""Markdown + annotated-GIF report writer for a scenario run."""
from __future__ import annotations

import os
from datetime import datetime, timezone

import imageio.v2 as imageio
from PIL import Image, ImageDraw

import config
from argon.loop import RunResult


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _redact(text: str, secrets: list[str]) -> str:
    out = text or ""
    for s in secrets:
        if s:
            out = out.replace(s, "<REDACTED>")
    return out


def _annotate(img: Image.Image, tap_xy, label: str) -> Image.Image:
    """Draw a marker at the tap point and a caption band."""
    frame = img.copy()
    draw = ImageDraw.Draw(frame)
    if tap_xy:
        x, y = tap_xy
        r = max(14, img.width // 40)
        draw.ellipse([x - r, y - r, x + r, y + r], outline=(255, 40, 40), width=5)
        draw.line([x - r, y, x + r, y], fill=(255, 40, 40), width=3)
        draw.line([x, y - r, x, y + r], fill=(255, 40, 40), width=3)
    if label:
        band_h = max(28, img.height // 22)
        draw.rectangle([0, 0, img.width, band_h], fill=(0, 0, 0))
        draw.text((8, 6), label[:90], fill=(255, 255, 255))
    return frame


def _downscale(img: Image.Image, long_edge: int | None) -> Image.Image:
    if not long_edge:
        return img
    w, h = img.size
    scale = long_edge / max(w, h)
    if scale >= 1:
        return img
    return img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)


def write_report(scenario_name: str, scenario_meta: dict, device_info: dict,
                 result: RunResult, secrets: list[str]) -> dict:
    """Write the GIF, per-step thumbnails and the markdown report.

    Returns {'report': path, 'gif': path, 'passed': bool}.
    """
    os.makedirs(config.REPORTS_DIR, exist_ok=True)
    ts = _ts()
    base = f"{scenario_name}-{ts}"
    gif_path = os.path.join(config.REPORTS_DIR, f"{base}.gif")
    frames_dir = os.path.join(config.REPORTS_DIR, f"{base}_frames")
    os.makedirs(frames_dir, exist_ok=True)

    # Build annotated frames + per-step thumbnails.
    gif_frames = []
    thumb_rel: list[str] = []
    for step in result.steps:
        label = f"{step.index+1}. {step.action_name} — {step.note}"
        annotated = _annotate(step.screenshot, step.tap_xy, label)
        gif_frames.append(_downscale(annotated, config.GIF_MAX_LONG_EDGE))
        thumb = _downscale(annotated, 320)
        tname = f"step_{step.index+1:02d}.png"
        thumb.save(os.path.join(frames_dir, tname))
        thumb_rel.append(f"{base}_frames/{tname}")

    if gif_frames:
        imageio.mimsave(
            gif_path, [f.convert("RGB") for f in gif_frames],
            duration=config.GIF_FRAME_DURATION_SECONDS, loop=0)
    else:
        gif_path = ""

    passed = result.completed
    verdict = "PASS" if passed else "FAIL"

    lines: list[str] = []
    lines.append(f"# Argon run — `{scenario_name}` — {verdict}")
    lines.append("")
    lines.append(f"- **UTC time:** {ts}")
    lines.append(f"- **Scenario:** {scenario_meta.get('description','')}")
    lines.append(f"- **Goal:** {_redact(scenario_meta.get('goal',''), secrets)}")
    lines.append(f"- **Success condition:** {scenario_meta.get('success_condition','')}")
    lines.append(f"- **Model:** `{config.COMPUTER_USE_MODEL}` "
                 f"(env `{config.COMPUTER_USE_ENVIRONMENT}`)")
    lines.append(f"- **Stopped because:** {result.stopped_reason}")
    if result.error:
        lines.append(f"- **Error:** {_redact(result.error, secrets)}")
    lines.append("")
    lines.append("## Device / AVD")
    lines.append("")
    for k in ("serial", "model", "avd_name", "android_version", "sdk",
              "resolution", "density"):
        lines.append(f"- **{k}:** {device_info.get(k,'?')}")
    lines.append("")

    if gif_path:
        lines.append("## Run recording")
        lines.append("")
        lines.append(f"![run](./{os.path.basename(gif_path)})")
        lines.append("")

    lines.append("## Steps")
    lines.append("")
    if not result.steps:
        lines.append("_No steps executed (see Stopped-because / Error above)._")
    for step, thumb in zip(result.steps, thumb_rel):
        coords = f"{step.tap_xy}" if step.tap_xy else "—"
        lines.append(f"### Step {step.index+1}: `{step.action_name}`")
        lines.append("")
        lines.append(f"- **Intended action:** `{step.action_name}` "
                     f"args=`{_redact(str(step.action_args), secrets)}`")
        lines.append(f"- **Device tap (px):** {coords}")
        lines.append(f"- **Execution note:** {_redact(step.note, secrets)}")
        if step.model_text:
            lines.append(f"- **Model reasoning:** {_redact(step.model_text, secrets)}")
        lines.append("")
        lines.append(f"![step {step.index+1}](./{thumb})")
        lines.append("")

    lines.append("## Result")
    lines.append("")
    lines.append(f"- **Verdict:** **{verdict}**")
    lines.append(f"- **Final model message:** {_redact(result.final_text, secrets)}")
    lines.append("")

    report_path = os.path.join(config.REPORTS_DIR, f"{base}.md")
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    return {"report": report_path, "gif": gif_path, "passed": passed}
