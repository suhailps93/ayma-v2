# Location log & routines — consent copy (DRAFT)

> **DRAFT — founder review required before ship. NOT the active Terms or Privacy
> Policy.** This file is a drafting surface for the location-date-moments
> feature (PIECE 2). Nothing here is wired as live/accepted terms or as a
> shipping consent gate. The live Terms and Privacy Policy are the hosted
> documents linked from Settings › Privacy; update those (and the store
> declarations below) only after the founder reviews and approves this wording.

## What this feature collects and does

The feature is **off by default** and governed by three switches in
Settings › Privacy (precedence documented in `docs/ARCHITECTURE.md` §4.3a):

1. **Location (master switch).** Off means Ayma uses no GPS at all — no log,
   no routines, no date arrival checks, no proactive messages. The top-level
   kill switch.
2. **Background location.** Off means no checks while the app is closed
   (foreground only), master permitting.
3. **Date moments** and **Location log** — the per-feature opt-ins (both
   default off) that decide what your location is used for.

When you opt in:

- **Location log.** Ayma stores a log of places you visit —
  `{coordinates, time, resolved place name, place kind}` per visit — in your
  private account data. Place names/kinds are resolved via Google Places.
- **Learned routines.** Ayma derives recurring routines from that log
  **deterministically** (no AI/model involved) — e.g. "morning walks",
  "Sunday hikes", "late-night drinks", "days at work" — and shows them to you
  under "What Ayma has learned" in Settings › Privacy.
- **Date moments.** When you arrive at a date you and a match both approved,
  Ayma recaps the plan privately to you.
- **Proactive messages.** When you arrive at a place that matches a learned
  routine, Ayma may reach out — **both a push notification and an in-app chat
  message**, in her own voice, referencing the moment. These are
  **frequency-capped** (at most a few a day, once per routine per day) so they
  never spam you.

## Your controls

- Turn any switch off at any time. **Master off halts all collection
  immediately** — nothing is logged, no routines are derived, no arrival checks
  run, no proactive messages are sent.
- **"Wipe what Ayma has learned?"** (Settings › Privacy) clears the location
  log and, with it, the derived routines.
- Granting the OS location permission does **not** by itself turn anything on —
  the in-app switches are the opt-in.

---

## Draft Terms & Conditions clause (for review)

> **Location, routines and proactive messages (optional).** If you turn on the
> location log or Date moments in Settings › Privacy, you agree that Ayma may
> collect your device location — including in the background while the app is
> closed, if you enable Background location — to maintain a log of places you
> visit, to learn recurring routines from that log, to recap approved dates when
> you arrive, and to send you proactive push notifications and in-app messages
> related to those routines and dates. These features are off by default, are
> governed by the switches in Settings › Privacy (including a master switch that
> turns all location use off), and can be turned off at any time. Clearing "what
> Ayma has learned" deletes your location log and derived routines.

## Draft Privacy Policy section (for review)

> **Precise & background location (optional, off by default).**
> *What we collect:* when you enable the location log or Date moments, your
> device's precise location (latitude/longitude and time), collected in the
> foreground and — if you enable Background location — in the background while
> the app is closed.
> *Why:* to store a private log of places you visit; to resolve each place's
> name and kind via Google Places; to derive recurring routines from the log
> **deterministically (no automated profiling by AI models)**; to recap an
> approved date when you arrive; and to send you proactive notifications and
> in-app messages about your routines and dates.
> *Your choices:* all of this is off by default and controlled by the switches
> in Settings › Privacy. A master switch turns off all location use. You can
> clear your location log and derived routines at any time via "Wipe what Ayma
> has learned". We do not sell your location data.
> *Retention:* location log entries persist until you clear them or delete your
> account; derived routines are computed on demand and are not stored
> separately.

---

## Store declarations — ship-time note (founder reviews before submission)

Before shipping, update the app-store privacy declarations to reflect this
feature (and have the founder review them):

- **Google Play Data safety:** declare **Location → Precise location** as
  collected; disclose **background location access** (ACCESS_BACKGROUND_LOCATION
  + a location foreground service) with the prominent-disclosure + runtime
  consent flow Play requires; declare that location is collected and stored,
  used for app functionality and (optionally) personalization, not sold, and
  user-deletable.
- **Apple App Store privacy labels:** declare **Precise Location** under Data
  Used/Collected, linked to the user, for App Functionality (and
  Personalization for routines/proactive messages); note background use via the
  `location` UIBackgroundMode and "Always" authorization.
- **Store listing / review notes:** explain that location, background location,
  the log and proactive messages are all opt-in and default-off, with a master
  off switch, to pass review for background-location use.
