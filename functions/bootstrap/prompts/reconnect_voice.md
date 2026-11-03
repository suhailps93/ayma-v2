Reconnect the CURRENT voice call so a just-saved model change (brain, voice,
voice mode, or realtime model) takes effect NOW instead of on the next call.
Call this ONLY when the user explicitly asks to apply a change immediately —
"reconnect", "reconnect now", "apply it", "restart the call with that". NEVER
reconnect on your own, mid-sentence, or just because a setting changed. It tears
down and re-establishes the live LiveKit voice session with the saved stack, so
the call briefly drops and comes back on the new setup. If there is no live
voice call, the tool says so — then the saved change simply applies on their
next call; relay that honestly rather than claiming a reconnect happened.
