"""Demo seed data for Practice Date (hackathon deliverable B).

Four judge-ready demo profiles, each deliberately carrying NEVER-LOAD needles
(street address, phone, email, GPS coordinates, a person they're also seeing,
and private / ai-only wiki notes) so the privacy extraction test
(``tests/test_practice_extraction.py``) can prove none of it reaches the
persona context. The same data drives the live demo via
``scripts/seed_practice_profiles.py``.

Shape mirrors production: ``users/{uid}/profile/main`` plus
``users/{uid}/wiki_pages/{page_id}`` with a ``visibility`` of
``public`` | ``private`` | ``ai_only`` and a ``{{private}}`` span inside one
public body. Nothing here is a real person.
"""

from __future__ import annotations

# Each entry: the public, viewer-visible profile; the wiki pages (mixed
# visibility, with one public body hiding a {{private}} span); and `secrets`,
# the exact needle strings the extraction test asserts never leak.
DEMO_PROFILES: list[dict] = [
    {
        "uid": "demo_practice_maya",
        "profile": {
            "name": "Maya",
            "birthdate": "1995-07-14",
            "location": "San Francisco",  # coarse city only (viewer-visible)
            # --- NEVER-LOAD: present on the record, never in the public view ---
            "home_address": "412 Fillmore St, Apt 3B, San Francisco",
            "phone": "+1-415-555-0142",
            "email": "maya.secret@example.com",
            "exact_coordinates": {"lat": 37.7731, "lng": -122.4309},
            "photos": [],
        },
        "wiki_pages": [
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
            "name": "Leo",
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
            "name": "Aisha",
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
            "name": "Noah",
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
