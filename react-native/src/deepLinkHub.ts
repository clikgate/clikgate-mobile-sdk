import {
  browserHandoffFromMap,
  deepLinkFromMap,
  type ClikgateBrowserHandoff,
  type ClikgateDeepLink,
} from './models';

export type DeepLinkListener = (link: ClikgateDeepLink) => void;
export type BrowserHandoffListener = (handoff: ClikgateBrowserHandoff) => void;
type Subscribe = (handler: (event: unknown) => void) => (() => void) | null;

/**
 * App listeners of one kind of item. Items that arrive while nobody listens are buffered
 * (latest `capacity`) and replayed to the next (first) listener.
 */
class Fanout<T> {
  private readonly listeners = new Set<(item: T) => void>();
  private buffer: T[] = [];

  constructor(
    private readonly capacity: number,
    private readonly label: string
  ) {}

  add(listener: (item: T) => void): () => void {
    const wasEmpty = this.listeners.size === 0;
    this.listeners.add(listener);
    if (wasEmpty && this.buffer.length > 0) {
      Promise.resolve().then(() => this.replay(listener));
    }
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      this.listeners.delete(listener);
    };
  }

  get size(): number {
    return this.listeners.size;
  }

  emit(item: T): void {
    if (this.listeners.size === 0) {
      this.buffer.push(item);
      if (this.buffer.length > this.capacity) {
        this.buffer.splice(0, this.buffer.length - this.capacity);
      }
      return;
    }
    for (const listener of Array.from(this.listeners))
      this.deliver(listener, item);
  }

  clear(): void {
    this.listeners.clear();
    this.buffer = [];
  }

  private replay(listener: (item: T) => void): void {
    // The listener may have unsubscribed before the microtask ran: keep the items then.
    if (!this.listeners.has(listener)) return;
    const pending = this.buffer;
    this.buffer = [];
    for (const item of pending) this.deliver(listener, item);
  }

  private deliver(listener: (item: T) => void, item: T): void {
    try {
      listener(item);
    } catch (e) {
      // One failing listener must not break the others (or the native event loop).
      console.error(`Clikgate: ${this.label} listener threw`, e);
    }
  }
}

/**
 * Receives deep links and browser handoffs from the native module and fans them out to app
 * listeners. Both arrive on the native `ClikgateDeepLink` event; a handoff is tagged
 * `event: "browserHandoff"`. Items that arrive while nobody
 * listens are buffered (latest `capacity`) and replayed to the next (first) listener — the same
 * behaviour as the Flutter plugin's broadcast streams.
 *
 * The native side buffers too (latest 10) until the JS side subscribes, which happens in
 * `Clikgate.configure` (or the first `onDeepLink` / `onBrowserHandoff`), so nothing received at
 * cold start is lost.
 */
export class DeepLinkHub {
  private readonly links: Fanout<ClikgateDeepLink>;
  private readonly handoffs: Fanout<ClikgateBrowserHandoff>;
  private unsubscribeNative: (() => void) | null = null;
  private started = false;

  constructor(
    private readonly subscribe: Subscribe,
    capacity = 10
  ) {
    this.links = new Fanout(capacity, 'onDeepLink');
    this.handoffs = new Fanout(capacity, 'onBrowserHandoff');
  }

  /** Starts listening to the native module (which then flushes its own buffer). */
  start(): void {
    if (this.started) return;
    this.started = true;
    this.unsubscribeNative = this.subscribe((event) => this.onEvent(event));
  }

  /**
   * Adds a deep-link listener and returns its unsubscribe function. When it is the first
   * listener, buffered links are replayed to it (asynchronously, right after this call returns).
   */
  addListener(listener: DeepLinkListener): () => void {
    this.start();
    return this.links.add(listener);
  }

  /** Adds a browser-handoff listener; same buffering and replay as `addListener`. */
  addHandoffListener(listener: BrowserHandoffListener): () => void {
    this.start();
    return this.handoffs.add(listener);
  }

  get listenerCount(): number {
    return this.links.size;
  }

  private onEvent(event: unknown): void {
    if (
      typeof event === 'object' &&
      event !== null &&
      (event as { event?: unknown }).event === 'browserHandoff'
    ) {
      this.handoffs.emit(browserHandoffFromMap(event));
    } else {
      this.links.emit(deepLinkFromMap(event));
    }
  }

  /** Stops listening and drops buffered items and listeners. */
  dispose(): void {
    this.unsubscribeNative?.();
    this.unsubscribeNative = null;
    this.started = false;
    this.links.clear();
    this.handoffs.clear();
  }
}
