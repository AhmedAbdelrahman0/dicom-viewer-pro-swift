import Foundation
import CoreGraphics

/// Vision-language "describe what you see" suggestion. The user clicks
/// "Describe View" in the dictation panel, the panel hands the current
/// slice to the suggester, and a draft sentence comes back tagged
/// `Provenance.vlmSuggested`. The user accepts (→ `acceptedAISuggestion`)
/// or rejects.
///
/// In C3 we ship two implementations:
///   • `StubPixelToTextSuggester` — returns a placeholder describing
///     image dimensions. Lets the UI flow be tested without a model.
///   • `ClosurePixelToTextSuggester` — wraps an injected closure so a
///     future commit can plug in MedGemma vision (Apache-2.0, ~1.2-2 s
///     on M3) or RadFM running on the user's DGX Spark over SSH.
///
/// Why the stub ships in C3: we want users to see the AI button working
/// end-to-end (click → see a sentence appear in italic gray with VLM
/// badge → accept / reject) before we ask them to wait on a model
/// download. The stub is a one-liner, never wrong, never crashes.
public protocol PixelToTextSuggester: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isOnDevice: Bool { get }

    /// Generate a finding-style sentence describing the image.
    /// `context` carries optional study metadata (modality, body part)
    /// so future VLMs can prompt-engineer accordingly.
    func suggest(image: CGImage,
                 context: PixelToTextContext) async throws -> ReportSentence?
}

public struct PixelToTextContext: Sendable, Equatable {
    public var modality: String
    public var bodyPart: String
    public var seriesDescription: String
    public var sliceIndex: Int?

    public init(modality: String = "",
                bodyPart: String = "",
                seriesDescription: String = "",
                sliceIndex: Int? = nil) {
        self.modality = modality
        self.bodyPart = bodyPart
        self.seriesDescription = seriesDescription
        self.sliceIndex = sliceIndex
    }
}

public enum PixelToTextSuggesterError: Swift.Error, LocalizedError, Sendable {
    case modelUnavailable(String)
    case imageInvalid(String)
    case transportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m): return "Pixel-to-text model unavailable: \(m)"
        case .imageInvalid(let m):     return "Pixel-to-text image: \(m)"
        case .transportFailed(let m):  return "Pixel-to-text transport: \(m)"
        }
    }
}

// MARK: - Stub

/// Always-on placeholder suggester. Returns a sentence describing the
/// image's dimensions and modality so the UI flow is visible end-to-end.
/// **NOT** clinically meaningful — the displayName makes that clear.
public final class StubPixelToTextSuggester: PixelToTextSuggester, @unchecked Sendable {

    public let id: String = "stub-pixel-to-text"
    public let displayName: String = "Stub (no model — UI flow only)"
    public let isOnDevice: Bool = true

    public init() {}

    public func suggest(image: CGImage,
                        context: PixelToTextContext) async throws -> ReportSentence? {
        let w = image.width, h = image.height
        let modality = context.modality.isEmpty ? "image" : context.modality
        let where_ = context.bodyPart.isEmpty
            ? (context.seriesDescription.isEmpty
                ? "the displayed slice"
                : "the \(context.seriesDescription) series")
            : "the \(context.bodyPart)"
        let slice = context.sliceIndex.map { " (slice \($0))" } ?? ""
        let body = "[VLM placeholder] \(modality.uppercased()) of \(where_)\(slice) — \(w)×\(h) px. Wire MedGemma or RadFM in a future commit for a real description."
        return ReportSentence(
            text: body,
            provenance: .vlmSuggested
        )
    }
}

// MARK: - Closure-backed

/// Test seam + integration point for production VLMs. Mirrors the same
/// closure pattern as `ClosureImpressionDrafter`.
public final class ClosurePixelToTextSuggester: PixelToTextSuggester, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let isOnDevice: Bool
    private let closure: @Sendable (CGImage, PixelToTextContext) async throws -> ReportSentence?

    public init(id: String,
                displayName: String,
                isOnDevice: Bool,
                _ closure: @escaping @Sendable (CGImage, PixelToTextContext) async throws -> ReportSentence?) {
        self.id = id
        self.displayName = displayName
        self.isOnDevice = isOnDevice
        self.closure = closure
    }

    public func suggest(image: CGImage,
                        context: PixelToTextContext) async throws -> ReportSentence? {
        try await closure(image, context)
    }
}
