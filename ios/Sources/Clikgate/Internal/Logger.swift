import Foundation
import os.log

/// Never pass the SDK key, push tokens, identity tokens or pasteboard contents to the logger.
final class ClikgateLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: ClikgateOptions.LogLevel
    private let log = OSLog(subsystem: "com.clikgate.sdk", category: "Clikgate")
    private var loggedOnce = Set<String>()

    init(level: ClikgateOptions.LogLevel) { _level = level }

    var level: ClikgateOptions.LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _level }
        set { lock.lock(); _level = newValue; lock.unlock() }
    }

    func verbose(_ m: @autoclosure () -> String) { emit(.verbose, m) }
    func debug(_ m: @autoclosure () -> String) { emit(.debug, m) }
    func info(_ m: @autoclosure () -> String) { emit(.info, m) }
    func warning(_ m: @autoclosure () -> String) { emit(.warning, m) }
    func error(_ m: @autoclosure () -> String) { emit(.error, m) }

    /// Logs an error only the first time `key` is seen in this process.
    func errorOnce(_ key: String, _ m: @autoclosure () -> String) {
        lock.lock()
        let first = loggedOnce.insert(key).inserted
        lock.unlock()
        if first { emit(.error, m) }
    }

    private func emit(_ l: ClikgateOptions.LogLevel, _ m: () -> String) {
        guard l != .none, l >= level else { return }
        let type: OSLogType
        switch l {
        case .verbose, .debug: type = .debug
        case .info: type = .info
        case .warning: type = .default
        case .error, .none: type = .error
        }
        os_log("%{public}@", log: log, type: type, "[Clikgate] " + m())
    }
}
