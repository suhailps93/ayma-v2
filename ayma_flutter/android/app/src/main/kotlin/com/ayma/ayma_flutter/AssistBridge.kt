package com.ayma.ayma_flutter

/**
 * In-memory hand-off for ONE assistant summon, plus the pure text logic
 * around it. This file is the privacy core of the default-assistant
 * feature, so its rules are hard requirements (docs/AYMA_DEFAULT_ASSISTANT.md):
 *
 *  - Screen content arrives ONLY from a user-initiated summon through the
 *    Assist API ([AymaAssistantSession]). Nothing here polls, scrapes in
 *    the background, or uses an Accessibility service.
 *  - A snapshot lives ONLY in process memory ([AssistBridge]). It is
 *    never written to disk, never logged, and never sent anywhere by the
 *    native side. The screenshot travels as in-memory bytes.
 *  - A snapshot is consumed once ([AssistBridge.take] clears it) and
 *    expires after [AssistBridge.EXPIRY_MS] even if never consumed.
 */

// One node of the foreground app's view hierarchy as the Assist API
// reported it — a plain value tree so the flattening logic below is
// JVM-unit-testable without the Android framework.
data class AssistNodeData(
    val text: String? = null,
    val contentDescription: String? = null,
    val className: String? = null,
    val children: List<AssistNodeData> = emptyList(),
)

// Turns a view-hierarchy tree into the ordered, de-duplicated list of
// visible text strings Ayma may reason about.
object AssistTextFlattener {
    /// Hard cap on strings kept from one hierarchy — a pathological app
    /// cannot flood the session context.
    const val MAX_TEXTS = 120

    /// Hard cap on characters per string (long web views report whole
    /// paragraphs as one node).
    const val MAX_TEXT_CHARS = 300

    fun flatten(root: AssistNodeData?): List<String> {
        if (root == null) return emptyList()
        val out = mutableListOf<String>()
        val seen = mutableSetOf<String>()
        fun walk(node: AssistNodeData) {
            if (out.size >= MAX_TEXTS) return
            val raw = node.text?.takeIf { it.isNotBlank() }
                ?: node.contentDescription?.takeIf { it.isNotBlank() }
            if (raw != null) {
                val cleaned = raw.trim().replace(Regex("\\s+"), " ")
                    .take(MAX_TEXT_CHARS)
                if (cleaned.isNotEmpty() && seen.add(cleaned.lowercase())) {
                    out.add(cleaned)
                }
            }
            for (child in node.children) {
                if (out.size >= MAX_TEXTS) return
                walk(child)
            }
        }
        walk(root)
        return out
    }

    /// Joins [texts] with newlines, capped at [maxChars] characters.
    fun joinCapped(texts: List<String>, maxChars: Int): String {
        if (maxChars <= 0) return ""
        val sb = StringBuilder()
        for (t in texts) {
            if (sb.isNotEmpty()) {
                if (sb.length + 1 >= maxChars) break
                sb.append('\n')
            }
            if (sb.length + t.length > maxChars) {
                sb.append(t, 0, maxChars - sb.length)
                break
            }
            sb.append(t)
        }
        return sb.toString()
    }
}

// Everything one summon captured. [screenshotBytes] is a JPEG held in
// memory only; [screenDataAllowed] is false when Android delivered no
// structure/content/screenshot (the user's "Use screen and app data"
// toggle is off) — the summon still opens Ayma, she just cannot see.
data class AssistSnapshotData(
    val foregroundPackage: String = "",
    val webUri: String = "",
    val structuredData: String = "",
    val texts: List<String> = emptyList(),
    val screenshotBytes: ByteArray? = null,
    val screenshotWidth: Int = 0,
    val screenshotHeight: Int = 0,
    val capturedAtMillis: Long = 0L,
    val screenDataAllowed: Boolean = false,
    val source: String = "",
) {
    val hasScreenContent: Boolean
        get() = texts.isNotEmpty() || screenshotBytes != null ||
            webUri.isNotEmpty() || structuredData.isNotEmpty()

    /// The map handed to Dart over the `ayma/assistant` channel.
    fun toMap(): Map<String, Any?> = mapOf(
        "foregroundPackage" to foregroundPackage,
        "webUri" to webUri,
        "structuredData" to structuredData,
        "texts" to texts,
        "screenshotBytes" to screenshotBytes,
        "screenshotWidth" to screenshotWidth,
        "screenshotHeight" to screenshotHeight,
        "capturedAtMillis" to capturedAtMillis,
        "screenDataAllowed" to screenDataAllowed,
        "source" to source,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AssistSnapshotData) return false
        return foregroundPackage == other.foregroundPackage &&
            webUri == other.webUri &&
            structuredData == other.structuredData &&
            texts == other.texts &&
            screenshotBytes.contentEquals(other.screenshotBytes) &&
            screenshotWidth == other.screenshotWidth &&
            screenshotHeight == other.screenshotHeight &&
            capturedAtMillis == other.capturedAtMillis &&
            screenDataAllowed == other.screenDataAllowed &&
            source == other.source
    }

    override fun hashCode(): Int {
        var r = foregroundPackage.hashCode()
        r = 31 * r + texts.hashCode()
        r = 31 * r + (screenshotBytes?.contentHashCode() ?: 0)
        r = 31 * r + capturedAtMillis.hashCode()
        return r
    }
}

// The single pending summon. Process-memory only, one-shot, expiring.
object AssistBridge {
    const val EXPIRY_MS = 5 * 60 * 1000L

    @Volatile
    private var pending: AssistSnapshotData? = null

    fun store(snapshot: AssistSnapshotData) {
        pending = snapshot
    }

    /// The pending snapshot if still fresh; an expired one is dropped.
    fun peek(nowMillis: Long = System.currentTimeMillis()): AssistSnapshotData? {
        val p = pending ?: return null
        if (nowMillis - p.capturedAtMillis > EXPIRY_MS) {
            pending = null
            return null
        }
        return p
    }

    /// Consume the pending snapshot (one-shot: reading clears it).
    fun take(nowMillis: Long = System.currentTimeMillis()): AssistSnapshotData? {
        val p = peek(nowMillis)
        pending = null
        return p
    }

    fun clear() {
        pending = null
    }
}
