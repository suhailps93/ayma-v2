package com.ayma.ayma_flutter

import java.io.File

/**
 * Ayma Keyboard V1 — the draft store shared by the Ayma app and the Ayma
 * Keyboard IME.
 *
 * Storage: one JSON file, `ayma_keyboard_draft.json`, in the app-internal
 * files directory. Both writers/readers (MainActivity for the Flutter
 * side, [AymaKeyboardService] for the IME) are the same application and
 * run under the same UID/sandbox, so the file is private to Ayma and no
 * IPC is needed. A ContentProvider was rejected for V1: it would need to
 * be exported (or use per-URI grants) to serve anything, and inside one
 * app it adds a queryable surface for zero benefit.
 *
 * Privacy: this file only ever contains text the user explicitly sent
 * to the keyboard from inside Ayma. It never contains keystrokes — the
 * IME writes nothing here except clearing a consumed/dismissed draft.
 *
 * The encode/decode and freshness logic in this file is deliberately
 * free of Android APIs so it can be covered by plain JVM unit tests.
 */
data class KeyboardDraft(
    val text: String,
    val createdAtMillis: Long,
    val source: String? = null,
) {
    fun isFreshAt(nowMillis: Long): Boolean {
        if (text.isBlank()) return false
        return nowMillis - createdAtMillis < TTL_MILLIS
    }

    fun isExpiredAt(nowMillis: Long): Boolean = !isFreshAt(nowMillis)

    /** Text for `InputConnection.commitText`, or null if not insertable. */
    fun formatForInsertAt(nowMillis: Long): String? {
        if (isExpiredAt(nowMillis)) return null
        return text.trim().ifEmpty { null }
    }

    fun encode(): String {
        val sb = StringBuilder()
        sb.append("{\"text\":")
        appendJsonString(sb, text)
        sb.append(",\"createdAtMillis\":").append(createdAtMillis)
        if (source != null) {
            sb.append(",\"source\":")
            appendJsonString(sb, source)
        }
        sb.append("}")
        return sb.toString()
    }

    companion object {
        const val TTL_MILLIS: Long = 60L * 60L * 1000L // 1 hour
        const val FILE_NAME = "ayma_keyboard_draft.json"

        fun decode(raw: String?): KeyboardDraft? {
            if (raw.isNullOrBlank()) return null
            val text = extractJsonString(raw, "text") ?: return null
            val created = extractJsonLong(raw, "createdAtMillis") ?: return null
            val source = extractJsonString(raw, "source")
            return KeyboardDraft(text, created, source)
        }

        private fun appendJsonString(sb: StringBuilder, value: String) {
            sb.append('"')
            for (c in value) {
                when (c) {
                    '"' -> sb.append("\\\"")
                    '\\' -> sb.append("\\\\")
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    '\t' -> sb.append("\\t")
                    else -> {
                        if (c < ' ') sb.append(String.format("\\u%04x", c.code))
                        else sb.append(c)
                    }
                }
            }
            sb.append('"')
        }

        /** Finds `"key"` and parses the JSON string value after its colon. */
        private fun extractJsonString(json: String, key: String): String? {
            val idx = json.indexOf("\"$key\"")
            if (idx < 0) return null
            var i = json.indexOf(':', idx + key.length + 2)
            if (i < 0) return null
            i++
            while (i < json.length && json[i].isWhitespace()) i++
            if (i >= json.length || json[i] != '"') return null
            i++
            val out = StringBuilder()
            while (i < json.length) {
                val c = json[i]
                when {
                    c == '\\' && i + 1 < json.length -> {
                        when (val e = json[i + 1]) {
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (i + 5 < json.length) {
                                    val hex = json.substring(i + 2, i + 6)
                                    hex.toIntOrNull(16)?.let { out.append(it.toChar()) }
                                    i += 4
                                }
                            }
                            else -> out.append(e)
                        }
                        i += 2
                    }
                    c == '"' -> return out.toString()
                    else -> {
                        out.append(c)
                        i++
                    }
                }
            }
            return null
        }

        private fun extractJsonLong(json: String, key: String): Long? {
            val idx = json.indexOf("\"$key\"")
            if (idx < 0) return null
            var i = json.indexOf(':', idx + key.length + 2)
            if (i < 0) return null
            i++
            while (i < json.length && json[i].isWhitespace()) i++
            val start = i
            if (i < json.length && json[i] == '-') i++
            while (i < json.length && json[i].isDigit()) i++
            if (i == start) return null
            return json.substring(start, i).toLongOrNull()
        }
    }
}

/** File-backed access to the single current draft. */
class KeyboardDraftFile(private val dir: File) {
    private val file: File get() = File(dir, KeyboardDraft.FILE_NAME)

    fun write(draft: KeyboardDraft) {
        // Write-then-rename so the IME never reads a half-written file.
        val tmp = File(dir, KeyboardDraft.FILE_NAME + ".tmp")
        tmp.writeText(draft.encode())
        if (!tmp.renameTo(file)) {
            file.writeText(draft.encode())
            tmp.delete()
        }
    }

    fun read(): KeyboardDraft? = try {
        if (file.exists()) KeyboardDraft.decode(file.readText()) else null
    } catch (_: Exception) {
        null
    }

    fun clear() {
        try {
            file.delete()
        } catch (_: Exception) {
            // Best-effort; an unreadable leftover is treated as no draft.
        }
    }
}
