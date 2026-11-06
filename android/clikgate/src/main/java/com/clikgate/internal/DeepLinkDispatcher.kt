package com.clikgate.internal

import android.os.Handler
import android.os.Looper
import com.clikgate.BrowserHandoffListener
import com.clikgate.ClikgateBrowserHandoff
import com.clikgate.ClikgateDeepLink
import com.clikgate.DeepLinkListener

/**
 * Delivers items to the app's single listener on the main thread. Items that arrive while no
 * listener is registered are buffered (latest [capacity]) and flushed on registration.
 */
internal open class Dispatcher<L : Any, T>(private val capacity: Int, private val call: (L, T) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val buffer = ArrayDeque<T>()
    private var listener: L? = null

    fun setListener(l: L?) {
        val toFlush: List<T>
        synchronized(this) {
            listener = l
            toFlush = if (l != null) buffer.toList().also { buffer.clear() } else emptyList()
        }
        if (l != null && toFlush.isNotEmpty()) main.post { toFlush.forEach { deliverTo(l, it) } }
    }

    fun dispatch(item: T) {
        val l = synchronized(this) {
            listener ?: run {
                buffer.addLast(item)
                while (buffer.size > capacity) buffer.removeFirst()
                null
            }
        } ?: return
        main.post { deliverTo(l, item) }
    }

    private fun deliverTo(l: L, item: T) {
        try {
            call(l, item)
        } catch (t: Throwable) {
            Log.e("Clikgate listener threw", t)
            throw t
        }
    }

    @Synchronized
    fun bufferedCount(): Int = buffer.size

    @Synchronized
    fun reset() {
        listener = null
        buffer.clear()
    }
}

internal class DeepLinkDispatcher(capacity: Int = 10) :
    Dispatcher<DeepLinkListener, ClikgateDeepLink>(capacity, { l, d -> l.onDeepLink(d) })

/** Shared-domain links the SDK opened in an in-app browser. */
internal class HandoffDispatcher : Dispatcher<BrowserHandoffListener, ClikgateBrowserHandoff>(10, { l, h -> l.onBrowserHandoff(h) })
