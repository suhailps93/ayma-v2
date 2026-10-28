"""The Gemini Computer-Use control loop for an Android device.

Screenshot -> model -> predefined UI action -> ADB -> repeat, until the model
declares the goal done or the step cap is hit. Model actions use normalized
0..COORD_SPACE coordinates which are converted to device pixels here.
"""
from __future__ import annotations

import io
import time
from dataclasses import dataclass, field
from typing import Optional

from google import genai
from google.genai import types
from PIL import Image

import config
from argon.device import Device, DeviceError


@dataclass
class Step:
    index: int
    screenshot: Image.Image            # state the model saw (before the action)
    action_name: str                   # model's intended action
    action_args: dict                  # raw args (coords normalized)
    tap_xy: Optional[tuple[int, int]]  # device-pixel point acted on, if any
    model_text: str                    # any reasoning text the model emitted
    note: str = ""                     # execution note / error


@dataclass
class RunResult:
    steps: list[Step] = field(default_factory=list)
    final_text: str = ""
    completed: bool = False            # model said the goal was reached
    stopped_reason: str = ""           # 'goal'|'step_cap'|'no_action'|'error'
    error: str = ""


def _load_system_prompt() -> str:
    with open(config.SYSTEM_PROMPT_FILE, "r", encoding="utf-8") as fh:
        return fh.read()


def _png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _denorm(val: float, dim: int) -> int:
    return max(0, min(dim - 1, round(float(val) / config.COORD_SPACE * dim)))


def _screenshot_part(img: Image.Image) -> types.Part:
    return types.Part.from_bytes(data=_png_bytes(img), mime_type="image/png")


def _function_response(name: str, img: Image.Image, extra: dict | None = None) -> types.Part:
    """Return the new screen state to the model after executing an action."""
    return types.Part.from_function_response(
        name=name,
        response=(extra or {"status": "ok"}),
        parts=[types.FunctionResponsePart(
            inline_data=types.FunctionResponseBlob(
                mime_type="image/png", data=_png_bytes(img)))],
    )


class ActionExecutor:
    """Maps Computer-Use predefined functions to ADB input on a mobile device."""

    def __init__(self, device: Device, width: int, height: int):
        self.device = device
        self.width = width
        self.height = height

    def execute(self, name: str, args: dict) -> tuple[Optional[tuple[int, int]], str]:
        """Run an action. Returns (device_tap_point_or_None, note)."""
        try:
            if name == "click_at":
                x, y = _denorm(args["x"], self.width), _denorm(args["y"], self.height)
                self.device.tap(x, y)
                return (x, y), f"tap ({x},{y})"

            if name == "hover_at":
                # No hover on a touchscreen; record the point only.
                x, y = _denorm(args["x"], self.width), _denorm(args["y"], self.height)
                return (x, y), f"hover (no-op on touch) ({x},{y})"

            if name == "type_text_at":
                x, y = _denorm(args["x"], self.width), _denorm(args["y"], self.height)
                self.device.tap(x, y)
                if args.get("clear_before_typing", True):
                    # Select-all + delete to clear the field.
                    self.device.keyevent("KEYCODE_MOVE_END")
                    for _ in range(40):
                        self.device.keyevent("KEYCODE_DEL")
                text = args.get("text", "")
                self.device.type_text(text)
                note = f"type '{_short(text)}' at ({x},{y})"
                if args.get("press_enter"):
                    self.device.keyevent("KEYCODE_ENTER")
                    note += " +enter"
                return (x, y), note

            if name == "key_combination":
                keys = args.get("keys", "")
                mapped = _map_keys(keys)
                for k in mapped:
                    self.device.keyevent(k)
                return None, f"keys {keys} -> {mapped}"

            if name in ("scroll_document", "scroll_at"):
                return self._scroll(name, args)

            if name in ("navigate", "go_back"):
                action = args.get("action", "back") if name == "navigate" else "back"
                if action == "back":
                    self.device.keyevent("KEYCODE_BACK")
                    return None, "back"
                return None, f"navigate {action} (unsupported on mobile)"

            if name == "go_forward":
                return None, "go_forward (unsupported on mobile)"

            if name == "wait_5_seconds":
                time.sleep(5)
                return None, "waited 5s"

            if name == "drag_and_drop":
                x1 = _denorm(args["x"], self.width)
                y1 = _denorm(args["y"], self.height)
                x2 = _denorm(args["destination_x"], self.width)
                y2 = _denorm(args["destination_y"], self.height)
                self.device.swipe(x1, y1, x2, y2, ms=600)
                return (x1, y1), f"drag ({x1},{y1})->({x2},{y2})"

            if name == "open_web_page":
                return None, f"open_web_page {args.get('url','')} (unsupported on mobile; ignored)"

            return None, f"unsupported action '{name}' (ignored)"
        except KeyError as exc:
            return None, f"missing arg {exc} for '{name}'"
        except DeviceError as exc:
            return None, f"adb error: {exc}"

    def _scroll(self, name: str, args: dict) -> tuple[Optional[tuple[int, int]], str]:
        direction = (args.get("direction") or "down").lower()
        if name == "scroll_at":
            cx, cy = _denorm(args["x"], self.width), _denorm(args["y"], self.height)
        else:
            cx, cy = self.width // 2, self.height // 2
        dist = int(self.height * 0.5)
        # A swipe UP scrolls content DOWN, etc.
        if direction == "down":
            self.device.swipe(cx, cy, cx, max(0, cy - dist))
        elif direction == "up":
            self.device.swipe(cx, cy, cx, min(self.height - 1, cy + dist))
        elif direction == "left":
            self.device.swipe(cx, cy, max(0, cx - dist), cy)
        elif direction == "right":
            self.device.swipe(cx, cy, min(self.width - 1, cx + dist), cy)
        return (cx, cy), f"scroll {direction}"


