package com.clikgate.internal

import android.net.Uri

/**
 * The path of a handled deep link as reported for the live check (`deeplink_handled`): no query or fragment,
 * and every segment that looks like an ID, an email address or a phone number replaced with `:id`.
 */
internal object DeepLinkPath {
    private const val MAX = 512

    fun clean(path: String): String {
        val p = path.substringBefore('?').substringBefore('#').split('/')
            .joinToString("/") { if (isId(Uri.decode(it))) ":id" else it }
        return if (p.isEmpty()) "/" else p.take(MAX)
    }

    /**
     * An `@`; only digits and `+-.() ` (numbers, phone numbers); or a run of letters and digits with a digit
     * and 6+ characters, or 16+ characters in mixed case (UUIDs, hex and base64-like tokens, codes).
     */
    fun isId(s: String): Boolean {
        if ('@' in s || s.any { it in '0'..'9' } && s.all { it in '0'..'9' || it in "+-.() " }) return true
        return s.split(Regex("[^A-Za-z0-9]+")).any { run ->
            if (run.any { it in '0'..'9' }) run.length >= 6
            else run.length >= 16 && run.any { it.isUpperCase() } && run.any { it.isLowerCase() }
        }
    }
}
