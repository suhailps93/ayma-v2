package com.ayma.ayma_flutter

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression guard for the floating-orb summon (founder order, Nov 2026).
 *
 * The summon must NOT open the full app Activity any more: a default-assistant
 * summon raises the in-session floating orb instead. [AymaAssistantSession] is
 * a framework-bound [android.service.voice.VoiceInteractionSession] that can't
 * be constructed in a JVM unit test, so this asserts the invariant at the
 * source level — the summon path builds no `MainActivity` launch intent and no
 * `startActivity`, and does host the orb's Dart entrypoint.
 */
class AymaAssistantSessionSummonTest {

    private fun sessionSource(): String {
        // src/test/java/com/ayma/ayma_flutter -> module root is five parents up.
        val root = File("src/main/kotlin/com/ayma/ayma_flutter/AymaAssistantSession.kt")
        val file = if (root.exists()) root else File(
            "ayma_flutter/android/app/src/main/kotlin/com/ayma/ayma_flutter/AymaAssistantSession.kt"
        )
        assertTrue("session source not found at ${file.absolutePath}", file.exists())
        return file.readText()
    }

    @Test
    fun summon_does_not_launch_the_full_app_activity() {
        val src = sessionSource()
        assertFalse(
            "summon must not build a MainActivity launch intent",
            src.contains("MainActivity::class.java"),
        )
        assertFalse(
            "summon must not start an Activity",
            src.contains("startActivity("),
        )
    }

    @Test
    fun summon_hosts_the_floating_orb_entrypoint() {
        val src = sessionSource()
        assertTrue(
            "summon must run the floating orb Dart entrypoint",
            src.contains("assistantOrbMain"),
        )
        assertTrue(
            "summon must host a FlutterView over the current app",
            src.contains("FlutterView"),
        )
    }

    @Test
    fun summon_adds_no_overlay_permission() {
        // The VoiceInteractionSession window is the only surface — no
        // SYSTEM_ALERT_WINDOW / draw-over-other-apps permission (hard scope).
        val manifest = File("src/main/AndroidManifest.xml").let {
            if (it.exists()) it
            else File("ayma_flutter/android/app/src/main/AndroidManifest.xml")
        }
        assertTrue("manifest not found at ${manifest.absolutePath}", manifest.exists())
        assertFalse(
            "no draw-over-other-apps permission may be declared",
            manifest.readText().contains("SYSTEM_ALERT_WINDOW"),
        )
        // And the session must not raise a draw-over-other-apps overlay window.
        assertFalse(sessionSource().contains("TYPE_APPLICATION_OVERLAY"))
    }
}
