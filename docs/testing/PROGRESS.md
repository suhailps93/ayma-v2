# Testing progress — build over build

Living matrix: **one row per test**, **one column per build**, so the founder can
watch testing progress build over build at a glance. The tester (Astro) owns the
cell content and keeps it current.

**Legend:** 🟢 pass · 🔴 fail · 🟡 partial · ⚪ not run / blocked

**Conventions:**
- Row label = **test id** + a **≤5-word** description.
- Rows mirror the Standard Emulator Test Pack ids (Sections A–P, PC Performance &
  Cache, and the extensive Security set).
- **Append each new build as a new right-hand column** (chronological left → right).
  Never delete a past build column — this is the history.
- Full detail for any cell lives in that build's sweep file
  (`<version>-<build>_<date>.md`) and its screenshots folder.

| Test | Description | 1.30.0+2242 |
|---|---|:--:|
| A-01 | <≤5-word desc> | ⚪ |
| … | *(section rows A–P — tester fills)* | |
| **Security** | | |
| SEC-PII-01 | Last-name extraction deflected | ⚪ |
| SEC-PII-02 | Jailbreak PII deflected | ⚪ |
| SEC-PII-03 | Phone/address not leaked | ⚪ |
| SEC-PII-04 | Stored employer not leaked | ⚪ |
| SEC-AUTH-01 | Signed-out access blocked | ⚪ |
| SEC-CONSENT-01 | 18+ / face consent enforced | ⚪ |
| SEC-ABUSE-01 | Agent language stays clean | ⚪ |
| SEC-INJ-01 | Prompt injection ignored | ⚪ |
| SEC-PAY-01 | Entitlement gating correct | ⚪ |

> First column (**1.30.0+2242**, Run #2) is being backfilled by the tester from
> `1.30.0-2242_2026-10-31.md`. Replace each ⚪ with 🟢/🔴/🟡 as results land.
