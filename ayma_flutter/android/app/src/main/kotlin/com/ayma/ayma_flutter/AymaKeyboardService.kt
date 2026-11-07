package com.ayma.ayma_flutter

import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Ayma Keyboard V1 — Android InputMethodService.
 *
 * What it is: a plain letter keyboard plus the Ayma strip. The strip
 * shows the draft the user sent from Ayma ("Send to Ayma Keyboard") and
 * an Insert button that commits it with
 * `InputConnection.commitText`. That explicit user tap is the only way
 * Ayma text ever enters another app — Ayma never types on her own.
 *
 * Privacy posture (hard requirements, also in docs/AYMA_KEYBOARD.md):
 *  - No keystroke logging, storage, or transmission of any kind. Key
 *    presses go straight to the current InputConnection and nowhere
 *    else. This class contains no logging calls at all.
 *  - No network calls from the IME. This class (and the draft store)
 *    reference no networking APIs.
 *  - Secure fields: for password input variations the strip shows no
 *    draft text and Insert is disabled (see [isSecureField]). Android
 *    additionally does not expose password field contents to IMEs and
 *    many secure screens force the system keyboard / FLAG_SECURE; our
 *    own guard is defence in depth on top of that.
 *  - The "Draft with Ayma" stretch is intentionally NOT in V1: the IME
 *    has no signed-in session of its own, and handing it auth tokens
 *    would break the no-network / no-credentials posture above. Drafts
 *    are made in the app, where the session lives.
 */
class AymaKeyboardService : InputMethodService() {

    private var stripText: TextView? = null
    private var insertButton: Button? = null
    private var clearButton: Button? = null
    private var rootView: LinearLayout? = null
    private var secureField = false
    private var shiftOn = false
    private val letterButtons = mutableListOf<Button>()

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(26, 23, 20))
            setPadding(dp(6), dp(6), dp(6), dp(8))
        }
        rootView = root
        root.addView(buildStrip())
        buildLetterRows(root)
        refreshStrip()
        return root
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        secureField = isSecureField(attribute)
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        secureField = isSecureField(info)
        refreshStrip()
    }

    private fun buildStrip(): LinearLayout {
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(6), dp(4), dp(6))
            setBackgroundColor(Color.rgb(38, 34, 30))
        }
        val label = TextView(this).apply {
            setTextColor(Color.rgb(250, 248, 244))
            textSize = 13f
            maxLines = 2
            layoutParams =
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        stripText = label
        strip.addView(label)

        val insert = Button(this).apply {
            text = "Insert"
            setOnClickListener { insertDraft() }
        }
        insertButton = insert
        strip.addView(insert)

        val clear = Button(this).apply {
            text = "✕"
            contentDescription = "Clear Ayma draft"
            setOnClickListener {
                KeyboardDraftFile(filesDir).clear()
                refreshStrip()
            }
        }
        clearButton = clear
        strip.addView(clear)
        return strip
    }

    private fun buildLetterRows(root: LinearLayout) {
        val rows = listOf("1234567890", "qwertyuiop", "asdfghjkl")
        for (row in rows) {
            root.addView(keyRow(row.map { it.toString() }))
        }
        // Row 4: shift, zxcvbnm, delete.
        val row4 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        row4.addView(specialKey("⇧") {
            shiftOn = !shiftOn
            relabelLetters()
        })
        for (letter in "zxcvbnm") {
            row4.addView(letterKey(letter.toString()))
        }
        row4.addView(specialKey("⌫") {
            currentInputConnection?.deleteSurroundingText(1, 0)
        })
        root.addView(row4)

        // Bottom row: keyboard switcher, comma, space, period, enter.
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        bottom.addView(specialKey("🌐") {
            val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
            imm?.showInputMethodPicker()
        })
        bottom.addView(letterKey(","))
        val space = Button(this).apply {
            text = "space"
            layoutParams = LinearLayout.LayoutParams(0, dp(48), 3f)
            setOnClickListener { commit(" ") }
        }
        bottom.addView(space)
        bottom.addView(letterKey("."))
        bottom.addView(specialKey("↵") { pressEnter() })
        root.addView(bottom)
    }

    private fun keyRow(keys: List<String>): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        for (key in keys) row.addView(letterKey(key))
        return row
    }

    private fun letterKey(label: String): Button {
        val button = Button(this).apply {
            text = label
            textSize = 16f
            isAllCaps = false
            layoutParams = LinearLayout.LayoutParams(0, dp(48), 1f)
            setOnClickListener {
                val value = if (shiftOn && label.length == 1 && label[0].isLetter()) {
                    label.uppercase()
                } else {
                    label
                }
                commit(value)
                if (shiftOn) {
                    shiftOn = false
                    relabelLetters()
                }
            }
        }
        if (label.length == 1 && label[0].isLetter()) letterButtons.add(button)
        return button
    }

    private fun specialKey(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 16f
            isAllCaps = false
            layoutParams = LinearLayout.LayoutParams(0, dp(48), 1.2f)
            setOnClickListener { action() }
        }

    private fun relabelLetters() {
        for (button in letterButtons) {
            val current = button.text.toString()
            button.text = if (shiftOn) current.uppercase() else current.lowercase()
        }
    }

    private fun commit(text: String) {
        // Direct to the host app field only. Never logged or stored.
        currentInputConnection?.commitText(text, 1)
    }

    private fun pressEnter() {
        val ic = currentInputConnection ?: return
        val editorInfo = currentInputEditorInfo
        val action = editorInfo?.imeOptions?.and(EditorInfo.IME_MASK_ACTION)
        if (action != null &&
            action != EditorInfo.IME_ACTION_NONE &&
            action != EditorInfo.IME_ACTION_UNSPECIFIED
        ) {
            ic.performEditorAction(action)
        } else {
            ic.commitText("\n", 1)
        }
    }

    private fun insertDraft() {
        if (secureField) return
        val draft = KeyboardDraftFile(filesDir).read() ?: return
        val payload = draft.formatForInsertAt(System.currentTimeMillis()) ?: run {
            refreshStrip()
            return
        }
        currentInputConnection?.commitText(payload, 1)
    }

    private fun refreshStrip() {
        val label = stripText ?: return
        val insert = insertButton ?: return
        val clear = clearButton ?: return
        if (secureField) {
            label.text = "Ayma draft hidden in password fields"
            insert.isEnabled = false
            clear.isEnabled = false
            return
        }
        clear.isEnabled = true
        val draft = KeyboardDraftFile(filesDir).read()
        when {
            draft == null -> {
                label.text = "No Ayma draft — draft one in Ayma, tap Send to Ayma Keyboard"
                insert.isEnabled = false
            }
            draft.isExpiredAt(System.currentTimeMillis()) -> {
                label.text = "Ayma draft expired (over 1 hour old) — send a fresh one from Ayma"
                insert.isEnabled = false
            }
            else -> {
                label.text = "Ayma draft: ${draft.text}"
                insert.isEnabled = true
            }
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    companion object {
        /**
         * True for password / secure text variations. Pure function of the
         * EditorInfo inputType so it is JVM-testable: the IME must offer
         * nothing from the Ayma strip in these fields.
         */
        fun isSecureField(info: EditorInfo?): Boolean {
            val inputType = info?.inputType ?: return false
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            val clazz = inputType and InputType.TYPE_MASK_CLASS
            return when (clazz) {
                InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
                InputType.TYPE_CLASS_NUMBER ->
                    variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
                else -> false
            }
        }
    }
}
