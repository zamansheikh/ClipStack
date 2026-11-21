package com.silifton.clipstack

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Optional "ClipStack paste" service. Android only lets an Accessibility
 * service paste into another app's text field; this one does exactly that,
 * and only when the bubble's Paste button is tapped. It ignores events and
 * never reads screen content beyond finding the focused field.
 */
class PasteAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    /** Pastes the clipboard into the field that has input focus, if any. */
    fun pasteIntoFocusedField(): Boolean {
        val roots = buildList {
            rootInActiveWindow?.let(::add)
            windows.mapNotNullTo(this) { it.root }
        }
        for (root in roots) {
            val field = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: continue
            if (field.isEditable && field.performAction(AccessibilityNodeInfo.ACTION_PASTE)) return true
        }
        return false
    }

    companion object {
        @Volatile var instance: PasteAccessibilityService? = null
            private set

        /** Whether the user switched the service on in Accessibility settings. */
        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            return enabled.split(':').any {
                it.equals("${context.packageName}/${PasteAccessibilityService::class.java.name}", ignoreCase = true) ||
                    it.equals("${context.packageName}/.PasteAccessibilityService", ignoreCase = true)
            }
        }
    }
}
