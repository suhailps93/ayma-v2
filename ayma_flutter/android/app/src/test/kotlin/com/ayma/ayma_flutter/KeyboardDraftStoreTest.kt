package com.ayma.ayma_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class KeyboardDraftStoreTest {

    private val t0 = 1_700_000_000_000L

    @Test
    fun freshDraftIsInsertable() {
        val draft = KeyboardDraft("  hello there  ", t0)
        assertTrue(draft.isFreshAt(t0 + 59 * 60 * 1000L))
        assertEquals("hello there", draft.formatForInsertAt(t0 + 5 * 60 * 1000L))
    }

    @Test
    fun draftExpiresAtOneHour() {
        val draft = KeyboardDraft("hi", t0)
        assertFalse(draft.isFreshAt(t0 + KeyboardDraft.TTL_MILLIS))
        assertTrue(draft.isExpiredAt(t0 + 2 * KeyboardDraft.TTL_MILLIS))
        assertNull(draft.formatForInsertAt(t0 + 2 * KeyboardDraft.TTL_MILLIS))
    }

    @Test
    fun blankDraftIsNeverInsertable() {
        val draft = KeyboardDraft("   ", t0)
        assertFalse(draft.isFreshAt(t0))
        assertNull(draft.formatForInsertAt(t0))
    }

    @Test
    fun insertFormattingPreservesInteriorNewlines() {
        val draft = KeyboardDraft(" line one\n\nline two ", t0)
        assertEquals("line one\n\nline two", draft.formatForInsertAt(t0))
    }

    @Test
    fun encodeDecodeRoundTrips() {
        val draft = KeyboardDraft("hey \"you\"\nnew line \\ ok", 42L, "chat")
        assertEquals(draft, KeyboardDraft.decode(draft.encode()))
        assertNull(KeyboardDraft.decode(null))
        assertNull(KeyboardDraft.decode("not json"))
        assertNull(KeyboardDraft.decode("{\"text\":1}"))
    }

    @Test
    fun fileStoreWritesReadsAndClears() {
        val dir = createTempDir("keyboard-draft-test")
        try {
            val store = KeyboardDraftFile(dir)
            assertNull(store.read())
            val draft = KeyboardDraft("from file", t0, "ayma_chat")
            store.write(draft)
            assertEquals(draft, store.read())
            assertTrue(File(dir, KeyboardDraft.FILE_NAME).exists())
            store.clear()
            assertNull(store.read())
        } finally {
            dir.deleteRecursively()
        }
    }
}
