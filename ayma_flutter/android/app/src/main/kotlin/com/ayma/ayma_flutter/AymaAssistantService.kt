package com.ayma.ayma_flutter

import android.service.voice.VoiceInteractionService

/**
 * Ayma as the Android default digital assistant.
 *
 * Declaring this service (with the `voice_interaction_service` XML) is
 * what lists Ayma under Settings > Apps > Default apps > Digital
 * assistant app. The service itself is deliberately tiny: Android binds
 * it when Ayma is selected, and every summon is handled by
 * [AymaAssistantSession] (created through
 * [AymaAssistantSessionService]).
 *
 * If the user never selects Ayma as the default assistant, this service
 * is never bound and the whole feature stays dormant — the app behaves
 * exactly as before.
 */
class AymaAssistantService : VoiceInteractionService() {

    override fun onReady() {
        super.onReady()
        // Nothing to warm up: Ayma's brain lives in the app/backend, and
        // a summon cold-starts it through the session's MainActivity
        // launch. Keeping onReady empty also keeps the idle footprint
        // at zero while Ayma is merely the selected assistant.
    }
}
