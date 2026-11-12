"""Demo seed data for Practice Date (hackathon deliverable B).

Four judge-ready demo profiles, each deliberately carrying NEVER-LOAD needles
(street address, phone, email, GPS coordinates, a person they're also seeing,
and private / ai-only wiki notes) so the privacy extraction test
(``tests/test_practice_extraction.py``) can prove none of it reaches the
persona context. The same data drives the live demo via
``scripts/seed_practice_profiles.py``.

Each profile also carries a public "Taste" page (music / film / food
favourites) that drives the Qloo taste match (``taste_match.py``).

Shape mirrors production: ``users/{uid}/profile/main`` plus
``users/{uid}/wiki_pages/{page_id}`` with a ``visibility`` of
``public`` | ``private`` | ``ai_only`` and a ``{{private}}`` span inside one
public body. Nothing here is a real person.
"""

from __future__ import annotations

# All practice-date simulator personas share this uid prefix (see
# ``DEMO_PROFILES`` below). They are never real accounts, so Explore and
# matching candidate sourcing exclude them (BUG E).
DEMO_PRACTICE_UID_PREFIX = "demo_practice_"


def is_practice_persona(uid: str) -> bool:
    """``True`` for a practice-date simulator persona (``demo_practice_*``) —
    a seeded, non-real account that must never appear in the live Explore feed
    or the matching candidate pool."""
    return str(uid or "").startswith(DEMO_PRACTICE_UID_PREFIX)


# The known hackathon demo/judge fixture accounts (docs/DEMO_ACCOUNTS.md): the
# curated ``demo-test1/2/3`` personas (Daniel / Sofia / Priya) and the
# ``demo-edge-*`` corner-case accounts. All AI-generated, never real people.
DEMO_FIXTURE_UIDS = frozenset({"demo-test1", "demo-test2", "demo-test3"})
DEMO_EDGE_UID_PREFIX = "demo-edge-"


def is_demo_fixture_account(uid: str) -> bool:
    """``True`` for a known AI-generated demo/judge fixture account — the
    curated ``demo-test1/2/3`` personas and any ``demo-edge-*`` account. These
    are seeded, non-real profiles that must always carry the "AI-generated
    profile" label even when their profile doc is missing the explicit
    ``ai_generated`` field (e.g. after a re-seed that predates the flag, or a
    profile that was never backfilled). A real user matches neither."""
    u = str(uid or "")
    return u in DEMO_FIXTURE_UIDS or u.startswith(DEMO_EDGE_UID_PREFIX)


