import Foundation

/// A structured piece of supplemental context attached to an AI request.
///
/// Lives only for the duration of one workflow invocation. Providers produce
/// these; the prompt-assembly layer wraps them into a `<contexts>` block so
/// the LLM can tell user instruction from environment-derived signals.
struct ContextPayload: Sendable, Equatable {
    /// Stable identifier the model sees as `type="..."` (e.g. `cursor_context`, `screen_ocr`).
    let type: String
    /// Raw content. Providers do not aggressively clean — short labels, IDs, and
    /// fragments may all be load-bearing for the model.
    let content: String
}

/// Source of supplemental context for an AI workflow.
///
/// Each provider owns its own capture, formatting, and failure handling.
/// Implementations must never throw — failure returns `nil` and the workflow
/// proceeds without the context.
protocol ContextProvider: Sendable {
    /// Stable identifier (used as `ContextPayload.type` and for logging).
    var typeIdentifier: String { get }

    /// Capture context. Returns `nil` if nothing was produced (disabled,
    /// permission denied, empty result, failure). Must not throw.
    func capture() async -> ContextPayload?
}
