#!/usr/bin/env python3
"""Verify the three demo/judge accounts (docs/DEMO_ACCOUNTS.md) end to end.

Read-only (except it runs taste_match / score_pair, which may write cache docs).
Prints concrete evidence for every hard requirement: profiles complete, photos +
attributes, story, Ayma conversation, appearance report, AI avatar, the good vs
bad taste_match and match scores, Explore discoverability for the founder, the
scoped email-verify bypass, the per-uid flag override, DMs, a live avatar
reply, Practice Date persona readiness, date-sim snapshot readiness, and
story/taste coverage. Run from the repo root:
python3 scripts/verify_demo_accounts.py
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "ayma-ai")
os.environ.setdefault("LLM_PROVIDER", "gemini")  # all surfaces -> Vertex Gemini
for _g in ("JSON", "VISION", "CHAT"):
    os.environ.setdefault(f"FLAG_LLM_ROUTE_{_g}", "vertex")

_ROOT = Path(__file__).resolve().parent.parent
_BOOTSTRAP = _ROOT / "functions" / "bootstrap"
sys.path.insert(0, str(_BOOTSTRAP))
PERSONAS = json.loads(
    (_ROOT / "scripts" / "demo_seed" / "personas.json").read_text(encoding="utf-8")
)


def _p(msg):
    print(msg, flush=True)


async def main() -> int:
    import firebase_admin

    try:
        firebase_admin.initialize_app()
    except ValueError:
        pass
    from firebase_admin import auth as fb_auth
    from db import get_db
    import schema
    import feature_flags
    import token_ledger
    import taste_match
    import explore
    import practice_core
    from pair_key import sorted_pair_key
    from dm_schema import thread_id
    from config import CONFIG

    db = get_db()
    plist = PERSONAS["personas"]
    by_key = {p["key"]: p for p in plist}
    t1, t2, t3 = by_key["test1"]["uid"], by_key["test2"]["uid"], by_key["test3"]["uid"]

    _p("\n===== 1. ACCOUNTS + PROFILE COMPLETENESS =====")
    for p in plist:
        uid = p["uid"]
        try:
            u = fb_auth.get_user(uid)
            auth_ok = f"email={u.email} verified={u.email_verified} disabled={u.disabled}"
        except Exception as exc:  # noqa: BLE001
            auth_ok = f"AUTH MISSING: {exc}"
        root_exists = db.collection("users").document(uid).get().exists
        prof = schema.profile_doc(db, uid).get().to_dict() or {}
        comp = prof.get("completeness") or {}
        photos = prof.get("photos") or []
        wiki = list(db.collection("users").document(uid).collection("wiki_pages").stream())
        raw = list(db.collection("users").document(uid).collection("raw_turns").stream())
        chat = list(db.collection("users").document(uid).collection("chat_messages").stream())
        appe = db.collection("users").document(uid).collection("appearance_reports").document("current").get()
        avatar = db.collection("users").document(uid).collection("persona").document("avatar").get()
        _p(f"\n-- {p['key']} ({p['name']}) {uid}")
        _p(f"   auth: {auth_ok}  users-root={root_exists}")
        _p(f"   completeness score={comp.get('score')} complete={comp.get('complete')}")
        _p(f"   gender={prof.get('gender')} interested_in={prof.get('interested_in')} "
           f"age_pref=[{prof.get('qz_partner_age_min')},{prof.get('qz_partner_age_max')}] "
           f"location={prof.get('location')!r} intent={prof.get('relationship_intent')}")
        _p(f"   photos={len(photos)}  wiki_pages={len(wiki)}  raw_turns={len(raw)}  "
           f"chat_messages={len(chat)}  appearance_report={appe.exists}  avatar={avatar.exists}")
        # photo attributes
        for ph in photos:
            mid = ph.get("media_id")
            if not mid:
                continue
            md = db.collection("users").document(uid).collection("user_media").document(mid).get().to_dict() or {}
            at = md.get("attributes") or {}
            _p(f"     photo {mid}: shot={at.get('shot_type')} "
               f"usable_for_face={at.get('usable_for_face')} usable_for_body={at.get('usable_for_body')} "
               f"path={md.get('storage_path')}")

    _p("\n===== 2. TASTE MATCH (Qloo) =====")
    good = await taste_match.report_section(db, t1, t2)
    bad = await taste_match.report_section(db, t1, t3)
    _p(f"   test1 x test2 (GOOD): score={good and good.get('score')} "
       f"label={good and good.get('score_label')} shared={good and good.get('shared')}")
    _p(f"   test1 x test3 (BAD):  score={bad and bad.get('score')} "
       f"label={bad and bad.get('score_label')} shared={bad and bad.get('shared')}")

    _p("\n===== 3. MATCH SCORES (matches/{pair}) =====")
    for a, b, tag in ((t1, t2, "GOOD"), (t1, t3, "BAD")):
        m = db.collection("matches").document(sorted_pair_key(a, b)).get().to_dict() or {}
        _p(f"   {tag} {a} x {b}: score={m.get('score')} status={m.get('status')}")

    _p("\n===== 4. EXPLORE DISCOVERABILITY (founder) =====")
    founder = None
    try:
        founder = fb_auth.get_user_by_email("suhailps@gmail.com").uid
    except Exception as exc:  # noqa: BLE001
        _p(f"   founder lookup failed: {exc}")
    if founder:
        fprof = schema.profile_doc(db, founder).get().to_dict() or {}
        filters = explore.apply_saved_age_range({}, fprof)
        cards = explore.explore(db, founder, filters, limit=100)
        ids = {c["uid"] for c in cards}
        _p(f"   founder={founder} filters={filters} candidates={len(cards)}")
        for p in plist:
            card = next((c for c in cards if c["uid"] == p["uid"]), None)
            _p(f"   {p['key']} in Explore: {p['uid'] in ids}"
               + (f"  (age={card['age']} score={card['score']})" if card else ""))

    _p("\n===== 5. EMAIL-VERIFY BYPASS (scoped) =====")
    _p(f"   CONFIG.test_bypass_emails={CONFIG.test_bypass_emails}")
    for uid, label in ((t1, "test1 (allowlisted)"),):
        _p(f"   _contact_verified({label})={token_ledger._contact_verified(uid)}")
    if founder:
        _p(f"   _contact_verified(founder, not in list but verified)="
           f"{token_ledger._contact_verified(founder)}")

    _p("\n===== 6. PER-UID FLAG OVERRIDE (scoped) =====")
    _p(f"   CONFIG.all_flags_on_uids={CONFIG.all_flags_on_uids}")
    for name in ("meta_integrations", "mcp_server"):
        v_demo, src = feature_flags.resolve(name, t1)
        v_other, _ = feature_flags.resolve(name, "not-a-demo-uid")
        _p(f"   {name}: demo-uid={v_demo} (src={src})  other-uid={v_other}")

    _p("\n===== 7. DMs =====")
    for a_key, b_key, tag in (("test1", "test2", "strong"), ("test1", "test3", "mismatched")):
        a, b = by_key[a_key]["uid"], by_key[b_key]["uid"]
        tref = db.collection("dm_threads").document(thread_id(a, b))
        msgs = list(tref.collection("messages").stream())
        _p(f"   {a_key} x {b_key} ({tag}): {len(msgs)} messages")

    _p("\n===== 8. AVATAR CHAT (live) =====")
    ctx = practice_core.build_persona_context(db, t1, t2)
    if ctx is None:
        _p("   no persona context for test2 (avatar unavailable)")
    else:
        reply = await practice_core.persona_reply(
            ctx, [], "Hi! What do you like to do on weekends?",
            uid=t1, session_id="verify-probe",
        )
        _p(f"   test2 avatar reply: {reply[:200]!r}")

    _p("\n===== 9. PRACTICE-DATE READINESS (read-only) =====")
    for viewer_key, target_key in (("test1", "test2"), ("test1", "test3")):
        viewer, target = by_key[viewer_key]["uid"], by_key[target_key]["uid"]
        pctx = practice_core.build_persona_context(db, viewer, target)
        if pctx is None:
            _p(f"   {viewer_key} -> {target_key}: NO PERSONA CONTEXT")
            continue
        prompt = practice_core.compose_persona_prompt(pctx)
        _p(f"   {viewer_key} -> {target_key}: name={pctx.name!r} age={pctx.age} "
           f"gender={pctx.gender!r} location={pctx.location!r} "
           f"pages={len(pctx.pages)} photos={pctx.photo_count} "
           f"prompt_chars={len(prompt)} name_in_prompt={pctx.name in prompt}")

    _p("\n===== 10. DATE-SIM READINESS (read-only) =====")
    import persona_snapshot

    for p in plist:
        uid = p["uid"]
        snap = db.collection("users").document(uid).collection(
            "persona").document("avatar").get()
        if not snap.exists:
            _p(f"   {p['key']}: NO SNAPSHOT")
            continue
        data = snap.to_dict() or {}
        g = data.get("grounding") or {}
        _p(f"   {p['key']}: distilled={data.get('distilled')} "
           f"stale={data.get('stale')} "
           f"readiness={data.get('readiness_score')} "
           f"low_context={data.get('low_context')} "
           f"pages={len(g.get('pages') or [])} "
           f"exemplars={len(g.get('style_exemplars') or [])}")
    for viewer_key, target_key in (("test1", "test2"), ("test1", "test3")):
        pre = persona_snapshot.preflight_readiness(
            db, by_key[viewer_key]["uid"], by_key[target_key]["uid"])
        _p(f"   preflight {viewer_key} -> {target_key}: {pre}")

    _p("\n===== 11. STORY + TASTE COVERAGE =====")
    for p in plist:
        uid = p["uid"]
        pages = list(db.collection("users").document(uid).collection(
            "wiki_pages").stream())
        types = sorted(
            (d.to_dict() or {}).get("page_type", "?") for d in pages)
        _p(f"   {p['key']}: wiki page_types={types}")
        taste = next(
            ((d.to_dict() or {}) for d in pages
             if d.id == "taste"), {})
        body = str(taste.get("ai_body") or "")
        present = [ln.split(":")[0] for ln in body.splitlines() if ":" in ln]
        _p(f"   {p['key']}: taste domains={present}")

    _p("\n===== VERIFY DONE =====")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
