"""LinkedIn work-history import → dated career nodes (founder order Nov 18 2026).

Covers the data-export route (the only route that can deliver dated positions —
official LinkedIn OIDC grants name/email/picture only, no work history): parse a
sample ``Positions.csv`` into dated career nodes (role/company/period, node-level
``dated`` set, ``linkedin_import`` source carried); the Career timeline orders
the imported roles most-recent-first; an imported role that restates an existing
prose career note is FOLDED (one node, moved onto the timeline), never two; and a
re-import is idempotent.
"""

from __future__ import annotations

import linkedin_import
import person_graph_store as store
import person_graph_tree as tree
from fake_firestore import FakeDb

UID = "u_linkedin"

# A representative LinkedIn data-export Positions.csv (the real column set + the
# "MMM YYYY" date format the modern export ships; a current role has a blank
# Finished On).
SAMPLE_CSV = (
    "Company Name,Title,Description,Location,Started On,Finished On\n"
    "Globex,Staff Engineer,Led the payments platform.,Remote,Mar 2023,\n"
    "Initech,Senior Engineer,Built the billing service.,San Jose CA,Jan 2020,Dec 2022\n"
    "Acme Corp,Software Engineer,First job out of school.,San Jose CA,Jun 2015,Dec 2019\n"
)


def _career_nodes(db, uid):
    graph = store.effective(db, uid)
    t = tree.node_tree(graph, surface="story")
    for section in t["sections"]:
        if section["page_type"] == "career":
            return section["nodes"]
    return []


# --- parse ------------------------------------------------------------------


def test_parse_positions_csv_dates_company_title_period():
    positions = linkedin_import.parse_positions_csv(SAMPLE_CSV)
    assert len(positions) == 3
    globex = positions[0]
    assert globex.company == "Globex"
    assert globex.title == "Staff Engineer"
    assert globex.started_iso == "2023-03"       # Mar 2023 → ISO sort key
    assert globex.is_current is True             # blank Finished On
    assert globex.period == "Mar 2023 – Present"
    assert globex.dated == "2023-03"

    initech = positions[1]
    assert initech.finished_iso == "2022-12"
    assert initech.is_current is False
    assert initech.period == "Jan 2020 – Dec 2022"


def test_parse_rejects_non_positions_file():
    import pytest

    with pytest.raises(ValueError):
        linkedin_import.parse_positions_csv("some,random\nfile,contents\n")


def test_parse_tolerates_iso_dates_and_blank_rows():
    csv_text = (
        "Company Name,Title,Started On,Finished On\n"
        ",,,\n"  # blank row — skipped
        "Hooli,Intern,2014-06-01,2014-09-01\n"
    )
    positions = linkedin_import.parse_positions_csv(csv_text)
    assert len(positions) == 1
    assert positions[0].started_iso == "2014-06-01"


# --- import → dated career nodes -------------------------------------------


def test_import_creates_dated_career_nodes_with_source():
    db = FakeDb()
    result = linkedin_import.import_csv(db, UID, SAMPLE_CSV)
    assert result["created"] == 3
    overlay = store.load_overlay(db, UID)
    linkedin_nodes = {k: v for k, v in overlay.items() if k.startswith("linkedin.")}
    assert len(linkedin_nodes) == 3
    for node in linkedin_nodes.values():
        assert node["section"] == "career"
        assert node["dated"]                       # node-level date set
        assert node["source_kind"] == "linkedin_import"
        assert node["source_ref"] == "linkedin_export"
        assert node["visual"]["type"] == "timeline_entry"
        assert node["visibility"] == "private"     # career details private by default


def test_timeline_orders_most_recent_first():
    db = FakeDb()
    linkedin_import.import_csv(db, UID, SAMPLE_CSV)
    nodes = _career_nodes(db, UID)
    dated = [n["dated"] for n in nodes if n.get("dated")]
    assert dated == ["2023-03", "2020-01", "2015-06"]  # most recent first


def test_import_dedupes_existing_prose_note():
    db = FakeDb()
    # The user already wrote this role as a prose career note (no dates).
    prose_id = store.add_loose_node(
        db, UID,
        "I was a Senior Engineer at Initech working on billing.",
        section="career",
    )
    result = linkedin_import.import_csv(db, UID, SAMPLE_CSV)
    overlay = store.load_overlay(db, UID)
    # The Initech role folded into the prose note — no second Initech node.
    assert result["folded"] == 1
    assert result["created"] == 2
    initech_nodes = [
        k for k, v in overlay.items()
        if v.get("section") == "career" and "initech" in str(v).lower()
    ]
    assert initech_nodes == [prose_id]             # exactly one Initech node
    assert overlay[prose_id]["dated"] == "2020-01"  # now dated → on the timeline
    assert overlay[prose_id]["visual"]["type"] == "timeline_entry"


def test_reimport_is_idempotent():
    db = FakeDb()
    linkedin_import.import_csv(db, UID, SAMPLE_CSV)
    first = store.load_overlay(db, UID)
    result = linkedin_import.import_csv(db, UID, SAMPLE_CSV)
    second = store.load_overlay(db, UID)
    assert result["updated"] == 3 and result["created"] == 0
    # No new nodes minted on re-import.
    assert set(first) == set(second)
    assert len([k for k in second if k.startswith("linkedin.")]) == 3
