import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// State + orchestration for the "produce AC PET from NAC PET" workflow.
///
/// Sits next to `ClassificationViewModel` and `NNUnetViewModel` — picks an
/// entry from `PETACCatalog`, builds the concrete corrector with the user's
/// supplied paths, runs it on the active PET volume, and hands the AC PET
/// back to `ViewerViewModel.installCorrectedPET(...)` so the user can flip
/// between NAC and AC instantly.
@MainActor
public final class PETACViewModel: ObservableObject {

    // MARK: - Published configuration

    @Published public var selectedEntryID: String = PETACCatalog.all.first?.id ?? ""

    /// Local path for `.subprocess` entries — the Python wrapper.
    @Published public var pythonExecutablePath: String = "/usr/bin/env"
    /// The .py the wrapper invokes.
    @Published public var scriptPath: String = ""
    /// `KEY=VAL` lines exported into the subprocess env.
    @Published public var environment: String = ""
    /// Extra args appended after the script path.
    @Published public var extraArgs: String = ""
    /// Per-call timeout. AC inference on Apple Silicon can take 30-60s for
    /// a 192³ volume; default keeps us off the floor for cold starts.
    @Published public var timeoutSeconds: Double = 600

    /// Optional anatomical channel (CT or MR). When the entry's
    /// `requiresAnatomicalChannel` is true, this MUST be populated by
    /// the panel before `run()` will execute.
    @Published public var useAnatomicalChannel: Bool = false

    // MARK: - Published state

    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var log: String = ""
    @Published public private(set) var lastResult: PETACResult?

    public init() {}

    public var selectedEntry: PETACCatalog.Entry? {
        PETACCatalog.byID(selectedEntryID)
    }

    public var entryReadinessMessage: String? {
        guard let entry = selectedEntry else { return "Pick an AC method first." }
        switch entry.backend {
        case .subprocess:
            if scriptPath.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Point at the AC Python script (`--input` / `--output` argv contract)."
            }
            return nil
        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            if !cfg.enabled { return "Enable DGX Spark in Settings → DGX Spark." }
            if !cfg.isConfigured { return "Set a host in Settings → DGX Spark." }
            if scriptPath.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Point at the AC script's path on the DGX."
            }
            return nil
        }
    }

    // MARK: - Public API

    /// Run AC on `nacPET`. The optional `anatomical` is the resampled CT or
    /// MR for MR-AC entries; ignored when the chosen entry doesn't want one.
    /// On success, the AC volume is also handed to `viewer.installCorrectedPET`
    /// so it shows up in the volume browser + can be fused.
    @discardableResult
    public func run(nacPET: ImageVolume,
                    anatomical: ImageVolume?,
                    viewer: ViewerViewModel) async -> PETACResult? {
        guard let entry = selectedEntry else {
            statusMessage = "Pick an AC method first."
            return nil
        }
        if let readiness = entryReadinessMessage {
            statusMessage = readiness
            return nil
        }

        isRunning = true
        log = ""
        defer { isRunning = false }

        let corrector: PETAttenuationCorrector
        do {
            corrector = try makeCorrector(for: entry)
        } catch {
            statusMessage = "Could not build corrector: \(error.localizedDescription)"
            return nil
        }

        let anatomicalToPass: ImageVolume?
        if entry.requiresAnatomicalChannel {
            guard let anatomical else {
                statusMessage = "This AC method needs a co-registered CT or MR channel."
                return nil
            }
            anatomicalToPass = anatomical
        } else {
            anatomicalToPass = useAnatomicalChannel ? anatomical : nil
        }

        statusMessage = "Running \(entry.displayName)…"
        do {
            let result = try await corrector.attenuationCorrect(
                nacPET: nacPET,
                anatomical: anatomicalToPass,
                progress: { [weak self] line in
                    guard !line.isEmpty else { return }
                    Task { @MainActor in
                        self?.log.append(line)
                        self?.log.append("\n")
                    }
                }
            )
            lastResult = result
            viewer.installCorrectedPET(result.acPET, replacingNAC: nacPET)
            let elapsed = String(format: "%.1f", result.durationSeconds)
            statusMessage = "✓ AC ready in \(elapsed)s — opened as \"\(result.acPET.seriesDescription)\""
            return result
        } catch let error as PETACError {
            statusMessage = error.errorDescription ?? "AC failed"
            return nil
        } catch {
            statusMessage = "AC failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Builder

    /// Maps a catalog `Entry` + the panel's user inputs to a concrete
    /// `PETAttenuationCorrector`. Mirrors the pattern in
    /// `ClassificationViewModel.makeClassifier(for:)` and
    /// `CohortClassifierFactory.make`.
    private func makeCorrector(for entry: PETACCatalog.Entry) throws -> PETAttenuationCorrector {
        switch entry.backend {
        case .subprocess:
            let script = scriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw PETACError.modelUnavailable("Script path empty.")
            }
            let env = parseEnvironment(environment)
            let args = parseArgs(extraArgs)
            let spec = SubprocessPETACCorrector.Spec(
                executablePath: (pythonExecutablePath as NSString).expandingTildeInPath,
                scriptPath: (script as NSString).expandingTildeInPath,
                arguments: args,
                environment: env,
                timeoutSeconds: timeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return SubprocessPETACCorrector(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                provenance: entry.provenance,
                license: entry.license
            )

        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            guard cfg.isConfigured, cfg.enabled else {
                throw PETACError.modelUnavailable("DGX Spark not configured / enabled.")
            }
            let script = scriptPath.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else {
                throw PETACError.modelUnavailable("Remote script path empty.")
            }
            // Honour the `activate=…` convention from `RemoteLesionClassifier`
            // — the first env line of that form becomes the activation
            // command. Other env lines are exported by the executor.
            let activation = environment
                .split(separator: "\n")
                .first { $0.hasPrefix("activate=") }
                .map { String($0.dropFirst("activate=".count)) } ?? ""
            let spec = RemotePETACCorrector.Spec(
                dgx: cfg,
                remoteScriptPath: script,
                activationCommand: activation,
                scriptArguments: parseArgs(extraArgs),
                timeoutSeconds: timeoutSeconds,
                requiresAnatomicalChannel: entry.requiresAnatomicalChannel
            )
            return RemotePETACCorrector(
                id: entry.id,
                displayName: "\(entry.displayName) · DGX",
                spec: spec,
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
        panel.message = "Pick the AC Python script"
        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
        }
    }
    #endif
}
