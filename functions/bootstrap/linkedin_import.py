"""LinkedIn work-history import → dated career nodes (founder order Nov 18 2026).

WHY THE DATA-EXPORT ROUTE, not OAuth: the official "Sign In with LinkedIn using
OpenID Connect" product grants only ``openid``/``profile``/``email`` — its
``claims_supported`` is name, email and picture, with NO positions / work
history (verified against learn.microsoft.com's OIDC reference, Nov 2026).
Work history over the API needs a restricted partner program Ayma is not in. So
the user's own LinkedIn data archive is the route: LinkedIn → Settings → "Get a
copy of your data" ships a ``Positions.csv`` (Company Name, Title, Description,
Location, Started On, Finished On). The user uploads that file; Ayma parses it
deterministically — no LinkedIn credentials in the app, no scraping, no network
call to LinkedIn — into DATED career nodes so the Career timeline finally fills.

Each imported role becomes an emergent node in the ``career`` section carrying a
node-level ``dated`` (the start date, the timeline's most-recent-first sort key),
a ``timeline_entry`` visual, and the ``linkedin_import`` SOURCE (node-sources
rule). A role that restates an existing prose career note is FOLDED into it
(enriched with the dates, moved onto the timeline) — never a second node for the
same role. A re-import keys onto a stable per-role id, so it is idempotent.
"""

from __future__ import annotations

import csv
import datetime as _dt
import io
import re
from dataclasses import dataclass

import node_visual
import person_graph_index as index
import person_graph_store as store
from person_graph import Provenance

CAREER_SECTION = "career"
SOURCE_KIND = "linkedin_import"

# A per-role node id is stable (company+title slug), so a re-import updates the
# same node instead of minting a duplicate.
_NODE_PREFIX = "linkedin"

_MAX_DESC = 600  # cap an imported description so one node never bloats the graph
_MAX_ROWS = 500  # a sane ceiling on a single archive's positions

# Header aliases — the modern export is "Company Name,Title,Description,Location,
# Started On,Finished On", but accept small variations defensively.
_HEADERS = {
    "company": ("company name", "company", "organization", "organisation"),
    "title": ("title", "position", "role", "job title"),
    "description": ("description", "summary"),
    "location": ("location",),
    "started": ("started on", "start date", "started", "from"),
    "finished": ("finished on", "end date", "finished", "ended", "to"),
}

# Date formats LinkedIn's export has used, newest first. Finished-On is blank for
# a current role.
_DATE_FORMATS = (
    ("%b %Y", "%m"),      # Jan 2020
    ("%B %Y", "%m"),      # January 2020
    ("%Y-%m-%d", "%d"),   # 2020-01-15
    ("%b %d, %Y", "%d"),  # Jan 15, 2020
    ("%m/%d/%Y", "%d"),   # 01/15/2020
    ("%Y-%m", "%m"),      # 2020-01
    ("%Y", "%y"),         # 2020
)


@dataclass(frozen=True)
class Position:
    """One parsed LinkedIn role."""

    company: str
    title: str
    description: str
    location: str
    started_iso: str      # sort key: "YYYY" / "YYYY-MM" / "YYYY-MM-DD" ("" if none)
    finished_iso: str
    started_display: str   # human text as it appeared ("Jan 2020"), "" if none
    finished_display: str
    is_current: bool       # Finished On blank → current role

    @property
    def dated(self) -> str:
        """The timeline sort key — the start date, else the end date."""
        return self.started_iso or self.finished_iso

    @property
    def period(self) -> str:
        if self.started_display and self.finished_display:
            return f"{self.started_display} – {self.finished_display}"
        if self.started_display and self.is_current:
            return f"{self.started_display} – Present"
        if self.started_display:
            return self.started_display
        if self.finished_display:
            return f"Until {self.finished_display}"
        return ""

    @property
    def gist(self) -> str:
        head = self.title or self.company
        if self.title and self.company:
            head = f"{self.title} · {self.company}"
        return head[:80]

    @property
    def text(self) -> str:
        if self.title and self.company:
            line = f"{self.title} at {self.company}"
        else:
            line = self.title or self.company
        if self.period:
            line = f"{line} ({self.period})"
        if self.description:
            line = f"{line}. {self.description}"
        return line

    @property
    def node_id(self) -> str:
        return f"{_NODE_PREFIX}.{_slug(self.company)}__{_slug(self.title)}"

    @property
    def visual(self) -> dict:
        return node_visual.timeline_entry(self.gist, self.period or self.started_display)


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (text or "").lower()).strip("_")
    return s[:48] or "role"


def _parse_date(raw: str) -> tuple[str, str]:
    """``(iso_sort_key, display)`` for one LinkedIn date cell. Blank → ``("", "")``
    (a current role's Finished On). Tolerant of the formats the export has shipped;
    an unrecognised but non-empty value is kept verbatim as the display with no
    sort key so the role still renders (just unordered)."""
    s = (raw or "").strip()
    if not s:
        return "", ""
    for fmt, precision in _DATE_FORMATS:
        try:
            dt = _dt.datetime.strptime(s, fmt)
        except ValueError:
            continue
        if precision == "%y":
            return f"{dt.year:04d}", s
        if precision == "%m":
            return f"{dt.year:04d}-{dt.month:02d}", s
        return f"{dt.year:04d}-{dt.month:02d}-{dt.day:02d}", s
    return "", s


def _norm_headers(fieldnames: list[str] | None) -> dict[str, str]:
    """Map our canonical keys → the actual column name in this file."""
    out: dict[str, str] = {}
    for raw in fieldnames or []:
        key = (raw or "").strip().lower()
        for canon, aliases in _HEADERS.items():
            if key in aliases and canon not in out:
                out[canon] = raw
    return out


