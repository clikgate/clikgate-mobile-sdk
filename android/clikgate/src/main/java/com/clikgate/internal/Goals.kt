package com.clikgate.internal

import com.clikgate.ClikgateError
import com.clikgate.GoalKind
import com.clikgate.GoalResult
import com.clikgate.GoalStatus
import org.json.JSONObject
import java.math.BigDecimal
import java.util.UUID

/** `goal()` items for `POST /v1/sdk/goals`, and their results. */
internal object Goals {
    private val KEY = Regex("^[a-z][a-z0-9_]{1,39}$")
    private val CURRENCY = Regex("^[A-Z]{3}$")
    const val MAX_SIGNIFICANT_DIGITS = 15
    const val MAX_REFERENCE = 128

    /** The server's reason for a name that isn't set up as a goal while the organisation accepts only set-up goals. */
    const val UNKNOWN_GOAL = "unknown_goal"

    /** Queue dedupe key of a goal: the server's idempotency key `(goal, reference)`, hashed. */
    fun dedupeKey(goal: String, reference: String): String = "goal:" + Core.hash("$goal:$reference")

    fun isGoal(payload: JSONObject): Boolean = payload.has("goal")

    /**
     * The wire string of [value]: plain notation, trailing fractional zeros removed
     * (`2E+6` → `"2000000"`, `1500.50` → `"1500.5"`). Throws `invalid_argument` when negative or
     * over 15 significant digits.
     */
    fun wireValue(value: BigDecimal): String {
        if (value.signum() < 0) throw invalid("Goal value must be zero or more", "value")
        val plain = if (value.signum() == 0) "0" else value.stripTrailingZeros().toPlainString()
        if (significantDigits(plain) > MAX_SIGNIFICANT_DIGITS) {
            throw invalid("Goal value has more than $MAX_SIGNIFICANT_DIGITS significant digits", "value")
        }
        return plain
    }

    private val PLAIN = Regex("^[0-9]+(\\.[0-9]+)?$")

    /** Parses a wrapper's decimal string (`"1500.50"`, no sign / exponent); null when malformed. */
    fun parseValue(text: String): BigDecimal? {
        val t = text.trim()
        if (t.startsWith("-") && PLAIN.matches(t.substring(1))) return BigDecimal(t) // negative: rejected by wireValue
        return if (PLAIN.matches(t)) BigDecimal(t) else null
    }

    /** Digits left after removing leading zeros and trailing fractional zeros. */
    fun significantDigits(plain: String): Int {
        var s = plain
        if ('.' in s) s = s.trimEnd('0').trimEnd('.')
        return s.replace(".", "").trimStart('0').length
    }

    /** Builds a `/goals` item, validating locally. Throws [ClikgateError] (`invalid_argument`). */
    fun build(
        key: String,
        value: BigDecimal?,
        currency: String?,
        reference: String?,
        provider: String?,
        isFirst: Boolean?,
        clickId: String?,
        now: Long,
    ): JSONObject {
        if (!KEY.matches(key)) throw invalid("Goal key must be snake_case, 2-40 characters (^[a-z][a-z0-9_]*\$)", "goal")
        val o = JSONObject().put("goal", key)
        if (reference != null && (reference.isBlank() || reference.length > MAX_REFERENCE)) {
            throw invalid("Goal reference must be 1-$MAX_REFERENCE characters", "reference")
        }
        o.put("reference", reference ?: UUID.randomUUID().toString())
        value?.let { o.put("value", wireValue(it)) }
        currency?.let {
            if (!CURRENCY.matches(it)) throw invalid("Currency must be 3 uppercase letters (ISO 4217)", "currency")
            o.put("currency", it)
        }
        isFirst?.let { o.put("is_first", it) }
        o.put("occurred_at", Core.isoTimestamp(now))
        if (clickId != null) o.put("click_id", clickId)
        if (provider != null) o.put("provider", provider)
        return o
    }

    fun refused(reason: String): GoalResult = GoalResult(GoalStatus.REFUSED, reason, null, false)

    /** One `results[]` item of the `/goals` response. Unknown statuses are refusals with the raw value as reason. */
    fun result(o: JSONObject): GoalResult {
        val raw = o.optString("status")
        val status = GoalStatus.values().firstOrNull { it.value == raw }
        val kind = GoalKind.values().firstOrNull { it.value == o.optString("goal_kind") }
        val reason = if (o.isNull("reason")) null else o.optString("reason").ifEmpty { null }
        return GoalResult(status ?: GoalStatus.REFUSED, if (status == null) raw.ifEmpty { "unknown" } else reason, kind, o.optBoolean("value_ignored"))
    }

    private fun invalid(msg: String, param: String) = ClikgateError(ClikgateError.INVALID_ARGUMENT, msg, param = param)
}
