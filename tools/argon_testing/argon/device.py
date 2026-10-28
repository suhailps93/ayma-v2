"""Thin ADB wrapper for screenshots and input injection.

All coordinates taken by the public tap/swipe/type methods are in DEVICE
PIXELS. Normalized (0..COORD_SPACE) coordinates from the model are converted
in argon/loop.py before reaching here.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass

from PIL import Image
import io


class DeviceError(RuntimeError):
    pass


@dataclass
class Device:
    serial: str

    # --- low-level ----------------------------------------------------------
    def _adb(self, args: list[str], binary: bool = False, timeout: int = 60):
        cmd = ["adb", "-s", self.serial] + args
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
        except FileNotFoundError as exc:
            raise DeviceError("adb not found on PATH") from exc
        except subprocess.TimeoutExpired as exc:
            raise DeviceError(f"adb timed out: {' '.join(args)}") from exc
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", "replace")[-300:]
            raise DeviceError(f"adb {' '.join(args)} failed: {err}")
        return proc.stdout if binary else proc.stdout.decode("utf-8", "replace")

    # --- introspection ------------------------------------------------------
    @staticmethod
    def list_serials() -> list[str]:
        try:
            out = subprocess.run(["adb", "devices"], capture_output=True,
                                 text=True, timeout=30).stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return []
        serials = []
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) == 2 and parts[1] == "device":
                serials.append(parts[0])
        return serials

    def describe(self) -> dict:
        """Best-effort device/AVD description for the report header."""
        def getprop(prop: str) -> str:
            try:
                return self._adb(["shell", "getprop", prop]).strip()
            except DeviceError:
                return "?"
        w, h = self.screen_size()
        return {
            "serial": self.serial,
            "model": getprop("ro.product.model"),
            "avd_name": getprop("ro.boot.qemu.avd_name") or getprop("ro.kernel.qemu.avd_name"),
            "android_version": getprop("ro.build.version.release"),
            "sdk": getprop("ro.build.version.sdk"),
            "resolution": f"{w}x{h}",
            "density": getprop("ro.sf.lcd_density"),
        }

    def screen_size(self) -> tuple[int, int]:
        """Return (width, height) in pixels from the current screenshot."""
        img = self.screenshot()
        return img.size

    # --- capture ------------------------------------------------------------
    def screenshot(self) -> Image.Image:
        """Capture the current screen as a PIL image (PNG via screencap)."""
        raw = self._adb(["exec-out", "screencap", "-p"], binary=True)
        try:
            return Image.open(io.BytesIO(raw)).convert("RGB")
        except Exception as exc:
            raise DeviceError("could not decode screencap PNG") from exc

    # --- input injection (device pixels) ------------------------------------
    def tap(self, x: int, y: int) -> None:
        self._adb(["shell", "input", "tap", str(x), str(y)])

    def swipe(self, x1: int, y1: int, x2: int, y2: int, ms: int = 300) -> None:
        self._adb(["shell", "input", "swipe",
                   str(x1), str(y1), str(x2), str(y2), str(ms)])

    def type_text(self, text: str) -> None:
        # `input text` does not handle spaces or special chars well; send
        # char-group by char-group, escaping spaces as %s.
        safe = text.replace(" ", "%s")
        self._adb(["shell", "input", "text", safe])

    def keyevent(self, key: str) -> None:
        """Send a keyevent. `key` may be a numeric code or Android keycode name
        (e.g. 'KEYCODE_ENTER', 'KEYCODE_BACK')."""
        self._adb(["shell", "input", "keyevent", key])
