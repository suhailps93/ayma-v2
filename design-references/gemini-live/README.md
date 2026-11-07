# Gemini Live — design references for Ayma video / screen share (feedback item 13)

Reference screenshots of Google Gemini Live's user-to-AI video and screen
sharing, gathered from the web on 2026-11-06. They are the UX reference the
founder named for Ayma's in-call Video / Screen share controls
(branch `fleet/ayma-video-screenshare`). Third-party editorial images,
kept for design reference only — not app assets.

| File | Source | What it shows |
| --- | --- | --- |
| `01-live-voice-call-9to5google.webp` | 9to5Google, Gemini Live guide (9to5google.com/guides/gemini-live) | Voice-only Live call: dark stage, glowing orb low-center, call controls in a single bottom row (camera, gallery, mic, red end-call). |
| `02-screen-share-consent-androidpolice.webp` | Android Police (anpoimages CDN) | The Live bottom bar — camera toggle, screen-share toggle (rectangle with up-arrow), orb, mic, end call — plus the per-session system consent dialog ("Share your screen…", Cancel / Share screen). |
| `03-live-camera-view-todaytech.jpg` | todaytech.eu, Gemini Live camera coverage | Camera ON: the camera feed becomes the main stage (large rounded-corner video area over the orb glow); bottom controls reduce to pause + end call. |
| `04-screen-share-and-camera-states-focus.jpg` | Focus.pl, Gemini Live new-features coverage | Triptych: "Share screen with Live" entry chip; the red Android system notification while sharing ("Sharing your screen with Gemini Live — Stop sharing") beside the Live call notification; camera ON with the bottom bar showing the camera toggle in its filled/active state, screen-share toggle, pause, end call, and a camera-flip button at the video's corner. |

## Behaviours mirrored in Ayma's implementation

1. **One bottom control bar in the call surface.** Camera and screen-share
   toggles sit beside the mic control in a single bottom row of circular
   buttons (`VoiceCallScreen` controls row) — not in a menu or a second
   screen.
2. **Active toggle = filled button.** A live camera/share shows the button
   filled in the accent colour; off shows the plain outline state.
3. **Camera feed becomes the stage.** With video on, the user's camera
   preview takes the main stage of the call screen (rounded-corner video
   area, mirrored for the front camera); the orb recedes behind it.
4. **Per-session system consent before any screen pixels flow.** Screen
   share always goes through the Android MediaProjection consent dialog
   (the "Share your screen…" system prompt) — once per session, never
   remembered silently.
5. **A persistent sharing indicator with a stop affordance.** While the
   screen is shared, Ayma shows an in-app "Sharing your screen" pill that
   stops the share when tapped, on top of the call foreground-service
   notification Android requires anyway.
6. **Unavailable capability is shown, not hidden.** Where Gemini greys a
   control it cannot use, Ayma shows the Video / Screen share toggles
   visibly disabled with a plain explanation when the selected model
   cannot perceive video (see the model-support matrix in the item-13
   DONE report; gating is driven by the voice catalog capability flags).

Not mirrored: the camera-flip button (04, video corner) — Ayma publishes
the front camera only in this build; and Gemini's gallery/image button
(01) — out of scope for item 13.
