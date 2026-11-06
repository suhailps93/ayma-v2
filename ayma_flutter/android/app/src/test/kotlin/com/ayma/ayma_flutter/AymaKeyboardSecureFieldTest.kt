package com.ayma.ayma_flutter

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The constants used here are compile-time ints in the Android SDK, and
 * EditorInfo is a plain data holder, so these run as local JVM tests.
 */
class AymaKeyboardSecureFieldTest {

    private fun info(inputType: Int) = EditorInfo().apply { this.inputType = inputType }

    @Test
    fun passwordVariationsAreSecure() {
        assertTrue(AymaKeyboardService.isSecureField(info(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)))
        assertTrue(AymaKeyboardService.isSecureField(info(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)))
        assertTrue(AymaKeyboardService.isSecureField(info(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)))
        assertTrue(AymaKeyboardService.isSecureField(info(
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD)))
    }

    @Test
    fun normalFieldsAreNotSecure() {
        assertFalse(AymaKeyboardService.isSecureField(info(InputType.TYPE_CLASS_TEXT)))
        assertFalse(AymaKeyboardService.isSecureField(info(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_NORMAL)))
        assertFalse(AymaKeyboardService.isSecureField(null))
    }
}
