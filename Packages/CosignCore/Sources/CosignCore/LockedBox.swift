import Foundation

public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ initial: Value) {
        self.storage = initial
    }

    public func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