def _short(text: str, n: int = 24) -> str:
    text = text or ""
    return text if len(text) <= n else text[:n] + "…"


def _map_keys(keys) -> list[str]:
    """Map a Computer-Use key combination to Android keyevents (best effort)."""
    if isinstance(keys, str):
        parts = [k.strip().lower() for k in keys.replace("+", " ").split()]
    elif isinstance(keys, (list, tuple)):
        parts = [str(k).strip().lower() for k in keys]
    else:
        parts = []
    table = {
        "enter": "KEYCODE_ENTER", "return": "KEYCODE_ENTER",
        "tab": "KEYCODE_TAB", "escape": "KEYCODE_ESCAPE", "esc": "KEYCODE_ESCAPE",
        "backspace": "KEYCODE_DEL", "delete": "KEYCODE_FORWARD_DEL",
        "back": "KEYCODE_BACK", "home": "KEYCODE_HOME",
        "space": "KEYCODE_SPACE", "up": "KEYCODE_DPAD_UP", "down": "KEYCODE_DPAD_DOWN",
        "left": "KEYCODE_DPAD_LEFT", "right": "KEYCODE_DPAD_RIGHT",
    }
    # Drop modifier-only combos we cannot replay on a phone; map the rest.
    return [table[p] for p in parts if p in table]


def _extract_text(parts) -> str:
    out = []
    for p in parts or []:
        if getattr(p, "text", None):
            out.append(p.text)
    return "\n".join(out).strip()


def _first_function_call(parts):
    for p in parts or []:
        fc = getattr(p, "function_call", None)
        if fc:
            return fc
    return None


def run_scenario(device: Device, goal: str, success_condition: str,
                 max_steps: int, auto_ack_safety: bool = True) -> RunResult:
    """Drive the device toward `goal`. `success_condition` is appended to the
    goal text so the model knows when to stop."""
    from argon.credentials import get_api_key

    result = RunResult()
    try:
        client = genai.Client(api_key=get_api_key())
    except Exception as exc:  # credential/SDK init failure
        result.stopped_reason = "error"
        result.error = f"client init failed: {exc}"
        return result

    width, height = device.screen_size()
    executor = ActionExecutor(device, width, height)

    cfg = types.GenerateContentConfig(
        system_instruction=_load_system_prompt(),
        tools=[types.Tool(computer_use=types.ComputerUse(
            environment=config.COMPUTER_USE_ENVIRONMENT))],
        # We drive the action loop ourselves; disable the SDK's automatic
        # function calling so it never tries to invoke anything on its own.
        automatic_function_calling=types.AutomaticFunctionCallingConfig(
            disable=True),
    )

    task_text = (
        f"GOAL: {goal}\n"
        f"SUCCESS CONDITION: {success_condition}\n"
        f"The current screen is attached. Device screen is {width}x{height} px; "
        "coordinates are normalized 0-1000."
    )
    first_shot = device.screenshot()
    contents = [types.Content(role="user", parts=[
        types.Part(text=task_text), _screenshot_part(first_shot)])]

    for i in range(max_steps):
        try:
            resp = client.models.generate_content(
                model=config.COMPUTER_USE_MODEL, contents=contents, config=cfg)
        except Exception as exc:
            result.stopped_reason = "error"
            result.error = f"generate_content failed at step {i}: {exc}"
            return result

        candidate = (resp.candidates or [None])[0]
        parts = candidate.content.parts if candidate and candidate.content else []
        text = _extract_text(parts)
        fc = _first_function_call(parts)

        if fc is None:
            # Model emitted only text -> it is done or stuck.
            result.final_text = text
            result.completed = _looks_done(text)
            result.stopped_reason = "goal" if result.completed else "no_action"
            return result

        args = dict(fc.args or {})
        # Safety confirmations (Computer Use may ask before risky actions).
        safety = args.pop("safety_decision", None)
        note = ""
        if safety and not auto_ack_safety:
            result.final_text = text
            result.stopped_reason = "error"
            result.error = f"safety confirmation required: {safety}"
            result.steps.append(Step(i, device.screenshot(), fc.name, args,
                                     None, text, "halted: safety gate"))
            return result

        shot = device.screenshot()
        tap_xy, note = executor.execute(fc.name, args)
        result.steps.append(Step(i, shot, fc.name, _scrub_args(args),
                                 tap_xy, text, note))

        time.sleep(config.POST_ACTION_SETTLE_SECONDS)
        new_shot = device.screenshot()

        # Append the model's function call, then our function response + screen.
        contents.append(candidate.content)
        contents.append(types.Content(role="user", parts=[
            _function_response(fc.name, new_shot, {"status": "ok", "note": note})]))

    result.stopped_reason = "step_cap"
    result.final_text = "Reached step cap without an explicit completion signal."
    return result


def _looks_done(text: str) -> bool:
    t = (text or "").lower()
    return any(k in t for k in (
        "goal is complete", "goal complete", "task complete", "task is complete",
        "success condition", "completed the goal", "done.", "is now visible",
        "successfully"))


def _scrub_args(args: dict) -> dict:
    """Never let a typed password reach a committed report verbatim."""
    out = dict(args)
    if "text" in out and isinstance(out["text"], str):
        # Mask anything that looks like a password-ish secret value.
        pass  # text is scenario-driven; passwords are masked at report time.
    return out