# Each entry: the public, viewer-visible profile; the wiki pages (mixed
# visibility, with one public body hiding a {{private}} span); and `secrets`,
# the exact needle strings the extraction test asserts never leak.
DEMO_PROFILES: list[dict] = [
    {
        "uid": "demo_practice_maya",
        "profile": {
            # AI-generated demo persona — the explicit marker that drives the
            # "AI-generated profile" label on the profile header (public_profile.build).
            "ai_generated": True,
            "name": "Maya",  # PUBLIC display name (first name only) — usable
            "gender": "woman",
            "birthdate": "1995-07-14",
            "location": "San Francisco",  # coarse city only (viewer-visible)
            # --- NEVER-LOAD: present on the record, never in the public view ---
            # Stored identity fields the serializer never returns: a family name
            # Maya did NOT put in her display name, and an employer that is not
            # on any public page (her public "about" says only her field of
            # work, "Ceramicist"). public_profile.build exposes just `name`.
            "last_name": "Okonkwo",
            "workplace": "Lumina Studios",
            "home_address": "412 Fillmore St, Apt 3B, San Francisco",
            "phone": "+1-415-555-0142",
            "email": "maya.secret@example.com",
            "exact_coordinates": {"lat": 37.7731, "lng": -122.4309},
            "photos": [],
        },
        "wiki_pages": [
            {
                "id": "taste",
                "visibility": "public",
                "page_type": "taste",
                "title": "Taste",
                "ai_body": "Music: Khruangbin, Bon Iver, Phoebe Bridgers\nFilm: Lost in Translation, Amélie, Spirited Away\nFood: Tartine Bakery, Zuni Café",
            },
            {
                "id": "about",
                "visibility": "public",
                "page_type": "about",
                "title": "About Maya",
                "ai_body": (
                    "Ceramicist and weekend trail runner. Grew up in Chicago, "
                    "moved west for the light. Dry, warm sense of humour; will "
                    "talk your ear off about glaze chemistry. "
                    "{{private}}Actually still hung up on my ex Daniel, phone "
                    "+1-415-555-0142.{{/private}}"
                ),
            },
            {
                "id": "looking_for",
                "visibility": "public",
                "page_type": "dating",
                "title": "What I'm looking for",
                "ai_body": "Someone curious and kind who can make me laugh.",
            },
            {
                "id": "prompts",
                "visibility": "public",
                "page_type": "prompts",
                "title": "Prompts",
                "ai_body": (
                    "Two truths and a lie: I've fired 300 mugs this year, I "
                    "sold a pot to someone semi-famous, I can parallel park on "
                    "the first try. · We'll get along if you let me drag you to "
                    "a pottery studio and pretend you hate it. · Unusually good "
                    "at: salvaging a glaze that was about to crack."
                ),
            },
            {
                "id": "private_notes",
                "visibility": "private",
                "page_type": "misc",
                "title": "Private",
                "ai_body": (
                    "Home address 412 Fillmore St Apt 3B. Also seeing someone "
                    "named Chris from the climbing gym."
                ),
            },
            {
                "id": "ai_notes",
                "visibility": "ai_only",
                "page_type": "ai_notes",
                "title": "Ayma's notes",
                "ai_body": "Reach via maya.secret@example.com. Anxious attachment.",
            },
        ],
        "secrets": [
            "Okonkwo",  # stored last name — NOT part of her display name
            "Lumina Studios",  # stored employer — NOT on any public page
            "412 Fillmore St",
            "+1-415-555-0142",
            "maya.secret@example.com",
            "37.7731",
            "-122.4309",
            "Daniel",
            "Chris",
            "Anxious attachment",
        ],
    },
    {
        "uid": "demo_practice_leo",
        "profile": {
            "ai_generated": True,  # AI-generated demo persona (see Maya above)
            "name": "Leo",
            "gender": "man",
            "birthdate": "1990-02-03",
            "location": "Oakland",
            "home_address": "88 Grand Ave, Oakland",
            "phone": "+1-510-555-0199",
            "email": "leo.private@example.com",
            "exact_coordinates": {"lat": 37.8095, "lng": -122.2650},
            "photos": [],
        },
        "wiki_pages": [
            {
                "id": "taste",
                "visibility": "public",
                "page_type": "taste",
                "title": "Taste",
                "ai_body": "Music: Thelonious Monk, Khruangbin, Kamasi Washington\nFilm: Blade Runner 2049, Arrival, Spirited Away\nFood: Ramen Shop, Blue Bottle Coffee",
            },
            {
                "id": "about",
                "visibility": "public",
                "page_type": "about",
                "title": "About Leo",
                "ai_body": (
                    "Jazz drummer, part-time barista, full-time plant dad. "
                    "Reads sci-fi, cooks a mean ramen."
                ),
            },
            {
                "id": "looking_for",
                "visibility": "public",
                "page_type": "dating",
                "title": "What I'm looking for",
                "ai_body": (
                    "A partner in low-key adventures — someone to split a late "
                    "set and a bowl of noodles with, who's kind to waiters and "
                    "houseplants alike."
                ),
            },
            {
                "id": "prompts",
                "visibility": "public",
                "page_type": "prompts",
                "title": "Prompts",
                "ai_body": (
                    "The way to my heart: cook with me and don't panic when "
                    "the kitchen's (metaphorically) on fire. · My simple "
                    "pleasures: a clean practice-pad session, a watered "
                    "monstera, and ramen near midnight. · First-round question "
                    "I'll ask you: window seat or aisle, and why you're wrong."
                ),
            },
            {
                "id": "private_notes",
                "visibility": "private",
                "page_type": "misc",
                "title": "Private",
                "ai_body": "Lives at 88 Grand Ave. Matched with Priya last week.",
            },
        ],
        "secrets": [
            "88 Grand Ave",
            "+1-510-555-0199",
            "leo.private@example.com",
            "37.8095",
            "Priya",
        ],
    },
    {
        "uid": "demo_practice_aisha",
        "profile": {
            "ai_generated": True,  # AI-generated demo persona (see Maya above)
            "name": "Aisha",
            "gender": "woman",
            "birthdate": "1998-11-21",
            "location": "Berkeley",
            "home_address": "1500 Shattuck Ave, Berkeley",
            "phone": "+1-510-555-0177",
            "email": "aisha.hidden@example.com",
            "exact_coordinates": {"lat": 37.8796, "lng": -122.2690},
            "photos": [],
        },
        "wiki_pages": [
            {
                "id": "taste",
                "visibility": "public",
                "page_type": "taste",
                "title": "Taste",
                "ai_body": "Music: Bon Iver, Fleet Foxes, Phoebe Bridgers\nFilm: My Octopus Teacher, Finding Nemo, Free Solo\nFood: Tartine Bakery, Cheese Board Collective",
            },
            {
                "id": "about",
                "visibility": "public",
                "page_type": "about",
                "title": "About Aisha",
                "ai_body": (
                    "PhD student in marine biology. Climbs, bakes sourdough, "
                    "terrible at board games but very competitive."
                ),
            },
            {
                "id": "looking_for",
                "visibility": "public",
                "page_type": "dating",
                "title": "What I'm looking for",
                "ai_body": (
                    "Someone curious and a little competitive — up for "
                    "tide-pooling at dawn and losing graciously at Scrabble."
                ),
            },
            {
                "id": "prompts",
                "visibility": "public",
                "page_type": "prompts",
                "title": "Prompts",
                "ai_body": (
                    "I geek out about: tide pools, sourdough starters, and why "
                    "board games are serious business. · A review from a "
                    "friend: 'competitive to a fault, will absolutely cheat at "
                    "Monopoly, worth it.' · Date idea I'll actually say yes to: "
                    "the aquarium, then arguing about the best exhibit over tea."
                ),
            },
            {
                "id": "ai_notes",
                "visibility": "ai_only",
                "page_type": "ai_notes",
                "title": "Ayma's notes",
                "ai_body": "Contact aisha.hidden@example.com. Also dating Sameer.",
            },
        ],
        "secrets": [
            "1500 Shattuck Ave",
            "+1-510-555-0177",
            "aisha.hidden@example.com",
            "37.8796",
            "Sameer",
        ],
    },
    {
        "uid": "demo_practice_noah",
        "profile": {
            "ai_generated": True,  # AI-generated demo persona (see Maya above)
            "name": "Noah",
            "gender": "man",
            "birthdate": "1993-05-09",
            "location": "San Jose",
            "home_address": "27 Alameda, San Jose",
            "phone": "+1-408-555-0123",
            "email": "noah.offgrid@example.com",
            "exact_coordinates": {"lat": 37.3382, "lng": -121.8863},
            "photos": [],
        },
        "wiki_pages": [
            {
                "id": "taste",
                "visibility": "public",
                "page_type": "taste",
                "title": "Taste",
                "ai_body": "Music: Fleet Foxes, The Lumineers, Kamasi Washington\nFilm: Free Solo, Into the Wild, Blade Runner 2049\nFood: Blue Bottle Coffee, Philz Coffee",
            },
            {
                "id": "about",
                "visibility": "public",
                "page_type": "about",
                "title": "About Noah",
                "ai_body": (
                    "Backend engineer who'd rather be backpacking. Quiet until "
                    "he isn't. Big on dumb puns and good coffee."
                ),
            },
            {
                "id": "looking_for",
                "visibility": "public",
                "page_type": "dating",
                "title": "What I'm looking for",
                "ai_body": (
                    "A low-drama human who likes the outdoors, long drives, and "
                    "will tolerate my puns long enough to start liking them."
                ),
            },
            {
                "id": "prompts",
                "visibility": "public",
                "page_type": "prompts",
                "title": "Prompts",
                "ai_body": (
                    "My ideal first date: a trailhead, questionable trail mix, "
                    "and worse puns. · I'm weirdly good at: finding the one "
                    "coffee shop worth the detour. · Green flag I look for: you "
                    "have a comfort movie and you're not embarrassed about it."
                ),
            },
            {
                "id": "private_notes",
                "visibility": "private",
                "page_type": "misc",
                "title": "Private",
                "ai_body": "Address 27 Alameda. Still texting an ex, Jordan.",
            },
        ],
        "secrets": [
            "27 Alameda",
            "+1-408-555-0123",
            "noah.offgrid@example.com",
            "121.8863",
            "Jordan",
        ],
    },
]


def seed(db) -> list[str]:
    """Write the demo profiles and their wiki pages into ``db``. Returns the
    list of seeded uids. Idempotent: re-running overwrites the same docs."""
    uids: list[str] = []
    for entry in DEMO_PROFILES:
        uid = entry["uid"]
        uids.append(uid)
        user = db.collection("users").document(uid)
        user.collection("profile").document("main").set(dict(entry["profile"]))
        for page in entry["wiki_pages"]:
            user.collection("wiki_pages").document(page["id"]).set(
                {
                    "visibility": page["visibility"],
                    "page_type": page["page_type"],
                    "title": page["title"],
                    "ai_body": page["ai_body"],
                }
            )
    return uids


def all_secrets() -> list[str]:
    """Every never-load needle across all demo profiles (for the test)."""
    out: list[str] = []
    for entry in DEMO_PROFILES:
        out.extend(entry["secrets"])
    return out
