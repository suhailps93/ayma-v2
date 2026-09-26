"""CI smoke for the offline A/B replay (tools/context_ab_replay.py) over the
synthetic long-conversation fixture — no Firestore, no Gemini calls. Verifies
the replay runs end-to-end, that the dieted levels actually shrink the
prompt, and — the quality gate — that no durable fact the old context carried
is LOST at any level."""

import re
import sys
from pathlib import Path

_BOOTSTRAP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BOOTSTRAP / "tools"))

import context_ab_replay as replay  # noqa: E402

_FIXTURE = _BOOTSTRAP / "tests" / "fixtures" / "context_ab_fixture.json"


def _report():
    data = replay.load_from_fixture(str(_FIXTURE))
    return data, replay.run_replay(data, n_turns=30)


def test_replay_runs_and_emits_the_markdown_tables():
    _, report = _report()
    assert "## Text chat" in report
    assert "## Voice" in report
    assert "## Quality" in report
    assert "| Level |" in report


def test_replay_finds_no_lost_facts_on_the_fixture():
    """The blocker gate: the fixture's durable facts (Meera/Bruno/Manipal/
    Coorg/Kochi, all referenced again in the tail) must stay reachable at
    every level."""
    _, report = _report()
    assert "LOSSES" not in report
    assert "No turn lost information" in report
    # and the fixture genuinely exercises the check
    assert "meera" in report and "bruno" in report


def test_replay_voice_costs_drop_at_every_level():
    _, report = _report()
    voice = report.split("## Voice")[1].split("## Quality")[0]
    totals = [
        int(m.replace(",", ""))
        for m in re.findall(r"\| ([\d,]+) \| -", voice)
    ]
    assert len(totals) == 4
    assert totals[1] < totals[0]  # sliding window beats no compression
    assert totals[2] <= totals[1]  # seed diet beats full seed
    assert totals[3] <= totals[1]


def test_replay_text_prompt_shrinks_at_level_2_and_3():
    data = replay.load_from_fixture(str(_FIXTURE))
    wiki_db = replay._FakeWikiDb(data.wiki_pages)
    window = data.turns[:-1]
    message = data.turns[-1].text
    sizes = {
        lv: replay.assemble_chat_turn(wiki_db, window, message, lv).input_tokens
        for lv in (0, 1, 2, 3)
    }
    assert sizes[1] == sizes[0]  # level 1 reorders, never grows/shrinks
    assert sizes[2] < sizes[0]
    assert sizes[3] <= sizes[2] + 50  # core card ≈ trimmed card on this fixture


def test_replay_never_writes_to_firestore():
    """READ-ONLY guarantee, enforced textually: the tool must not contain any
    Firestore write verb."""
    src = (_BOOTSTRAP / "tools" / "context_ab_replay.py").read_text()
    for verb in (".set(", ".add(", ".update(", ".delete("):
        assert verb not in src, f"replay tool must never call {verb}"
