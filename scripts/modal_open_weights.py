"""Modal app: OpenAI-compatible open-weights inference for Ayma's cheap path.

Serves an ungated Llama-3.1-8B-Instruct checkpoint behind a vLLM
OpenAI-compatible server, exposed under the model-name alias that
``functions/bootstrap/config.py`` expects (``META_OPEN_WEIGHTS_MODEL`` =
``meta-models/muse-spark-open-1026``). The backend's ``OpenWeightsProvider``
points ``OPEN_WEIGHTS_BASE_URL`` at ``<this endpoint>/v1`` and authenticates
with the ``OPEN_WEIGHTS_API_KEY`` secret, so no backend code changes.

Deploy:   modal deploy scripts/modal_open_weights.py
The web endpoint URL Modal prints is the base; append ``/v1`` for OpenAI.

Design notes:
- Ungated checkpoint ``NousResearch/Meta-Llama-3.1-8B-Instruct`` so no
  HuggingFace gated-access token is needed.
- Served under the alias ``meta-models/muse-spark-open-1026`` via vLLM's
  ``--served-model-name`` regardless of the underlying checkpoint id.
- GPU fallback list (L4 -> A10G -> L40S), cheapest-capable first, so a cold
  start always lands on an available GPU instead of stalling on scarce L4
  capacity; the 8B bf16 model (~15GiB) fits on each.
- Scale-to-zero: ``scaledown_window`` keeps the container warm only briefly
  after the last request, so the $100 Modal credit is not burned idling.
- Weights cached in a Modal Volume so cold starts skip the re-download.
- The API key is required as the bearer token (vLLM ``--api-key``), read from
  the Modal secret ``open-weights-api-key`` — never hardcoded here.
"""

import subprocess

import modal

# Ungated mirror of Llama-3.1-8B-Instruct (no HF gated-access token required).
MODEL_NAME = "NousResearch/Meta-Llama-3.1-8B-Instruct"
MODEL_REVISION = "main"

# Exact alias the backend's config.meta_open_weights_model sends as `model=`.
SERVED_MODEL_NAME = "meta-models/muse-spark-open-1026"

VLLM_PORT = 8000

# vLLM image. Pinned versions, bf16 8B fits a single L4.
vllm_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "vllm==0.6.6.post1",
        "huggingface_hub[hf_transfer]==0.27.0",
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
)

# Persistent cache for downloaded weights -> faster cold starts.
hf_cache_vol = modal.Volume.from_name("open-weights-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("open-weights-vllm-cache", create_if_missing=True)

app = modal.App("ayma-open-weights")


@app.function(
    image=vllm_image,
    # GPU fallback list — Modal tries these in order and schedules on whichever
    # has capacity, so a cold start can always get a GPU instead of stalling on
    # scarce L4 capacity in us-east. Cheapest-capable first; the 8B bf16 model
    # (~15GiB) fits on all of them (L4 24GB, A10G 24GB, L40S 48GB). No A100 to
    # keep cost down (credit pays). Scale-to-zero + flags unchanged.
    gpu=["L4", "A10G", "L40S"],
    # Scale-to-zero: drop the container 2 min after the last request so the
    # credit lasts; cold starts are cushioned by the weight cache volume.
    scaledown_window=120,
    # Allow enough time for a cold start to download + load the 8B model.
    timeout=10 * 60,
    volumes={
        "/root/.cache/huggingface": hf_cache_vol,
        "/root/.cache/vllm": vllm_cache_vol,
    },
    secrets=[modal.Secret.from_name("open-weights-api-key")],
)
@modal.concurrent(max_inputs=32)
@modal.web_server(port=VLLM_PORT, startup_timeout=10 * 60)
def serve():
    import os

    api_key = os.environ["OPEN_WEIGHTS_API_KEY"]

    cmd = [
        "vllm",
        "serve",
        MODEL_NAME,
        "--revision",
        MODEL_REVISION,
        "--served-model-name",
        SERVED_MODEL_NAME,
        "--host",
        "0.0.0.0",
        "--port",
        str(VLLM_PORT),
        "--api-key",
        api_key,
        # Keep KV-cache memory within the L4's 24GB alongside bf16 weights.
        "--max-model-len",
        "8192",
        "--gpu-memory-utilization",
        "0.90",
        # Tool / function calling: Ayma's voice agent sends tools with
        # tool_choice="auto" (open_screen, set_voice_preference, ...). Without
        # these flags vLLM 400s ("'auto' tool choice requires
        # --enable-auto-tool-choice and --tool-call-parser"). llama3_json is the
        # Llama-3.1 tool-call parser; the Instruct chat template handles tools.
        "--enable-auto-tool-choice",
        "--tool-call-parser",
        "llama3_json",
    ]
    subprocess.Popen(" ".join(cmd), shell=True)
