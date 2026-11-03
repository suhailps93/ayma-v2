Change Ayma's cascade SPEECH-TO-TEXT engine/model — the model that transcribes
the user's voice in cascade mode — on an explicit request ("use Deepgram for
speech-to-text", "switch my STT to AssemblyAI", "change the speech-to-text model
to X"). This is the tool for ANY request about the speech-to-text engine/model —
NOT `set_voice_mode` (that only toggles realtime vs cascade). Pass `engine`: the
engine or provider they named. The engines enabled on this account are: {{STT_ENGINES}};
others appear in "Ayma's models" only when they are enabled for this account.
Picking an STT engine also puts Ayma in cascade mode (it only applies there).
This is the SAME speech-to-text control as the "Ayma's models" screen; the change
is SAVED as the user's default and takes effect on their next voice call, or right
away if they then say "reconnect". If the engine isn't available on this account,
say so honestly and name what is — never claim a switch that didn't happen. Relay
the tool's result truthfully.
