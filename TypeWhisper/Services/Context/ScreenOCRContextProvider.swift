import AppKit
import CoreGraphics
import Foundation
import Vision
import os.log

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

private let ocrLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "ScreenOCRContextProvider"
)

/// Captures a single screenshot of the visible desktop at workflow start and
/// runs Apple's Vision OCR over it. The extracted text is attached to the AI
/// request as `<context type="screen_ocr">` and discarded immediately after.
///
/// Ephemeral by construction: this provider holds no references after
/// ``capture()`` returns and writes nothing to disk.
struct ScreenOCRContextProvider: ContextProvider {
    static let type = "screen_ocr"

    /// Hard upper bound on a captured image's longer side, scaled before OCR
    /// to keep Vision responsive on multi-monitor or Retina setups. Vision's
    /// `.accurate` recognition level handles ~3000px reliably without an
    /// undue latency hit.
    private static let maxImageDimension: CGFloat = 3000

    var typeIdentifier: String { Self.type }

    func capture() async -> ContextPayload? {
        guard Self.hasScreenRecordingPermission() else {
            ocrLogger.info("Screen recording permission not granted; skipping OCR context")
            return nil
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let image = await Self.captureScreenImage() else {
            ocrLogger.info("Screen capture produced no image; skipping OCR context")
            return nil
        }
        let captureMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

        let recognized = await Self.recognizeText(in: image)
        let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

        let cleaned = Self.normalize(recognized)
        guard !cleaned.isEmpty else {
            ocrLogger.info("OCR returned no usable text (captureMs=\(String(format: "%.1f", captureMs), privacy: .public), totalMs=\(String(format: "%.1f", totalMs), privacy: .public))")
            return nil
        }

        ocrLogger.info("OCR context captured: chars=\(cleaned.count, privacy: .public), captureMs=\(String(format: "%.1f", captureMs), privacy: .public), totalMs=\(String(format: "%.1f", totalMs), privacy: .public)")

        return ContextPayload(type: Self.type, content: cleaned)
    }

    // MARK: - Permission

    /// Probe-only: never triggers the system prompt. We surface the prompt
    /// from the UI toggle instead so users opt in deliberately.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt if not yet granted. Safe to call
    /// repeatedly; returns the current grant state.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    private static func captureScreenImage() async -> CGImage? {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 14.0, *) {
            do {
                return try await captureViaScreenCaptureKit()
            } catch {
                ocrLogger.error("ScreenCaptureKit capture failed: \(String(describing: error), privacy: .public)")
            }
        }
        #endif

        // Fallback path (deprecated on macOS 14+ but still functional).
        return captureViaCGWindowList()
    }

    #if canImport(ScreenCaptureKit)
    @available(macOS 14.0, *)
    private static func captureViaScreenCaptureKit() async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Prefer the display under the mouse so multi-monitor setups capture
        // what the user is actually looking at; fall back to first display.
        let cursorLocation = NSEvent.mouseLocation
        let display = content.displays.first(where: { display in
            NSRect(
                x: CGFloat(display.frame.origin.x),
                y: CGFloat(display.frame.origin.y),
                width: CGFloat(display.frame.size.width),
                height: CGFloat(display.frame.size.height)
            ).contains(cursorLocation)
        }) ?? content.displays.first

        guard let display else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.size.width)
        config.height = Int(display.frame.size.height)
        config.showsCursor = false
        config.capturesAudio = false
        // No need for high frame rate; this is a one-shot screenshot.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }
    #endif

    private static func captureViaCGWindowList() -> CGImage? {
        // Final fallback. CGWindowListCreateImage is deprecated on macOS 14+
        // but still works when ScreenCaptureKit is unavailable (rare).
        return CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage) async -> [String] {
        let scaled = downscaledIfNeeded(image)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    ocrLogger.error("Vision OCR error: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // Vision returns observations in approximate top-down /
                // left-right order; preserve that as line ordering.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Best-effort multi-language detection — let Vision pick.
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: scaled, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    ocrLogger.error("Vision OCR perform threw: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private static func downscaledIfNeeded(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxImageDimension else { return image }

        let scale = maxImageDimension / longest
        let newWidth = Int((width * scale).rounded())
        let newHeight = Int((height * scale).rounded())
        guard newWidth > 0, newHeight > 0 else { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    // MARK: - Formatting

    /// Light normalization only: collapses pathological blank-line runs and
    /// trims leading/trailing whitespace. Preserves line breaks because UI
    /// layout often carries meaning the LLM can use.
    static func normalize(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let joined = lines.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Collapse 3+ consecutive newlines into 2 — Vision occasionally emits
        // runs of empty observations on whitespace regions.
        let collapsed = trimmed.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed
    }
}
