package com.clikgate

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.fail

/**
 * Minimal JSON Schema (2020-12 subset used by shared/schemas) check: type, const, enum,
 * required, properties, additionalProperties: false, items, minItems/maxItems, anyOf, pattern,
 * minLength/maxLength, minimum. Enough to keep SDK requests and parsed fixtures on contract
 * without adding a validator dependency.
 */
internal object SchemaCheck {
    fun schema(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader!!.getResource("schemas/$name.schema.json")) { "schema $name missing" }.readText(),
    )

    fun assertValid(schemaName: String, value: Any?) {
        val errors = ArrayList<String>()
        check(schema(schemaName), value, "$", errors)
        if (errors.isNotEmpty()) fail("$schemaName: ${errors.joinToString("; ")}\n$value")
    }

    private fun typeOk(type: String, v: Any?): Boolean = when (type) {
        "object" -> v is JSONObject
        "array" -> v is JSONArray
        "string" -> v is String
        "boolean" -> v is Boolean
        "integer" -> v is Int || v is Long
        "number" -> v is Number
        "null" -> v == null || v == JSONObject.NULL
        else -> true
    }

    private fun check(s: JSONObject, raw: Any?, at: String, errors: MutableList<String>) {
        val v = if (raw == JSONObject.NULL) null else raw
        s.optJSONArray("anyOf")?.let { alts ->
            val ok = (0 until alts.length()).any { i -> ArrayList<String>().also { check(alts.getJSONObject(i), v, at, it) }.isEmpty() }
            if (!ok) errors.add("$at matches no anyOf branch")
            return
        }
        if (s.has("const") && s.get("const") != (v ?: JSONObject.NULL)) errors.add("$at != const ${s.get("const")}")
        s.optJSONArray("enum")?.let { e ->
            if ((0 until e.length()).none { e.get(it) == (v ?: JSONObject.NULL) }) errors.add("$at=$v not in enum $e")
        }
        when (val t = s.opt("type")) {
            is String -> if (!typeOk(t, v)) errors.add("$at is not $t")
            is JSONArray -> if ((0 until t.length()).none { typeOk(t.getString(it), v) }) errors.add("$at is not one of $t")
        }
        if (v is String) {
            s.optString("pattern").takeIf { it.isNotEmpty() }?.let { if (!Regex(it).containsMatchIn(v)) errors.add("$at=\"$v\" !~ $it") }
            if (s.has("minLength") && v.length < s.getInt("minLength")) errors.add("$at shorter than ${s.getInt("minLength")}")
            if (s.has("maxLength") && v.length > s.getInt("maxLength")) errors.add("$at longer than ${s.getInt("maxLength")}")
        }
        if (v is Number && s.has("minimum") && v.toDouble() < s.getDouble("minimum")) errors.add("$at < minimum")
        if (v is JSONObject) {
            val props = s.optJSONObject("properties") ?: JSONObject()
            s.optJSONArray("required")?.let { r -> for (i in 0 until r.length()) if (!v.has(r.getString(i))) errors.add("$at.${r.getString(i)} missing") }
            if (s.opt("additionalProperties") == false) {
                v.keys().forEach { if (!props.has(it)) errors.add("$at.$it not allowed") }
            }
            props.keys().forEach { k -> if (v.has(k)) check(props.getJSONObject(k), v.get(k), "$at.$k", errors) }
        }
        if (v is JSONArray) {
            if (s.has("minItems") && v.length() < s.getInt("minItems")) errors.add("$at has fewer than ${s.getInt("minItems")} items")
            if (s.has("maxItems") && v.length() > s.getInt("maxItems")) errors.add("$at has more than ${s.getInt("maxItems")} items")
            s.optJSONObject("items")?.let { item -> for (i in 0 until v.length()) check(item, v.get(i), "$at[$i]", errors) }
        }
    }
}
