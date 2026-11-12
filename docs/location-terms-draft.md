# Location, routines & proactive messages — proposed Terms section (DRAFT)

> **DRAFT — founder review required before ship. NOT the active Terms.** This is
> a proposed new section for the Ayma Terms of Service covering the location-date-
> moments feature (location log, learned routines, proactive messages, background
> location). It is written to drop into `docs/TERMS.md` (the source of truth that
> `ayma_flutter/lib/legal/terms_text.dart` and `public/terms.html` are generated
> from) once approved. It is **not** wired into any live Terms file, in-app or on
> the site. The companion consent copy is `docs/legal/location-log-consent-DRAFT.md`;
> the Privacy Policy needs a matching section (sketched there).

> **Internal note (not shown in the app or on the web):** an attorney must review
> this wording before any store release, alongside the existing bold clauses. The
> priority clauses here are background collection while the app is closed, the
> retention line, and the "turning GPS off" controls. Keep this file, `docs/TERMS.md`,
> `terms_text.dart` and `public/terms.html` in step once approved.

---

## Location, routines and proactive messages (optional)

**This feature is optional and off by default.** Ayma does not use your location,
keep any record of where you go, or send you anything based on where you are,
unless you turn it on. You turn it on, and off, with the switches in **Settings ›
Privacy**, and a single **master Location switch** turns all of it off at once.

**Opting in.** When you start Ayma it may ask your device for permission to use
location, the same way it asks about notifications. **Granting that device
permission does not turn anything on by itself** — the location log and Date
moments are separate opt-ins you make in Settings, both off until you choose them,
and **nothing is collected or logged until you do.**

**What we collect.** If you turn on the location log or Date moments, Ayma
collects your device's **precise location (latitude, longitude and the time)**,
and for each place you visit resolves a **place name and place kind** (for
example "a café", "a park") using **Google Places**. Ayma collects this while the
app is open and, **only if you also turn on Background location, while the app is
closed or in the background.**

**The location log.** With the log on, Ayma keeps a **private record of the
places you have visited** — the coordinates, time, resolved place name and place
kind for each visit — in your own account data. It is private to you and is not
shown on your profile or to other users.

**Routines Ayma learns about you.** From **your own log only**, Ayma works out
your **recurring routines** — for example "morning walks", "Sunday hikes" or
"days at work". This is done **by a plain, deterministic calculation, not by an
AI model**, and the routines Ayma has found are shown to you under **"What Ayma
has learned"** in Settings › Privacy. Ayma does not build routines from anyone
else's location, and does not use another person's location to learn about you.

**Proactive messages, including while the app is closed.** When you arrive
somewhere that fits a routine you've built — or at a date you and a match both
approved — **Ayma may reach out to you first**, with a **push notification and an
in-app message** in her own voice. **If you have turned on Background location,
these can arrive even when the app is closed.** They are **frequency-capped** (at
most a few a day, and at most once per routine per day) so they do not spam you.

**Turning it off, and what each switch stops.**

- **Location (the master switch) — turns GPS off entirely.** With it off, **Ayma
  uses no location at all**: nothing is logged, no routines are learned, no
  date-arrival checks run, and **no proactive messages are sent from your
  location.** This switch overrides every other location setting.
- **Background location — turns off location while the app is closed.** With it
  off (but the master switch on), Ayma only checks your location **while the app
  is open in front of you**, never in the background.
- **The per-feature switches (Location log, Date moments)** turn each use on or
  off on its own.
- **"Wipe what Ayma has learned"** (Settings › Privacy) **deletes your location
  log and the routines learned from it.**
- Turning any switch off takes effect immediately. Turning off the device's
  location permission in your phone's own settings also stops all collection.

**How long we keep it.** Your **location log entries stay until you clear them**
(with "Wipe what Ayma has learned") **or delete your account**, after which they
are removed on the same schedule as the rest of your data in "How long we keep
your data" in the Privacy Policy. The **routines are worked out from the log when
needed and are not stored separately**, so clearing the log clears them.

**We do not sell your location data, and we do not use it for advertising.**

---

## Drafting notes — choices made where the existing Terms were silent

The current Terms mention location only twice, both in passing: "**Approximate
location, only if you choose to provide it**" (under *Your data › What we collect
and store*) and "**general location if you provided it**" (under *Advertising*).
They say nothing about precise location, a stored history of places, background
collection, learned routines, or proactive outreach. Choices I made to fill
those gaps, for the founder to confirm:

1. **"Precise" location, not "approximate."** The feature logs exact
   coordinates and resolves specific places, so I used **precise location**
   rather than the existing Terms' "approximate location" (which describes the
   optional coarse-location-for-ads use and is left as-is). These are two
   different uses and the draft keeps them separate; the founder may want the
   *Your data* list updated to add precise location as a distinct entry.

2. **"Asked at app start" reconciled with the default-off opt-in.** The brief
   said the log is "opt-in and asked at app start." In the build, what happens at
   start is the **OS location-permission prompt** (`main.dart`); the log itself
   is a **default-off Settings toggle**, and granting the OS permission turns
   nothing on. I wrote it that way — permission may be asked at start, the log is
   a separate opt-in, nothing is collected until you turn it on — so the Terms
   match the actual behaviour. If the founder intends a distinct **in-app log
   opt-in prompt shown at first launch** (beyond the OS permission), the wording
   should name that prompt instead.

3. **Retention stated explicitly.** The existing Terms have no location-specific
   retention line. I took the retention from the consent draft — **log persists
   until you clear it or delete your account; routines computed on demand, not
   stored separately** — and tied account-deletion to the existing "How long we
   keep your data" schedule so there's one deletion story.

4. **"GPS off" mapped to the master Location switch.** The brief asked what
   "turning GPS off" stops. The build's **master Location switch** is the GPS
   kill switch, so I described turning it off as "Ayma uses no location at all"
   and listed exactly what stops (log, routines, arrival checks, proactive
   messages). I also noted that turning the **OS** location permission off stops
   collection too, since users may reach for that first.

5. **"Not sold / not for advertising" stated for location.** The existing Terms
   say location *may* feed advertising ("general location if you provided it").
   To avoid contradicting that, this draft's no-sale/no-ads line is scoped to the
   **log and routines** (the precise-location feature), leaving the separate
   coarse-location-for-ads disclosure untouched. **The founder should confirm**
   whether precise log location must be fully walled off from advertising (the
   draft assumes yes); if so the Advertising section should say precise log
   location is never used for ads, the way it already does for face data and
   Google-account data.

6. **Voice and scope.** Kept to the existing Terms' plain-language, second-person
   voice with bold on the load-bearing clauses; no new defined terms. Date
   moments are mentioned only briefly since this section's focus (per the brief)
   is the log, the learned patterns, and proactive messages; the consent draft
   has the fuller Date moments description.
