package com.clikgate.internal

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

internal class QueuedEvent(val rowId: Long, val payload: JSONObject)

/**
 * Persistent FIFO of serialised `/events` items in SQLite `clikgate_events.db`.
 * Bounded by event count and total bytes; the oldest events are dropped when full.
 */
internal class EventQueue(context: Context) :
    SQLiteOpenHelper(context, DB_NAME, null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL, " +
                "payload TEXT NOT NULL, bytes INTEGER NOT NULL)",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    /** Adds an event, enforces the limits and returns the queue length. */
    @Synchronized
    fun add(payload: JSONObject, maxEvents: Int, maxBytes: Long, key: String = payload.optString("event_id")): Int {
        val text = payload.toString()
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.insert(TABLE, null, ContentValues().apply {
                put("event_id", key)
                put("payload", text)
                put("bytes", text.toByteArray(Charsets.UTF_8).size)
            })
            trim(db, maxEvents, maxBytes)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return count()
    }

    private fun trim(db: SQLiteDatabase, maxEvents: Int, maxBytes: Long) {
        var (count, bytes) = stats(db)
        if (count <= maxEvents && bytes <= maxBytes) return
        db.rawQuery("SELECT id, bytes FROM events ORDER BY id ASC", null).use { c ->
            var dropped = 0
            var lastId = -1L
            while ((count > maxEvents || bytes > maxBytes) && c.moveToNext()) {
                lastId = c.getLong(0)
                bytes -= c.getLong(1)
                count--
                dropped++
            }
            if (lastId >= 0) {
                db.delete(TABLE, "id <= ?", arrayOf(lastId.toString()))
                Log.w("Event queue full: dropped $dropped oldest event(s)")
            }
        }
    }

    private fun stats(db: SQLiteDatabase): Pair<Int, Long> =
        db.rawQuery("SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM events", null).use { c ->
            c.moveToFirst()
            c.getInt(0) to c.getLong(1)
        }

    @Synchronized
    fun peek(limit: Int): List<QueuedEvent> {
        val out = ArrayList<QueuedEvent>()
        readableDatabase.rawQuery("SELECT id, payload FROM events ORDER BY id ASC LIMIT $limit", null).use { c ->
            while (c.moveToNext()) {
                try {
                    out.add(QueuedEvent(c.getLong(0), JSONObject(c.getString(1))))
                } catch (_: Exception) {
                    writableDatabase.delete(TABLE, "id = ?", arrayOf(c.getLong(0).toString()))
                }
            }
        }
        return out
    }

    @Synchronized
    fun remove(rowIds: Collection<Long>) {
        if (rowIds.isEmpty()) return
        writableDatabase.delete(TABLE, "id IN (${rowIds.joinToString(",")})", null)
    }

    /** Drops events whose `occurred_at` is before [cutoffIso] (same ISO format); returns how many. */
    @Synchronized
    fun dropOlderThan(cutoffIso: String): Int {
        val old = ArrayList<Long>()
        readableDatabase.rawQuery("SELECT id, payload FROM events ORDER BY id ASC", null).use { c ->
            while (c.moveToNext()) {
                val at = try {
                    JSONObject(c.getString(1)).optString("occurred_at")
                } catch (_: Exception) {
                    ""
                }
                if (at < cutoffIso) old.add(c.getLong(0))
            }
        }
        remove(old)
        return old.size
    }

    /** Keeps the newest [max] events. */
    @Synchronized
    fun trimTo(max: Int) {
        val db = writableDatabase
        trim(db, max, Long.MAX_VALUE)
    }

    /** True when an item with this `event_id` column (event id, or a goal's dedupe key) is queued. */
    @Synchronized
    fun contains(key: String): Boolean =
        readableDatabase.rawQuery("SELECT 1 FROM events WHERE event_id = ? LIMIT 1", arrayOf(key)).use { it.moveToFirst() }

    @Synchronized
    fun count(): Int = stats(readableDatabase).first

    @Synchronized
    fun clear() {
        writableDatabase.delete(TABLE, null, null)
    }

    companion object {
        const val DB_NAME = "clikgate_events.db"
        private const val TABLE = "events"
    }
}
