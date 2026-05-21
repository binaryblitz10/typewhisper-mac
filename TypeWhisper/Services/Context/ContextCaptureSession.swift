import Foundation
import os.log

private let contextSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "ContextCaptureSession"
)

/// Coordinates one workflow's worth of context-provider captures.
///
/// Providers are launched eagerly (so OCR or other slow work runs while the
/// user is still speaking). Results are collected at the end of recording via
/// ``collect(timeout:)`` — synchronous-feeling providers complete instantly,
/// async ones (OCR) are awaited with a bounded timeout so they never block
/// the workflow indefinitely.
///
/// One session per recording. Discard after `collect` to enforce
/// ephemeral-only context.
final class ContextCaptureSession: @unchecked Sendable {
    private struct PendingCapture {
        let typeIdentifier: String
        let task: Task<ContextPayload?, Never>
    }

    private let lock = NSLock()
    private var pending: [PendingCapture] = []
    private var collected = false

    /// Launch a provider's capture immediately, in the background.
    /// `onCapture` is called on an arbitrary thread as soon as the provider
    /// finishes — use it to update live UI state before `collect` is called.
    func start(_ provider: any ContextProvider, onCapture: (@Sendable (ContextPayload?) -> Void)? = nil) {
        let typeIdentifier = provider.typeIdentifier
        let task = Task.detached(priority: .userInitiated) {
            let payload = await provider.capture()
            onCapture?(payload)
            return payload
        }
        lock.lock()
        pending.append(PendingCapture(typeIdentifier: typeIdentifier, task: task))
        lock.unlock()
    }

    /// Await all in-flight providers, bounded by `timeout`. Providers that
    /// time out are cancelled and dropped (the workflow continues without
    /// them — context is best-effort).
    func collect(timeout: TimeInterval) async -> [ContextPayload] {
        let snapshot: [PendingCapture] = {
            lock.lock()
            defer { lock.unlock() }
            if collected { return [] }
            collected = true
            let taken = pending
            pending.removeAll()
            return taken
        }()

        guard !snapshot.isEmpty else { return [] }

        return await withTaskGroup(of: ContextPayload?.self) { group in
            for capture in snapshot {
                group.addTask {
                    await Self.awaitWithTimeout(
                        capture: capture,
                        timeout: timeout
                    )
                }
            }
            var results: [ContextPayload] = []
            for await payload in group {
                if let payload {
                    results.append(payload)
                }
            }
            return results
        }
    }

    /// Cancel everything without collecting (used when the workflow aborts).
    func cancel() {
        lock.lock()
        let snapshot = pending
        pending.removeAll()
        collected = true
        lock.unlock()
        for capture in snapshot {
            capture.task.cancel()
        }
    }

    private static func awaitWithTimeout(
        capture: PendingCapture,
        timeout: TimeInterval
    ) async -> ContextPayload? {
        let typeIdentifier = capture.typeIdentifier
        let task = capture.task
        return await withTaskGroup(of: ContextPayload?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            task.cancel()
            if result == nil {
                contextSessionLogger.info("Context provider \(typeIdentifier, privacy: .public) timed out or returned nil")
            }
            return result
        }
    }
}
