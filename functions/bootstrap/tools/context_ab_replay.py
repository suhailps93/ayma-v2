"""Offline A/B replay for the context-optimization program (2026-09-26).

Replays the last ~N user turns of a real conversation (read-only from
Firestore) or a synthetic fixture (CI), assembling for each turn the prompt
the OLD path (CONTEXT_OPT_LEVEL=0) and each NEW path (levels 1/2/3) would
send, using the REAL production assembly functions (compose_system_prompt,
read_wiki_context, context_opt) — then counts tokens per component, prices
them with token_ledger's rates, and models the Gemini Live per-turn
re-billing with and without the sliding window. Emits a markdown report.

Usage (from functions/bootstrap, main .venv):

    .venv/bin/python tools/context_ab_replay.py                 # founder uid
    .venv/bin/python tools/context_ab_replay.py --uid <uid>
    .venv/bin/python tools/context_ab_replay.py \
        --fixture tests/fixtures/context_ab_fixture.json        # no Firestore
    ... [--turns 30] [--out report.md]

READ-ONLY: this script never writes to Firestore (it only ever calls
``.stream()``/``.get()``; there is no ``set``/``add``/``update`` anywhere in
it).

Modeling assumptions (stated once, used consistently):

* Tokens are estimated as chars/4 (context_opt.est_tokens) — the same
  estimator the Phase 0 measurement uses, so live numbers and replay numbers
  are comparable.
* The rolling summary (level >= 2) is simulated as a 1,500-char block — the
  summarizer's instructed maximum — since generating real summaries offline
  would spend real Gemini tokens. Its *content* is therefore not checked
  directly; a fact whose source turn lies in the summarized head is counted
  as "via summary" (the summarizer prompt instructs never to drop such
  facts, and tests/test_context_opt.py guards the plumbing).
* Voice audio: ~25 tokens/second; a user utterance is modeled at 8s
  (200 tokens) and an Ayma reply at 10s (250 tokens) per turn.
* Implicit prefix cache: consecutive-turn prompts' real byte-common prefix
  is computed per level, and those tokens are billed at 25% of the input
  rate (Gemini's implicit caching discount) in the "with cache" column;
  the "no cache" column bills everything at full rate (worst case).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Local dev creds (GOOGLE_APPLICATION_CREDENTIALS) before any firebase import.
try:  # pragma: no cover - convenience only
    from dotenv import load_dotenv

    for _parent in Path(__file__).resolve().parents:
        if (_parent / ".env.local").exists():
            load_dotenv(_parent / ".env.local")
            break
except ImportError:  # pragma: no cover
    pass

import context_opt  # noqa: E402
import token_ledger  # noqa: E402
import wiki_query  # noqa: E402
from config import CONFIG  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402
from transcript import Turn, format_recent_turns  # noqa: E402

FOUNDER_UID = "iWhWjiWhEpU7iyu9B9vy7GlT0PD2"
LEVELS = [0, 1, 2, 3]

# Voice audio model (see module docstring).
AUDIO_TOKENS_USER_TURN = 200
AUDIO_TOKENS_AYMA_TURN = 250
VOICE_TURNS = 30

# Simulated rolling-summary size (the summarizer's instructed max).
SUMMARY_SIM_CHARS = 1500

# The client caps the window it sends (main._MAX_RECENT_TURNS).
MAX_CLIENT_WINDOW = 200

# Text-chat output per turn — identical across levels (the diet changes what
# we SEND, not what the model says back); included so $/turn is end-to-end.
TEXT_OUTPUT_TOKENS_PER_TURN = 150

CACHED_TOKEN_PRICE_FACTOR = 0.25  # Gemini implicit-cache discount on hits


# --------------------------------------------------------------------------
# data loading
# --------------------------------------------------------------------------


@dataclass
class Dataset:
    label: str
    turns: list[Turn]  # oldest-first merged transcript
    wiki_pages: list[dict]  # [{page_type, page_id, ai_body}]


class _FakeWikiDb:
    """Just enough Firestore surface for read_wiki_context / recall_snippets,
    over already-fetched pages — so the replay hits Firestore once, not once
    per level per turn."""

    class _Snap:
        def __init__(self, page):
            self.id = page["page_id"]
            self._page = page

        def to_dict(self):
            return {
                "page_type": self._page["page_type"],
                "ai_body": self._page["ai_body"],
            }

    def __init__(self, pages):
        self._pages = pages

    def collection(self, _name):
        return self

    def document(self, _name):
        return self

    def stream(self):
        return iter(self._Snap(p) for p in self._pages)


def load_from_firestore(uid: str) -> Dataset:
    """READ-ONLY pull of the merged transcript + wiki for ``uid`` — reuses
    chat_history's own merge so the replayed window is exactly what the
    client would reload and resend."""
    import chat_history
    from db import get_db

    db = get_db()
    items = chat_history._collect(db, uid)  # read-only merge of both sources
    from datetime import datetime, timezone

    far_past = datetime.min.replace(tzinfo=timezone.utc)
    items.sort(key=lambda m: m["ts"] or far_past)
    turns = [
        Turn(role=m["role"], text=m["text"]) for m in items if m["text"].strip()
    ]

    pages = []
    for snap in (
        db.collection("users").document(uid).collection("wiki_pages").stream()
    ):
        data = snap.to_dict() or {}
        body = (data.get("ai_body") or "").strip()
        if body:
            pages.append(
                {
                    "page_id": snap.id,
                    "page_type": data.get("page_type") or "misc",
                    "ai_body": body,
                }
            )
    return Dataset(label=f"real uid {uid}", turns=turns, wiki_pages=pages)


def load_from_fixture(path: str) -> Dataset:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    turns = [Turn(role=t["role"], text=t["text"]) for t in raw["turns"]]
    return Dataset(
        label=f"fixture {Path(path).name}",
        turns=turns,
        wiki_pages=list(raw["wiki_pages"]),
    )


# --------------------------------------------------------------------------
# per-level prompt assembly (the real production functions, env-gated)
# --------------------------------------------------------------------------


class _Level:
    def __init__(self, level: int):
        self.level = level

    def __enter__(self):
        self._old = os.environ.get("CONTEXT_OPT_LEVEL")
        os.environ["CONTEXT_OPT_LEVEL"] = str(self.level)
        return self

    def __exit__(self, *_exc):
        if self._old is None:
            os.environ.pop("CONTEXT_OPT_LEVEL", None)
        else:
            os.environ["CONTEXT_OPT_LEVEL"] = self._old


@dataclass
class AssembledTurn:
    prompt: str
    message: str
    wiki_block: str
    history_block: str
    summary_block: str
    summarized_head: list[Turn] = field(default_factory=list)

    @property
    def input_tokens(self) -> int:
        return context_opt.est_tokens(len(self.prompt) + len(self.message))


def assemble_chat_turn(
    wiki_db: _FakeWikiDb, window: list[Turn], message: str, level: int
) -> AssembledTurn:
    """Mirror of main._prepare_chat's context selection at ``level`` (kept in
    lockstep with it; the flag-off suite asserts main.py's own level-0 path is
    byte-identical to pre-change behavior)."""
    with _Level(level):
        if context_opt.recall_enabled():
            wiki_ctx = wiki_query.read_wiki_context(
                wiki_db, "u",
                max_chars=context_opt.core_wiki_chars(),
                include_page_types=context_opt.CORE_PAGE_TYPES,
            )
        elif context_opt.wiki_trim_enabled():
            wiki_ctx = wiki_query.read_wiki_context(
                wiki_db, "u",
                max_chars=context_opt.trim_wiki_chars(),
                include_page_types=context_opt.wiki_include_types(message),
            )
        else:
            wiki_ctx = wiki_query.read_wiki_context(wiki_db, "u")

        prompt_window = window
        summary_text = ""
        head: list[Turn] = []
        if context_opt.summary_enabled():
            prompt_window = context_opt.trim_history(window)
            if len(window) > len(prompt_window):
                head = window[: len(window) - len(prompt_window)]
                summary_text = "S" * SUMMARY_SIM_CHARS  # size stand-in

        prompt = compose_system_prompt(
            recent_turns=prompt_window,
            wiki_context=wiki_ctx,
            summary_context=summary_text,
            stable_prefix=context_opt.stable_prefix_enabled(),
        )
    return AssembledTurn(
        prompt=prompt,
        message=message,
        wiki_block=wiki_ctx,
        history_block=format_recent_turns(prompt_window),
        summary_block=summary_text,
        summarized_head=head,
    )


def assemble_voice_seed(
    wiki_db: _FakeWikiDb, window: list[Turn], level: int
) -> tuple[int, AssembledTurn]:
    """Voice seed tokens at ``level``: the composed system prompt PLUS the
    chat_ctx replay of the seeded turns (the Live session carries both)."""
    with _Level(level):
        if context_opt.voice_seed_diet_enabled():
            prompt_turns = window[-context_opt.voice_tail_turns():]
            wiki_ctx = wiki_query.read_wiki_context(
                wiki_db, "u",
                max_chars=context_opt.core_wiki_chars(),
                include_page_types=context_opt.CORE_PAGE_TYPES,
            )
            summary_text = "S" * SUMMARY_SIM_CHARS
            head = window[: len(window) - len(prompt_turns)]
        else:
            prompt_turns = window
            wiki_ctx = wiki_query.read_wiki_context(wiki_db, "u")
            summary_text = ""
            head = []
        prompt = compose_system_prompt(
            recent_turns=prompt_turns,
            wiki_context=wiki_ctx,
            summary_context=summary_text,
        )
        chat_ctx_chars = sum(len(t.text) for t in prompt_turns)
    assembled = AssembledTurn(
        prompt=prompt,
        message="",
        wiki_block=wiki_ctx,
        history_block=format_recent_turns(prompt_turns),
        summary_block=summary_text,
        summarized_head=head,
    )
    seed_tokens = context_opt.est_tokens(len(prompt) + chat_ctx_chars)
    return seed_tokens, assembled


# --------------------------------------------------------------------------
# voice per-turn re-billing model
# --------------------------------------------------------------------------


def voice_session_input_tokens(
    seed_tokens: int, turns: int, *, compression: bool
) -> list[int]:
    """Per-turn INPUT tokens for a voice call: the Live API re-bills the whole
    accumulated context every turn. With compression, the context is cut back
    to the retained window whenever it crosses the trigger."""
    trigger = context_opt.voice_compression_trigger_tokens()
    retained = context_opt.voice_compression_target_tokens()
    ctx = seed_tokens
    out = []
    for _ in range(turns):
        turn_input = ctx + AUDIO_TOKENS_USER_TURN
        out.append(turn_input)
        ctx = turn_input + AUDIO_TOKENS_AYMA_TURN
        if compression and ctx > trigger:
            ctx = retained
    return out


# --------------------------------------------------------------------------
# quality: durable-fact coverage
# --------------------------------------------------------------------------

_CAP_WORD_RE = re.compile(r"\b[A-Z][a-z]{3,}\b")
_FACT_STOPWORDS = frozenset(
    "ayma user okay yeah thanks please hello sorry maybe really actually "
    "monday tuesday wednesday thursday friday saturday sunday january "
    "february march april may june july august september october november "
    "december also alright okay well right just then there here that this "
    "what when where they their about because still every never always "
    "something anything the and but for with "
    # interjections that show up capitalized mid-sentence but carry no fact
    "gotcha ouch oops haha hmmm whoa yay aww nope yeah".split()
)


def durable_fact_terms(turns: list[Turn], replay_start: int) -> dict[str, int]:
    """Proper-noun-ish terms that (a) first appear well before the replayed
    tail and (b) are referenced again inside it — i.e. facts the real later
    conversation actually relied on. Returns {term: first_turn_index}.

    A term counts as proper-noun-ish only when it behaves like one across the
    whole transcript: it appears capitalized in a NON-sentence-initial
    position at least once, and never appears lowercase (sentence-start
    capitals like "Back ..."/"Even ..." fail one of the two)."""
    all_text = " ".join(t.text for t in turns)
    lowercase_words = set(re.findall(r"(?<=[a-z] )[a-z]{4,}\b", all_text)) | set(
        re.findall(r"\b[a-z]{4,}\b", all_text)
    )
    mid_sentence_caps = set(
        m.group(0).lower()
        for m in re.finditer(r"(?<![.!?\n] )(?<!^)\b[A-Z][a-z]{3,}\b", all_text)
    )
    first_seen: dict[str, int] = {}
    for i, t in enumerate(turns):
        for m in _CAP_WORD_RE.findall(t.text):
            w = m.lower()
            if w in _FACT_STOPWORDS:
                continue
            if w in lowercase_words or w not in mid_sentence_caps:
                continue  # behaves like an ordinary word, not a name
            first_seen.setdefault(w, i)
    out: dict[str, int] = {}
    tail_text = " ".join(t.text for t in turns[replay_start:]).lower()
    for w, i in first_seen.items():
        if i < replay_start - 15 and re.search(rf"\b{re.escape(w)}\b", tail_text):
            out[w] = i
    return out


def classify_fact(
    term: str, assembled: AssembledTurn, all_wiki_text: str,
    window: list[Turn], level: int,
) -> str:
    """How the assembled context at ``level`` still covers ``term``:
    'direct' (in the prompt or the message itself), 'wiki' (in the standing
    wiki block), 'recall' (in a wiki page the recall tool can fetch — level 3
    only), 'summary' (its source turn feeds the rolling summary), 'LOST'
    (the old L0 prompt had it via the window but nothing at this level can
    reach it — a blocker), or 'n/a' (L0 didn't have it either: not a
    regression the diet introduced)."""
    pat = re.compile(rf"\b{re.escape(term)}\w*", re.IGNORECASE)
    if pat.search(assembled.prompt) or pat.search(assembled.message):
        return "direct"
    if pat.search(assembled.wiki_block):
        return "wiki"
    if level >= 3 and pat.search(all_wiki_text):
        return "recall"
    if any(pat.search(t.text) for t in assembled.summarized_head):
        return "summary"
    if any(pat.search(t.text) for t in window):
        return "LOST"
    return "n/a"


# --------------------------------------------------------------------------
# pricing
# --------------------------------------------------------------------------


def _rate(model: str, direction: str) -> float:
    price = token_ledger._MODEL_PRICING.get(model, {}).get(direction)
    if not isinstance(price, (int, float)):
        raise ValueError(f"No {direction} pricing configured for {model!r}")
    return float(price)


def text_rate() -> float:
    return _rate(CONFIG.gemini_model, "input")


def text_out_rate() -> float:
    return _rate(CONFIG.gemini_model, "output")


def voice_rate() -> float:
    return _rate(token_ledger.live_model_id(), "input")


def voice_out_rate() -> float:
    return _rate(token_ledger.live_model_id(), "output")


def usd(tokens: float, rate: float) -> float:
    return tokens / 1_000_000 * rate


# --------------------------------------------------------------------------
# the replay
# --------------------------------------------------------------------------


def run_replay(data: Dataset, n_turns: int = 30) -> str:
    wiki_db = _FakeWikiDb(data.wiki_pages)
    all_wiki_text = "\n".join(p["ai_body"] for p in data.wiki_pages)

    # The replayed turns: the last n user turns (each = one /chat call).
    user_idx = [i for i, t in enumerate(data.turns) if t.role == "user"]
    replay_idx = user_idx[-n_turns:]
    if not replay_idx:
        return f"# Context A/B replay — {data.label}\n\nNo user turns to replay."
    replay_start = replay_idx[0]

    facts = durable_fact_terms(data.turns, replay_start)

    # --- text chat ---------------------------------------------------------
    per_level_tokens: dict[int, list[int]] = {lv: [] for lv in LEVELS}
    per_level_cached: dict[int, list[int]] = {lv: [] for lv in LEVELS}
    prev_prompt: dict[int, str] = {}
    fact_cover: dict[int, dict[str, str]] = {lv: {} for lv in LEVELS}
    losses: list[str] = []

    for i in replay_idx:
        window = data.turns[max(0, i - MAX_CLIENT_WINDOW):i]
        message = data.turns[i].text
        for lv in LEVELS:
            a = assemble_chat_turn(wiki_db, window, message, lv)
            per_level_tokens[lv].append(a.input_tokens)
            # real byte-common prefix with the previous turn's prompt
            prev = prev_prompt.get(lv, "")
            common = os.path.commonprefix([prev, a.prompt]) if prev else ""
            per_level_cached[lv].append(context_opt.est_tokens(len(common)))
            prev_prompt[lv] = a.prompt
            for term, first_idx in facts.items():
                got = classify_fact(term, a, all_wiki_text, window, lv)
                cur = fact_cover[lv].get(term)
                order = ["LOST", "summary", "recall", "wiki", "direct", "n/a"]
                if cur is None or order.index(got) < order.index(cur):
                    fact_cover[lv][term] = got
                if got == "LOST":
                    losses.append(
                        f"level {lv}, turn {i} ({message[:40]!r}): fact "
                        f"{term!r} (first said at turn {first_idx}) is in "
                        "neither the prompt, the wiki, nor the summary head"
                    )

    # --- voice -------------------------------------------------------------
    seed_window = data.turns[-MAX_CLIENT_WINDOW:]
    voice_rows = []
    for lv in LEVELS:
        seed_tokens, _seed = assemble_voice_seed(wiki_db, seed_window, lv)
        with _Level(lv):
            compression = context_opt.voice_compression_enabled()
        per_turn = voice_session_input_tokens(
            seed_tokens, VOICE_TURNS, compression=compression
        )
        total = sum(per_turn)
        voice_rows.append((lv, seed_tokens, compression, per_turn, total))

    # --- report ------------------------------------------------------------
    lines = [
        f"# Context A/B replay — {data.label}",
        "",
        f"Transcript: {len(data.turns)} merged turns; replayed the last "
        f"{len(replay_idx)} user turns. Wiki: {len(data.wiki_pages)} pages, "
        f"{len(all_wiki_text)} chars. Tokens = chars/4. Prices: text input "
        f"${text_rate()}/1M (output ${text_out_rate()}/1M, "
        f"{TEXT_OUTPUT_TOKENS_PER_TURN} tok/turn, identical across levels), "
        f"voice audio input ${voice_rate()}/1M "
        f"({token_ledger.live_model_id()}, the configured voice model).",
        "",
        "## Text chat — prompt input per turn",
        "",
        "| Level | Avg in-tokens/turn | vs L0 | $/100 turns (no cache) | "
        "$/100 turns (implicit cache) | Cached prefix/turn |",
        "|---|---|---|---|---|---|",
    ]
    base_avg = sum(per_level_tokens[0]) / len(per_level_tokens[0])
    for lv in LEVELS:
        toks = per_level_tokens[lv]
        cached = per_level_cached[lv]
        avg = sum(toks) / len(toks)
        avg_cached = sum(cached) / len(cached)
        cost_nc = usd(avg * 100, text_rate()) + usd(
            TEXT_OUTPUT_TOKENS_PER_TURN * 100, text_out_rate()
        )
        eff = avg - avg_cached * (1 - CACHED_TOKEN_PRICE_FACTOR)
        cost_c = usd(eff * 100, text_rate()) + usd(
            TEXT_OUTPUT_TOKENS_PER_TURN * 100, text_out_rate()
        )
        red = (1 - avg / base_avg) * 100
        lines.append(
            f"| {lv} | {avg:,.0f} | {'-' if lv == 0 else f'-{red:.0f}%'} | "
            f"${cost_nc:.3f} | ${cost_c:.3f} | {avg_cached:,.0f} tok |"
        )

    lines += [
        "",
        f"## Voice — one {VOICE_TURNS}-turn call (Live API re-bills the whole "
        "context every turn)",
        "",
        "| Level | Seed tokens | Sliding window | Total in-tokens/call | "
        "vs L0 | $/call | $/100 turns |",
        "|---|---|---|---|---|---|---|",
    ]
    base_voice = voice_rows[0][4]
    for lv, seed_tokens, compression, per_turn, total in voice_rows:
        red = (1 - total / base_voice) * 100
        out_tok = AUDIO_TOKENS_AYMA_TURN * VOICE_TURNS
        cost = usd(total, voice_rate()) + usd(
            out_tok,
            voice_out_rate(),
        )
        lines.append(
            f"| {lv} | {seed_tokens:,} | {'on' if compression else 'off'} | "
            f"{total:,} | {'-' if lv == 0 else f'-{red:.0f}%'} | "
            f"${cost:.3f} | ${cost / VOICE_TURNS * 100:.3f} |"
        )

    lines += ["", "## Quality — durable-fact coverage", ""]
    if not facts:
        lines.append(
            "No durable back-references detected in the replayed tail "
            "(no early proper-noun fact is re-mentioned late)."
        )
    else:
        lines.append(
            f"{len(facts)} durable fact term(s) referenced in the replayed "
            "tail: " + ", ".join(sorted(facts)) + "."
        )
        lines.append("")
        lines.append("| Level | direct | wiki | recall | via summary | LOST |")
        lines.append("|---|---|---|---|---|---|")
        for lv in LEVELS:
            c = fact_cover[lv]
            counts = {k: 0 for k in ("direct", "wiki", "recall", "summary", "LOST")}
            for v in c.values():
                if v in counts:
                    counts[v] += 1
            lines.append(
                f"| {lv} | {counts['direct']} | {counts['wiki']} | "
                f"{counts['recall']} | {counts['summary']} | {counts['LOST']} |"
            )
    lines.append("")
    if losses:
        lines.append("### LOSSES (blockers)")
        lines += [f"- {loss}" for loss in sorted(set(losses))]
    else:
        lines.append(
            "No turn lost information the old context had — every durable "
            "fact stays reachable (directly, via the wiki/recall, or via the "
            "summarizer's input)."
        )
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--uid", default=FOUNDER_UID)
    ap.add_argument("--fixture", default="")
    ap.add_argument("--turns", type=int, default=30)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    if args.fixture:
        data = load_from_fixture(args.fixture)
    else:
        data = load_from_firestore(args.uid)

    report = run_replay(data, n_turns=args.turns)
    if args.out:
        Path(args.out).write_text(report + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(report)


if __name__ == "__main__":
    main()
