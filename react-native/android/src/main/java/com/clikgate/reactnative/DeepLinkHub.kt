package com.clikgate.reactnative

import com.clikgate.Clikgate
import java.lang.ref.WeakReference

/**
 * One SDK deep-link listener for the process (the SDK supports a single listener). Survives
 * React Native reloads: the current module instance is attached on creation. Links that arrive
 * while no JS listener is subscribed (or no module/React instance exists) are buffered (latest
 * 10) and flushed when JS adds its first listener. The SDK calls back on the main thread.
 */
internal object DeepLinkHub {
  private const val CAPACITY = 10

  private var module: WeakReference<ClikgateModule>? = null
  private var listenerCount = 0
  private val buffer = ArrayDeque<Map<String, Any?>>()
  private var installed = false

  @Synchronized
  fun attach(m: ClikgateModule) {
    module = WeakReference(m)
    listenerCount = 0
    if (!installed) {
      installed = true
      Clikgate.onDeepLink { link -> dispatch(BridgeMaps.deepLink(link)) }
      // Browser handoffs share the ClikgateDeepLink event, tagged.
      Clikgate.onBrowserHandoff { h -> dispatch(mapOf("event" to "browserHandoff", "url" to h.url, "host" to h.host)) }
    }
  }

  @Synchronized
  fun detach(m: ClikgateModule) {
    if (module?.get() === m) {
      module = null
      listenerCount = 0
    }
  }

  @Synchronized
  fun addListener(m: ClikgateModule) {
    if (module?.get() !== m) return
    listenerCount++
    flush(m)
  }

  @Synchronized
  fun removeListeners(m: ClikgateModule, count: Int) {
    if (module?.get() !== m) return
    listenerCount = (listenerCount - count).coerceAtLeast(0)
  }

  @Synchronized
  private fun dispatch(event: Map<String, Any?>) {
    val m = module?.get()
    if (m == null || listenerCount == 0 || !m.emit(event)) {
      buffer.addLast(event)
      while (buffer.size > CAPACITY) buffer.removeFirst()
    }
  }

  private fun flush(m: ClikgateModule) {
    while (buffer.isNotEmpty()) {
      if (!m.emit(buffer.first())) return
      buffer.removeFirst()
    }
  }
}
