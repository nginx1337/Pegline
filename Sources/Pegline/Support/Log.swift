import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "app.pegline"'
enum Log {
    nonisolated static let detection = Logger(subsystem: "app.pegline", category: "detection")
    nonisolated static let store = Logger(subsystem: "app.pegline", category: "store")
    nonisolated static let line = Logger(subsystem: "app.pegline", category: "line")
    nonisolated static let system = Logger(subsystem: "app.pegline", category: "system")
    nonisolated static let actions = Logger(subsystem: "app.pegline", category: "actions")
}
