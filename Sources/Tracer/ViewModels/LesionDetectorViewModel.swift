import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// State + orchestration for the lesion detection workflow. Picks a
/// catalog entry, builds the concrete detector with the user's supplied
/// paths, runs it on the active volume, and publishes per-detection
/// records the panel renders.
///
/// Mirrors `PETACViewModel` and `ClassificationViewModel` so users with
/// either of those workflows learn this one in seconds.
@MainActor
public final class LesionDetectorViewModel: ObservableObject {

    // MARK: - Published configuration

    @Published public var selectedEntryID: String =
        LesionDetectorCatalog.all.first?.id ?? ""

    /// Subprocess wrapper. `/usr/bin/env` is the default — Tracer
    /// prepends `python3` automatically.
    @Published public var pythonExecutablePath: String = "/usr/bin/env"
    @Published public var scriptPath: String = ""
    @Published public var environment: String = ""
    @Published public var extraArgs: String = ""
    @Published public var timeoutSeconds: Double = 600
    @Published public var useAnatomicalChannel: Bool = false

    /// Confidence threshold applied AFTER the model returns. Detections
    /// with `detectionConfidence` below this are hidden in the panel +
    /// excluded from the chat-summary count. Doesn't affect the model
    /// itself — the wrapper script's threshold is its own concern.
    @Published public var minConfidence: Double = 0.0

    // MARK: - Published state

    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var log: String = ""
    @Published public private(set) var lastDetections: [LesionDetection] = []
    @Published public private(set) var lastSourceVolumeID: String?

    public init() {}

    public var selectedEntry: LesionDetectorCatalog.Entry? {
        LesionDetectorCatalog.byID(selectedEntryID)
    }

    public var entryReadinessMessage: String? {
        guard let entry = selectedEntry else { return "Pick a detector first." }
        switch entry.backend {
        case .subprocess:
            if scriptPath.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Point at the detector Python script (--input / stdout-JSON contract)."
            }
            return nil
        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            if !cfg.enabled { return "Enable DGX Spark in Settings → DGX Spark." }
            if !cfg.isConfigured { return "Set a host in Settings → DGX Spark." }
            if scriptPath.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Point at the detector script's path on the DGX."
            }
            return nil
        }
    }

    /// Detections after the user-side confidence filter. `lastDetections`
    /// holds the unfiltered model output; this is what the table renders.
    public var visibleDetections: [LesionDetection] {
        guard minConfidence > 0 else { return lastDetections }
        return lastDetections.filter { $0.detectionConfidence >= minConfidence }
    }

    // MARK: - Public API

    /// Run detection on `volume`. The optional `anatomical` is the
    /// resampled CT/MR for cross-modal detectors; ignored when the
    /// chosen entry doesn't want one.
    @discardableResult
    public func run(volume: ImageVolume,
                    anatomical: ImageVolume?) async -> [LesionDetection] {
        guard let entry = selectedEntry else {
            statusMessage = "Pick a detector first."
            return []
        }
        if let readiness = entryReadinessMessage {
            statusMessage = readiness
            return []
        }

        isRunning = true
        log = ""
        defer { isRunning = false }

        let detector: LesionDetector
        do {
            detector = try makeDetector(for: entry)
        } catch {
            statusMessage = "Could not build detector: \(error.localizedDescription)"
            return []
        }

        let anatomicalToPass: ImageVolume?
        if entry.requiresAnatomicalChannel {
            guard let anatomical else {
                statusMessage = "This detector needs a co-registered CT or MR channel."
                return []
            }
            anatomicalToPass = anatomical
        } else {
            anatomicalToPass = useAnatomicalChannel ? anatomical : nil
        }

        statusMessage = "Running \(entry.displayName)…"
        do {
            let detections = try await detector.detect(
                volume: volume,
                anatomical: anatomicalToPass,
                progress: { [weak self] line in
                    guard !line.isEmpty else { return }
                    Task { @MainActor in
                        self?.log.append(line)
                        self?.log.append("\n")
                    }
                }
            )
            lastDetections = detections
            lastSourceVolumeID = volume.seriesUID
            statusMessage = detections.isEmpty
                ? "✓ No detections returned by \(entry.displayName)."
                : "✓ \(detections.count) detection(s) from \(entry.displayName)."
            return detections
        } catch let error as DetectionError {
            statusMessage = error.errorDescription ?? "Detection failed"
            return []
        } catch {
            statusMessage = "Detection failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Clear the result list. Doesn't touch the model config.
    public func clearResults() {
        lastDetections = []
        lastSourceVolumeID = nil
        statusMessage = ""
        log = ""
    }

    /// Export the current detection set as a JSON file mirroring the
    /// wire-format schema. Useful for piping a Tracer-produced run into
    /// downstream tools or for archival.
    public func exportJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lastDetections)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Builder

    private func makeDetector(for entry: LesionDetectorCatalog.Entry) throws -> LesionDetector {
        switch entry.backend {
        case .subprocess:
            let script = scriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw DetectionError.modelUnavailable("Script path empty.")
            }
            let env = parseEnvironment(environment)
            let args = parseArgs(extraArgs)
            let spec = SubprocessLesionDetector.Spec(
                executablePath: (pythonExecutablePath as NSString).expandingTildeInPath,
                scriptPath: (script as NSString).expandingTildeInPath,
                arguments: args,
                environment: env,
                timeoutSeconds: timeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return SubprocessLesionDetector(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                provenance: entry.provenance,
                license: entry.license
            )

        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            guard cfg.isConfigured, cfg.enabled else {
                throw DetectionError.modelUnavailable("DGX Spark not configured / enabled.")
            }
            let script = scriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw DetectionError.modelUnavailable("Remote script path empty.")
            }
            let activation = environment
                .split(separator: "\n")
                .first { $0.hasPrefix("activate=") }
                .map { String($0.dropFirst("activate=".count)) } ?? ""
            let spec = RemoteLesionDetector.Spec(
                dgx: cfg,
                remoteScriptPath: script,
                activationCommand: activation,
                scriptArguments: parseArgs(extraArgs),
                timeoutSeconds: timeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return RemoteLesionDetector(
                id: entry.id,
                displayName: "\(entry.displayName) · DGX",
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                provenance: entry.provenance,
                license: entry.license
            )
        }
    }

    private func parseEnvironment(_ raw: String) -> [String: String] {
        raw.split(separator: "\n")
            .reduce(into: [:]) { acc, line in
                let pieces = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pieces.count == 2 { acc[pieces[0]] = pieces[1] }
            }
    }

    private func parseArgs(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    #if canImport(AppKit)
    public func pickScriptPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the detector Python script"
        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
        }
    }
    #endif
}
