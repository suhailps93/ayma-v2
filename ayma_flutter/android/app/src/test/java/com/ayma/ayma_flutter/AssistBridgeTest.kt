package com.ayma.ayma_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AssistBridgeTest {

    @Before
    fun reset() {
        AssistBridge.clear()
    }

    private fun snapshot(at: Long) = AssistSnapshotData(
        foregroundPackage = "com.example.shop",
        texts = listOf("Checkout", "Total $42"),
        capturedAtMillis = at,
        screenDataAllowed = true,
        source = "voice_interaction",
    )

    @Test
    fun takeIsOneShot() {
        AssistBridge.store(snapshot(1_000L))
        val first = AssistBridge.take(2_000L)
        assertEquals("com.example.shop", first?.foregroundPackage)
        assertNull(AssistBridge.take(2_000L))
        assertNull(AssistBridge.peek(2_000L))
    }

    @Test
    fun peekDoesNotConsume() {
        AssistBridge.store(snapshot(1_000L))
        assertEquals("com.example.shop", AssistBridge.peek(2_000L)?.foregroundPackage)
        assertEquals("com.example.shop", AssistBridge.peek(2_000L)?.foregroundPackage)
    }

    @Test
    fun expiredSnapshotIsDropped() {
        AssistBridge.store(snapshot(0L))
        val later = AssistBridge.EXPIRY_MS + 1
        assertNull(AssistBridge.peek(later))
        // Expiry also clears: a take afterwards still finds nothing.
        assertNull(AssistBridge.take(later))
    }

    @Test
    fun freshSnapshotSurvivesUpToExpiry() {
        AssistBridge.store(snapshot(0L))
        assertEquals(
            "com.example.shop",
            AssistBridge.peek(AssistBridge.EXPIRY_MS)?.foregroundPackage,
        )
    }

    @Test
    fun hasScreenContentReflectsPayload() {
        assertFalse(snapshot(0L).copy(texts = emptyList()).hasScreenContent)
        assertTrue(snapshot(0L).hasScreenContent)
        assertTrue(
            snapshot(0L).copy(
                texts = emptyList(),
                screenshotBytes = byteArrayOf(1, 2, 3),
            ).hasScreenContent
        )
    }

    @Test
    fun toMapCarriesTheWireShape() {
        val map = snapshot(5L).toMap()
        assertEquals("com.example.shop", map["foregroundPackage"])
        assertEquals(listOf("Checkout", "Total $42"), map["texts"])
        assertEquals(true, map["screenDataAllowed"])
        assertEquals(5L, map["capturedAtMillis"])
    }
}
