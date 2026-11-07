# Plan a date with PayPal — how this build works

Branch: `paypal/plan-a-date` (off staging build 2343, `f62dc49b`).
This branch is **not** merged to staging or v2 — it stays on its own
branch for the PayPal AI Hackathon (submission deadline Thu Nov 12,
2026, 12:00 PM PT; nothing is submitted without the founder reviewing
every field and giving the go).

## The flow

1. In a human-to-human DM thread, either person sends
   `@ayma plan a date`.
2. The backend (`functions/bootstrap/main.py`, the DM send endpoint)
   spots the trigger, reads the recent thread and both people taste
   notes, and Ayma posts a **date card** into the thread
   (`date_plan.py`): a place, a time, and the total cost.
3. The card has an **Approve** button for each person — each approves
   for themselves, and the card shows who has approved and who has
   not. Instead of approving, either person can tap **Suggest a
   change** and reply with a different time, a different kind of
   place, or "cheaper". Ayma posts the revised plan on the same card
   and approvals reset.
4. When both have approved, Ayma creates **two linked PayPal sandbox
   orders, one half of the total for each person** (one PayPal order
   has one payer, so a split is two orders). Each person pays their
   own half from the card; the card shows each half as pending or
   paid: proposed → one approved → both approved → paying →
   confirmed.
5. When both halves are captured, Ayma writes a booking record to the
   `date_bookings` collection and the card shows **Reservation
   confirmed** with its confirmation number.

## What is real and what is stubbed

- **Real:** the trigger, thread reading, card state machine,
  approvals, change-and-reset, the split-order maths, the booking
  record, and the PayPal Orders API client
  (`functions/bootstrap/paypal_client.py`) — create order and capture
  against `https://api-m.sandbox.paypal.com` when credentials are
  configured.
- **Stubbed when no credentials are set:** if `PAYPAL_CLIENT_ID` /
  `PAYPAL_CLIENT_SECRET` are not in the backend environment, the
  client falls back to a clearly labelled test mode: order ids start
  with `STUB-`, captures succeed locally, the card says "PayPal
  sandbox test mode — no real money moves", and the plan is marked
  `paypal_stubbed`. Nothing stubbed is ever shown as a real order.
- **Reservation provider:** there is no live restaurant-booking
  provider wired into Ayma, so the "reservation" is the booking
  record above (place, time, both people, confirmation number),
  created only after both halves are paid. Wiring a real booking
  provider is a later chunk.
- **Planning:** the place/time pick in this chunk is a deterministic
  read of the thread words and taste notes. It makes no direct
  model-provider call — Ayma inference stays on the existing
  LiveKit-routed path.

## PayPal sandbox setup (still to do — needs an account step)

No PayPal developer account exists for this project yet, and there is
no saved PayPal login. To turn on the real sandbox flow:

1. Create / sign in at developer.paypal.com (this account step needs
   the founder password route — flagged to Astro in the build thread).
2. Create a sandbox app, note its client ID and secret.
3. Create two sandbox buyer accounts (the demo pair: Daniel Reyes and
   Sofia Marino) to pay the two halves.
4. Set `PAYPAL_CLIENT_ID` and `PAYPAL_CLIENT_SECRET` in the backend
   environment (see `functions/bootstrap/paypal.env.example`). Never
   commit real secrets; sandbox credentials only, never live ones.

Until those are set, the whole flow still runs end to end in the
labelled test mode above.

## Demo personas

Daniel Reyes / Sofia Marino are the demo pair from the build brief.
They are names in the demo script only — no production user data and
no credentials are in this branch.
