"""Demo-seed Practice Date readiness (docs/DEMO_ACCOUNTS.md) — fully offline.

Proves, without touching live systems, that the data the demo seed writes for
test1/test2/test3 is exactly what the Practice Date + AI Date Simulation flows
read. The REAL ``scripts/demo_seed/personas.json`` fixtures and the REAL seed
writers (``write_profile_and_questionnaire`` / ``write_taste``) run against
FakeDb; story pages use the seed's exact write shape for the nine page types
``prompts/demo_seed/story_pages.md`` requires; photos use the pipeline's grid +
``user_media`` shape; DMs go through the real ``dm_ops``; avatar snapshots are
built AFTER the DMs (the seed's order). Then both personas ground, prompts
compose, sessions round-trip, readiness is high (never low-context), and all
three accounts stay discoverable in Explore with complete cards.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

import date_sim
import dm_ops
import explore
import persona_snapshot
import practice_core
import public_profile
from fake_firestore import FakeDb

_BOOTSTRAP = Path(__file__).resolve().parent.parent
_REPO = _BOOTSTRAP.parent.parent


def _load_seed_module():
    """Import ``scripts/seed_demo_accounts.py`` without leaking its process-env
    defaults (``LLM_PROVIDER``/``FLAG_LLM_ROUTE_*``) or ``sys.path`` edit into
    the rest of the test session."""
    saved_env = dict(os.environ)
    saved_path = list(sys.path)
    try:
        spec = importlib.util.spec_from_file_location(
            "seed_demo_accounts", _REPO / "scripts" / "seed_demo_accounts.py"
        )
        module = importlib.util.module_from_spec(spec)
        sys.modules["seed_demo_accounts"] = module
        spec.loader.exec_module(module)
        return module
    finally:
        os.environ.clear()
        os.environ.update(saved_env)
        sys.path[:] = saved_path


seed = _load_seed_module()
PERSONAS = json.loads(
    (_REPO / "scripts" / "demo_seed" / "personas.json").read_text(encoding="utf-8")
)
BY_KEY = {p["key"]: p for p in PERSONAS["personas"]}

# The nine story page types prompts/demo_seed/story_pages.md requires.
STORY_PAGE_TYPES = (
    "identity",
    "career",
    "interests",
    "values",
    "lifestyle",
    "relationships",
    "family",
    "social_circle",
    "dealbreakers",
)

# Static story bodies in the seed's exact write shape (write_story persists
# {ai_body, visibility, page_type, title}; bodies come from Gemini live).
_STORY_BODIES = {
    "identity": "{name} is warm, bookish and grounded, with a dry quiet humour.",
    "career": "{name} loves craft and does careful, people-shaped work.",
    "interests": "{name} spends weekends on creative hobbies and small live shows.",
    "values": "{name} values honesty, slowness and showing up for people.",
    "lifestyle": "{name} keeps a calm homebody rhythm with early nights.",
    "relationships": "{name} is secure and talks things through with care.",
    "family": "{name} is close to family and calls home every week.",
    "social_circle": "{name} keeps a small circle of long, easy friendships.",
    "dealbreakers": "{name} cannot compromise on honesty, kindness or life goals.",
}


@pytest.fixture
def db(monkeypatch) -> FakeDb:
    """All three demo accounts as the seed leaves them (post-DM snapshot order).

    Story bodies are static (live they come from Gemini) but use the seed's
    exact doc shape; photos use the pipeline's grid + ``user_media`` shape with
    a stubbed Storage URL so the photo wiring is exercised, not the network.
    """
    monkeypatch.setattr(
        public_profile,
        "_photo_url",
        lambda path: f"https://cdn.example/{path}" if path else None,
    )
    fake = FakeDb()
    for persona in PERSONAS["personas"]:
        uid = persona["uid"]
        seed.write_profile_and_questionnaire(
            fake, persona, seed._qz_map(PERSONAS, persona["key"]),
            PERSONAS["location"],
        )
        seed.write_taste(fake, persona)
        wiki = fake.collection("users").document(uid).collection("wiki_pages")
        for page_type in STORY_PAGE_TYPES:
            wiki.document(page_type).set(
                {
                    "ai_body": _STORY_BODIES[page_type].format(
                        name=persona["first_name"]
                    ),
                    "visibility": "public",
                    "page_type": page_type,
                    "title": page_type.replace("_", " ").title(),
                }
            )
        media_ids = []
        for order, kind in enumerate(("face", "body", "candid")):
            mid = f"media-{uid}-{kind}"
            media_ids.append(mid)
            fake.collection("users").document(uid).collection(
                "user_media"
            ).document(mid).set(
                {
                    "storage_path": f"uploads/{uid}/seed_{kind}.jpg",
                    "moderation_status": "approved",
                    "attributes": {
                        "shot_type": "face" if kind == "face" else "full_body",
                        "usable_for_face": kind in ("face", "candid"),
                        "usable_for_body": kind in ("body", "candid"),
                    },
                }
            )
        fake.collection("users").document(uid).collection("profile").document(
            "main"
        ).set(
            {
                "photos": [
                    {"media_id": mid, "order": i}
                    for i, mid in enumerate(media_ids)
                ]
            },
            merge=True,
        )
    # Real DM threads (A sends first, short alternating texts — the
    # prompts/demo_seed/dm_thread.md rules), the source of style exemplars.
    pairs = (("test1", "test2"), ("test1", "test3"))
    for a_key, b_key in pairs:
        a, b = BY_KEY[a_key]["uid"], BY_KEY[b_key]["uid"]
        texts = [
            "Hey! Your profile caught my eye",
            "Hi! Thanks — yours too",
            "What does a perfect weekend look like for you?",
            "Studio time, then a small folk show",
            "That sounds ideal honestly",
            "What kind of music are you into?",
            "Folk and indie mostly, always",
            "Same here — we should swap playlists",
        ]
        for i, text in enumerate(texts):
            sender, other = (a, b) if i % 2 == 0 else (b, a)
            dm_ops.post_message(fake, sender, other, "text", text)
    # Snapshots AFTER the DMs (the seed's order) so style exemplars land.
    # distill=True like live, with a stubbed LLM so the test stays offline.
    async def _fake_distill(*args, **kwargs):
        return {"brief": "A warm creative homebody.", "story_highlights": ["art"]}

    monkeypatch.setattr(
        "practice_llm.generate_structured", _fake_distill
    )
    for persona in PERSONAS["personas"]:
        ctx = asyncio.run(
            persona_snapshot.build_persona_snapshot(fake, persona["uid"])
        )
        assert ctx is not None, f"no snapshot for {persona['key']}"
    # Persisted match docs (the scorer runs live; the card/report reads need
    # the doc shape persist_match writes).
    from pair_key import sorted_pair_key

    for a_key, b_key, score in (("test1", "test2", 0.99), ("test1", "test3", 0.25)):
        a, b = BY_KEY[a_key]["uid"], BY_KEY[b_key]["uid"]
        fake.collection("matches").document(sorted_pair_key(a, b)).set(
            {"uids": sorted([a, b]), "score": score, "status": "scored"}
        )
    return fake


def _adult_age(birthdate: str) -> int:
    from matching import _age

    age = _age(birthdate)
    assert age is not None
    return age


def test_personas_json_complete():
    """Every demo persona carries everything the seed + screens need."""
    assert PERSONAS["location"] == "San Jose, United States"
    assert [p["key"] for p in PERSONAS["personas"]] == ["test1", "test2", "test3"]
    for persona in PERSONAS["personas"]:
        assert persona["uid"].startswith("demo-test"), persona["key"]
        for field in (
            "email",
            "name",
            "first_name",
            "last_name",
            "gender",
            "birthdate",
            "headline",
            "brief",
        ):
            assert str(persona[field]).strip(), f"{persona['key']}.{field}"
        assert persona["interested_in"], f"{persona['key']}.interested_in"
        assert _adult_age(persona["birthdate"]) >= 18, persona["key"]
        assert 18 <= persona["partner_age_min"] <= persona["partner_age_max"]
        taste = persona["taste"]
        for domain in (
            "music",
            "film",
            "food",
            "tv",
            "books",
            "podcasts",
            "games",
            "travel",
            "brands",
        ):
            assert taste.get(domain), f"{persona['key']}.taste.{domain}"
        for kind in ("face", "body", "candid"):
            assert str(persona["image_prompts"].get(kind)).strip()
    assert PERSONAS["qz_shared_good"]["relationship_intent"] == "Long-term"
    assert "procreation_intent" in PERSONAS["qz_shared_good"]
    assert (
        PERSONAS["qz_overrides"]["test3"]["procreation_intent"]
        == "Absolutely non-negotiably childfree"
    )


def test_story_prompt_requires_nine_page_types():
    """The story template asks for exactly the nine pages the seed relies on."""
    template = (_REPO / "prompts" / "demo_seed" / "story_pages.md").read_text(
        encoding="utf-8"
    )
    assert "9 objects" in template
    for page_type in STORY_PAGE_TYPES:
        assert page_type in template, page_type


def test_seed_writes_complete_profiles(db: FakeDb):
    """profile/main + questionnaire leave nothing a screen reads blank."""
    for persona in PERSONAS["personas"]:
        uid = persona["uid"]
        prof = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        )
        for field in (
            "name",
            "first_name",
            "last_name",
            "gender",
            "birthdate",
            "location",
            "headline",
            "relationship_intent",
        ):
            assert prof.get(field), f"{persona['key']}.{field}"
        assert prof["interested_in"] == persona["interested_in"]
        assert prof["qz_partner_age_min"] == persona["partner_age_min"]
        assert prof["qz_partner_age_max"] == persona["partner_age_max"]
        assert prof["distance_pref"] == "50"
        assert prof["ai_avatar_enabled"] is True
        assert prof["paused"] is False
        assert prof["onboarding_complete"] is True
        assert len(prof["photos"]) == 3
        # The users/{uid} root doc must exist — Explore streams the users
        # collection, so subcollections alone leave the account invisible.
        assert (
            db.collection("users").document(uid).get().exists
        ), f"{persona['key']} root doc"
        qdocs = {
            s.id: (s.to_dict() or {}).get("value")
            for s in db.collection("users")
            .document(uid)
            .collection("questionnaire")
            .stream()
        }
        expected = seed._qz_map(PERSONAS, persona["key"])
        for node_id in list(expected) + ["partner_age_min", "partner_age_max"]:
            assert node_id in qdocs, f"{persona['key']}.{node_id}"
        assert qdocs["relationship_intent"] == "Long-term"


def test_taste_page_covers_all_domains(db: FakeDb):
    """The public Taste page spans all nine Qloo domains, non-empty."""
    for persona in PERSONAS["personas"]:
        taste = (
            db.collection("users")
            .document(persona["uid"])
            .collection("wiki_pages")
            .document("taste")
            .get()
            .to_dict()
        )
        assert taste["visibility"] == "public"
        body = taste["ai_body"]
        for header in (
            "Music",
            "Film",
            "Food",
            "TV",
            "Books",
            "Podcasts",
            "Games",
            "Travel",
            "Brands",
        ):
            line = next(
                (ln for ln in body.splitlines() if ln.startswith(f"{header}:")),
                "",
            )
            assert line.split(":", 1)[1].strip(), f"{persona['key']}.{header}"


def test_public_profile_renders_full(db: FakeDb):
    """The viewer-visible profile (Explore tap-through + persona source)."""
    t1, t2, t3 = (BY_KEY[k]["uid"] for k in ("test1", "test2", "test3"))
    for viewer, target in ((t1, t2), (t1, t3), (t2, t1)):
        view = public_profile.build(db, viewer, target)
        assert view is not None, (viewer, target)
        assert view["name"] == BY_KEY[
            next(k for k in BY_KEY if BY_KEY[k]["uid"] == target)
        ]["name"]
        assert view["age"] and view["age"] >= 18
        assert view["gender"]
        assert view["location"]
        assert len(view["photos"]) == 3
        assert all(p.startswith("https://") for p in view["photos"])
        # Nine story pages + taste, every one with a body.
        assert len(view["pages"]) == 10, [p["title"] for p in view["pages"]]
        assert all(p["body"].strip() for p in view["pages"])
        assert not view["blocked"] and not view.get("deleted")
    assert public_profile.build(db, t1, t2)["score"] == 0.99
    assert public_profile.build(db, t1, t3)["score"] == 0.25


def test_practice_date_flow_end_to_end_offline(db: FakeDb):
    """Persona context → prompt → session store, both demo pairs."""
    t1, t2, t3 = (BY_KEY[k]["uid"] for k in ("test1", "test2", "test3"))
    assert practice_core.build_persona_context(db, t1, "nobody") is None
    for viewer, target in ((t1, t2), (t1, t3)):
        ctx = practice_core.build_persona_context(db, viewer, target)
        assert ctx is not None, (viewer, target)
        assert ctx.name and ctx.age and ctx.gender and ctx.location
        assert len(ctx.pages) == 10
        assert ctx.photo_count == 3
        prompt = practice_core.compose_persona_prompt(ctx)
        assert ctx.name in prompt
        assert any(
            p["body"][:40] in prompt for p in ctx.pages
        ), "story grounding reaches the persona"
        sid = practice_core.start_session(db, viewer, target)
        turns = practice_core.append_turns(
            db,
            viewer,
            sid,
            [
                {"role": practice_core.ROLE_USER, "text": "Hi!"},
                {"role": practice_core.ROLE_MATCH, "text": "Hey there!"},
            ],
        )
        assert [t["role"] for t in turns] == ["user", "match"]
        practice_core.end_session(db, viewer, sid)
        assert practice_core._load_session(db, viewer, sid)["ended_at"]
    assert practice_core.compose_coach_prompt()
    assert practice_core.compose_debrief_prompt()


def test_date_sim_personas_ground_offline(db: FakeDb):
    """Both sim sides spawn with style, depth and high readiness."""
    t1, t2, t3 = (BY_KEY[k]["uid"] for k in ("test1", "test2", "test3"))
    for uid in (t1, t2, t3):
        snap = (
            db.collection("users")
            .document(uid)
            .collection("persona")
            .document("avatar")
            .get()
            .to_dict()
        )
        assert snap["grounding"]["name"]
        assert len(snap["grounding"]["pages"]) >= 10
        # Built after the DMs, so the user's own texting style landed.
        assert snap["grounding"]["style_exemplars"], uid
        assert snap["distilled"] is True
        assert snap["stale"] is False
    for viewer, target in ((t1, t2), (t1, t3)):
        self_ctx = persona_snapshot.get_persona_snapshot(db, viewer)
        match_ctx = persona_snapshot.get_persona_snapshot(db, target)
        assert self_ctx is not None and match_ctx is not None
        assert self_ctx.style_exemplars
        for ctx, speaker, other, role in (
            (self_ctx, self_ctx.name, match_ctx.name, date_sim.ROLE_YOU),
            (match_ctx, match_ctx.name, self_ctx.name, date_sim.ROLE_THEM),
        ):
            system, message = date_sim.compose_sim_prompt(
                ctx, speaker, other, [], role
            )
            assert speaker in system and other in system
            assert ctx.name in system and message
            readiness = persona_snapshot.readiness_for_context(ctx)
            assert readiness["low_context"] is False, (speaker, readiness)
            assert readiness["readiness_score"] >= 80, readiness
        preflight = persona_snapshot.preflight_readiness(db, viewer, target)
        assert preflight is not None
        assert preflight["low_context"] is False
        assert "message" not in preflight


def test_demo_accounts_discoverable_in_explore(db: FakeDb):
    """Each demo account sees the other two in Explore with full cards."""
    t1, t2, t3 = (BY_KEY[k]["uid"] for k in ("test1", "test2", "test3"))
    for viewer, others in ((t1, (t2, t3)), (t2, (t1,)), (t3, (t1,))):
        prof = (
            db.collection("users")
            .document(viewer)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        )
        cards = explore.explore(
            db, viewer, explore.apply_saved_age_range({}, prof), limit=100
        )
        by_uid = {c["uid"]: c for c in cards}
        for other in others:
            assert other in by_uid, (viewer, other)
            card = by_uid[other]
            assert card["name"] and card["age"] and card["location"]
            assert card["photo_url"].startswith("https://")
