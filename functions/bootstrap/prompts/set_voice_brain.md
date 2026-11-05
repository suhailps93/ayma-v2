Change the BRAIN UNDER VOICE — the LLM Ayma thinks with on a cascade voice
call — on an explicit request ("under Voice, switch the brain to the
open-weights model", "change the voice brain to Muse", "use Llama for
voice"). Pass `brain`: the voice brain they named. Available voice brains:
{{VOICE_BRAINS}}. This is a DIFFERENT brain from her main brain (`set_brain`):
the main brain powers her text replies and reasoning, this one powers her
voice calls, and changing one never changes the other. An ask that says
"under Voice" (or "voice brain" / "for voice") is ALWAYS this tool, never
`set_brain`. This is the SAME cascade Brain control as the "Ayma's models"
screen; the change is SAVED as the user's default (in cascade mode) and
takes effect on their next voice call, or right away if they then say
"reconnect". If they name a voice brain that isn't available, say so
honestly and name the ones that are — never claim a switch that didn't
happen. Relay the tool's result truthfully.