def parse_positions_csv(text: str) -> list[Position]:
    """Parse the ``Positions.csv`` from a LinkedIn data archive into
    :class:`Position` rows. Deterministic, no network, no LLM. Rows missing both a
    company and a title are skipped; parsing is tolerant of header-name and
    date-format variation. Raises ``ValueError`` only when the file has no
    recognisable Company/Title columns at all (not a positions export)."""
    text = text or ""
    # LinkedIn sometimes prefixes a "Notes:" preamble before the header row; skip
    # to the first line that looks like the CSV header.
    reader = csv.DictReader(io.StringIO(text))
    cols = _norm_headers(reader.fieldnames)
    if "company" not in cols and "title" not in cols:
        raise ValueError(
            "that file has no Company Name / Title columns — upload the "
            "Positions.csv from your LinkedIn data export"
        )
    out: list[Position] = []
    for row in reader:
        if len(out) >= _MAX_ROWS:
            break
        company = (row.get(cols.get("company", ""), "") or "").strip()
        title = (row.get(cols.get("title", ""), "") or "").strip()
        if not company and not title:
            continue
        description = (row.get(cols.get("description", ""), "") or "").strip()[:_MAX_DESC]
        location = (row.get(cols.get("location", ""), "") or "").strip()
        started_iso, started_display = _parse_date(row.get(cols.get("started", ""), ""))
        finished_raw = (row.get(cols.get("finished", ""), "") or "").strip()
        finished_iso, finished_display = _parse_date(finished_raw)
        out.append(
            Position(
                company=company,
                title=title,
                description=description,
                location=location,
                started_iso=started_iso,
                finished_iso=finished_iso,
                started_display=started_display,
                finished_display=finished_display,
                is_current=not finished_raw,
            )
        )
    return out


def _role_match_id(graph, pos: Position) -> str | None:
    """The id of an existing CAREER-section node that restates this role — an
    overlay (emergent) node whose content tokens contain BOTH the company tokens
    and the title tokens (deterministic, order-insensitive). Used to FOLD a role
    the user already wrote in prose instead of minting a second node. A LinkedIn
    import node (``linkedin.*``) is never a fold target (it IS the import).
    Needs a non-empty company AND title to match — a bare company or title alone
    is too weak to fold on."""
    company_tok = index.token_set(pos.company)
    title_tok = index.token_set(pos.title)
    if not company_tok or not title_tok:
        return None
    for nid, node in graph.items():
        if nid.startswith(f"{_NODE_PREFIX}.") or node.section != CAREER_SECTION:
            continue
        if not getattr(node, "emergent", False):
            continue
        node_tok = index.token_set(index.content_text(node))
        if company_tok <= node_tok and title_tok <= node_tok:
            return nid
    return None


def import_positions(
    db, uid: str, positions: list[Position], *, source_ref: str = "linkedin_export"
) -> dict:
    """Write parsed positions as dated career nodes, deduping against existing
    prose career notes. For each role:

    * it restates an existing prose career note → FOLD into it (enrich with the
      dates) and move it onto the timeline (``created``/``folded`` — one node);
    * its own stable import node already exists → update it (idempotent re-import);
    * otherwise → create a new dated career node.

    Returns a summary ``{"positions", "created", "updated", "folded", "skipped",
    "node_ids"}``."""
    summary = {
        "positions": len(positions),
        "created": 0,
        "updated": 0,
        "folded": 0,
        "skipped": 0,
        "node_ids": [],
    }
    for pos in positions:
        if not pos.dated and not (pos.company or pos.title):
            summary["skipped"] += 1
            continue
        graph = store.effective(db, uid)
        nid = pos.node_id
        # 1. Idempotent re-import: our own node already exists → refresh it.
        if nid in graph:
            store.fold_into_node(
                db, uid, nid, pos.text,
                source_kind=SOURCE_KIND, source_ref=source_ref,
                gist=pos.gist, provenance=Provenance.IMPORTED,
            )
            store.set_node_dated(db, uid, nid, pos.dated, visual=pos.visual)
            summary["updated"] += 1
            summary["node_ids"].append(nid)
            continue
        # 2. Dedupe vs an existing prose career note → fold into it, no duplicate.
        match = _role_match_id(graph, pos)
        if match is not None:
            store.fold_into_node(
                db, uid, match, pos.text,
                source_kind=SOURCE_KIND, source_ref=source_ref,
                gist=pos.gist, provenance=Provenance.IMPORTED,
            )
            store.set_node_dated(db, uid, match, pos.dated, visual=pos.visual)
            summary["folded"] += 1
            summary["node_ids"].append(match)
            continue
        # 3. A genuinely new role → a fresh dated career node.
        store.add_loose_node(
            db, uid, pos.text,
            label=pos.gist,
            section=CAREER_SECTION,
            node_id=nid,
            source_kind=SOURCE_KIND,
            source_ref=source_ref,
            gist=pos.gist,
            visual=pos.visual,
            dated=pos.dated,
            provenance=Provenance.IMPORTED,
        )
        summary["created"] += 1
        summary["node_ids"].append(nid)
    return summary


def import_csv(db, uid: str, csv_text: str, *, source_ref: str = "linkedin_export") -> dict:
    """Parse a ``Positions.csv`` and import it — the single call the endpoint
    makes. Raises ``ValueError`` when the file is not a positions export."""
    positions = parse_positions_csv(csv_text)
    result = import_positions(db, uid, positions, source_ref=source_ref)
    result["parsed"] = len(positions)
    return result
