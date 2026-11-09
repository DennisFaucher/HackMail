import Foundation
import Network

/// One-shot watchdog for a pending `NWConnection` operation (connect or receive).
///
/// If the operation has not finished when the deadline passes, the connection is cancelled, which makes
/// the pending completion handler fire with an error. Call `finish()` once the operation returns; it
/// stops the timer and reports whether the deadline was what ended the operation so callers can surface
/// a timeout error instead of a generic cancellation.
final class ConnectionDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var timer: Task<Void, Never>?

    init(after duration: Duration, connection: NWConnection) {
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.lock.withLock { self.fired = true }
            connection.cancel()
        }
    }

    /// Stops the timer. Returns `true` if the deadline expired before this call.
    @discardableResult
    func finish() -> Bool {
        timer?.cancel()
        return lock.withLock { fired }
    }
}
