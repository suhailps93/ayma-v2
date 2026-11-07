package com.ayma.ayma_flutter

import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/**
 * Factory for [AymaAssistantSession], named from
 * `res/xml/ayma_voice_interaction_service.xml` (the `sessionService`
 * attribute). One new session per summon.
 */
class AymaAssistantSessionService : VoiceInteractionSessionService() {

    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return AymaAssistantSession(this)
    }
}
