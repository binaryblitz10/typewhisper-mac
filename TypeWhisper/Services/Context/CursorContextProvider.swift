import Foundation

/// Wraps the existing accessibility-based cursor surrounding-text capture as a
/// ``ContextProvider``. The actual AX work runs on the MainActor through
/// ``TextInsertionService``; this provider just adapts the result into the
/// shared ``ContextPayload`` shape.
struct CursorContextProvider: ContextProvider {
    static let type = "cursor_context"

    var typeIdentifier: String { Self.type }

    /// Pre-captured cursor context from the synchronous AX read at recording
    /// start. We don't re-capture here because the cursor may have moved by
    /// the time `collect` runs.
    let snapshot: CursorContext?

    init(snapshot: CursorContext?) {
        self.snapshot = snapshot
    }

    func capture() async -> ContextPayload? {
        guard let snapshot else { return nil }
        let formatted = Self.format(snapshot)
        guard !formatted.isEmpty else { return nil }
        return ContextPayload(type: Self.type, content: formatted)
    }

    static func format(_ context: CursorContext) -> String {
        var lines: [String] = []
        if let left = context.leftContext, !left.isEmpty {
            lines.append("Text before cursor:")
            lines.append(left)
        }
        if let right = context.rightContext, !right.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Text after cursor:")
            lines.append(right)
        }
        return lines.joined(separator: "\n")
    }
}
