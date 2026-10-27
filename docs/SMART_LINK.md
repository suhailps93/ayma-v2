# The Ayma smart link (`justabot.info/get`)

A single, free, public link that sends whoever taps it to the right place for
their device: open the Ayma app if installed, else the correct app store, else
a web page with both store buttons. It is a **static Firebase Hosting page**
(`public/get.html`) — not the Cloud Run `/s/` or `/r/` routes, so it costs
nothing to serve.

## Where it is used

Every shared Appearance report card carries it in the share caption:

> Get your report on Ayma 💘 https://justabot.info/get

built by `ReportCardShare.captionFor(refCode)`
(`ayma_flutter/lib/services/report_card_share.dart`). The caption rides with the
1080x1920 PNG to **WhatsApp** and the **system share sheet ("More…")**.
**Instagram** strips shared text from an image share, so there the caption can't
ride along — the image is the content. Instead the app copies the caption (link
included) to the clipboard and toasts *"Link copied — paste it in your story or
caption."*, so a user who wants the link can paste it into their Instagram
story or caption.

## Referral passthrough

When the sharer has a referral code (`GET /referral`), the app appends it:
`https://justabot.info/get?r=<CODE>`. The static page forwards it to Google Play
as the `ayma_ref` install referrer (`&referrer=ayma_ref%3D<CODE>`) — the **same
key** the backend referral page uses (`referral_page.REFERRER_KEY`), so the app
reads it after install and attributes the referral. No code → the plain
`/get` link.

## How the redirect works (`public/get.html`)

Pure client-side JS, exposed as `window.aymaSmartLink` for testing:

- `detectOS(ua)` → `'android' | 'ios' | 'other'` (iPadOS 13+ reports as
  "Macintosh"; disambiguated by `navigator.maxTouchPoints`).
- **Android** → first tries an `intent://` deep link targeting the app package
  (`com.ayma.ayma_flutter`) with `S.browser_fallback_url` set to the Play
  listing; a 1.5 s timer also falls back to Play in case the intent resolves to
  nothing. Play URL carries the `ayma_ref` referrer.
- **iOS** → redirects to the App Store URL.
- **other** (desktop/unknown) → stays on the page and shows both store buttons.

Open Graph / Twitter Card tags give WhatsApp/Instagram/iMessage a rich preview
(title, description, and the Ayma orb at `https://justabot.info/ayma-orb.png`,
copied from `assets/icon/ayma_orb_ios.png`).

### Unit-testing the OS detection

`detectOS` is a pure function on `window.aymaSmartLink`. In a Node/jsdom test,
load the `<script>` body and assert, e.g.
`aymaSmartLink.detectOS('... Android ...') === 'android'`,
`aymaSmartLink.detectOS('... iPhone ...') === 'ios'`,
`aymaSmartLink.playUrl('AB12') === '...&referrer=ayma_ref%3DAB12'`.
The script guards `typeof document === 'undefined'` so it does no DOM work when
imported for testing. The Dart side is covered by
`test/appearance_report_card_test.dart` ("smart-link caption").

## TODO the founder must provide

- **The real numeric App Store ID.** `public/get.html` uses a placeholder
  `APP_STORE_ID = '0000000000'` (clearly `TODO`d in the file); until the iOS app
  is live in App Store Connect, the iOS redirect 404s. Replace the constant with
  the real id once known (also wire `SHARE_IOS_STORE_URL` on `ayma-api` so the
  `/r/` and `/s/` pages match).
- **(Optional) deep-link into a screen.** Today the Android `intent://` attempt
  opens the app (or falls back to Play); it does not route to a specific
  in-app screen for `/get`. To open the app to a chosen screen, add `/get` to
  the app's App Links `<intent-filter>` and `/.well-known/assetlinks.json`, and
  a go_router handler — a future enhancement.

## Serving

`firebase.json` rewrites `/get` → `/get.html`. Deployed by
`firebase deploy --only hosting` (part of `deploy-all.sh`). Hosting is free.
