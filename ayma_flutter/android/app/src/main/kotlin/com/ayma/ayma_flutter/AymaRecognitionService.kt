package com.ayma.ayma_flutter

import android.content.Intent
import android.speech.RecognitionService

/**
 * Recognition-service stub named by the voice-interaction XML (the
 * `recognitionService` attribute is required for the assistant listing).
 *
 * Ayma does her real listening inside the app (LiveKit voice sessions);
 * this stub exists only so the [AymaAssistantService] declaration is
 * complete. It performs no recording, no network access and no
 * recognition — a caller routed here simply gets no results.
 */
class AymaRecognitionService : RecognitionService() {

    override fun onStartListening(
        recognizerIntent: Intent?,
        listener: Callback?,
    ) {
        // Intentionally empty — see the class doc.
    }

    override fun onCancel(listener: Callback?) {
        // Intentionally empty — see the class doc.
    }

    override fun onStopListening(listener: Callback?) {
        // Intentionally empty — see the class doc.
    }
}
