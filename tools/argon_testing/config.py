"""Single source of truth for Argon emulator-testing harness configuration.

All model ids, endpoints, and tunable defaults live here and nowhere else.
No credentials are stored in this file; the key is read from Google Secret
Manager at runtime (see argon/credentials.py).
"""
from __future__ import annotations

# --- Gemini Computer Use model ---------------------------------------------
# The computer-use-capable model id. This is the ONLY place a model name
# appears in the tool. If this ever needs to change, change it here.
COMPUTER_USE_MODEL = "gemini-2.5-computer-use-preview-10-2025"

# Environment passed to the Computer Use tool. The emulator is a mobile
# device, so ENVIRONMENT_MOBILE is the correct surface.
COMPUTER_USE_ENVIRONMENT = "ENVIRONMENT_MOBILE"

# Gemini Developer API base (generativelanguage). The google-genai SDK targets
# this automatically; the explicit value is kept for the Step-0 probe and docs.
GENAI_API_BASE = "https://generativelanguage.googleapis.com"

# --- Secret Manager ----------------------------------------------------------
GCP_PROJECT = "ayma-ai"
# Secret holding the Gemini / Computer Use credential.
SECRET_API_KEY = "GEMINI_ARGON_API_KEY"
# Secret (optional) holding the seeded test-account password. If this secret
# does not exist, the harness prompts for the password instead and never
# stores it. See README for how to populate it.
SECRET_TEST_PASSWORD = "AYMA_TEST_ALEX_PASSWORD"

# --- Run loop defaults -------------------------------------------------------
# Hard cap on model/action steps for any single scenario run.
DEFAULT_MAX_STEPS = 25
# Seconds to wait after executing an action before the next screenshot, to let
# the UI settle.
POST_ACTION_SETTLE_SECONDS = 1.2
# Coordinate space the Computer Use model returns actions in (normalized).
COORD_SPACE = 1000

# --- GIF output --------------------------------------------------------------
GIF_FRAME_DURATION_SECONDS = 1.1  # per-frame display time
# Downscale long edge of each frame to keep the GIF small (pixels). None = full.
GIF_MAX_LONG_EDGE = 540

# --- Paths -------------------------------------------------------------------
import os

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPORTS_DIR = os.path.join(TOOL_DIR, "reports")
SCENARIOS_DIR = os.path.join(TOOL_DIR, "scenarios")
PROMPTS_DIR = os.path.join(TOOL_DIR, "prompts")
SYSTEM_PROMPT_FILE = os.path.join(PROMPTS_DIR, "task_system_prompt.md")
