import Foundation

@MainActor
public final class AutoPETVExperimentViewModel: ObservableObject {
    @Published public var experiment: AutoPETVExperimentConfig
    @Published public private(set) var drafts: [AutoPETVManifestBuilder.DraftCase] = []
    @Published public private(set) var bundle = AutoPETVExperimentBundle()
    @Published public private(set) var lastPackage: AutoPETVDGXPipeline.Package?
    @Published public private(set) var lastRun: AutoPETVExperimentRunRecord?
    @Published public private(set) var isRunning = false
    @Published public var statusMessage = "Refresh from the active PET/CT session."

    private let store: AutoPETVExperimentStore

    public init(store: AutoPETVExperimentStore = AutoPETVExperimentStore()) {
        self.store = store
        self.experiment = AutoPETVExperimentConfig(
            name: "AutoPET V \(Self.dateStamp())",
            remoteExperimentRoot: DGXSparkConfig.load().remoteWorkdir + "/autopetv"
        )
        reloadStore()
    }

    public var selectedDrafts: [AutoPETVManifestBuilder.DraftCase] {
        drafts.filter(\.include)
    }

    public var selectedCaseCount: Int {
        selectedDrafts.count
    }

    public var selectedTrainingCount: Int {
        selectedDrafts.filter { $0.split == .train }.count
    }

    public var selectedValidationCount: Int {
        selectedDrafts.filter { $0.split == .validation }.count
    }

    public func reloadStore() {
        bundle = (try? store.loadBundle()) ?? AutoPETVExperimentBundle()
    }

    public func refresh(from viewer: ViewerViewModel) {
        drafts = AutoPETVManifestBuilder.draftCases(
            volumes: viewer.activeSessionVolumes,
            labelMaps: viewer.labeling.labelMaps
        )
        if drafts.isEmpty {
            statusMessage = "No PET/CT pairs found in the active session."
        } else {
            statusMessage = "Found \(drafts.count) PET/CT case\(drafts.count == 1 ? "" : "s")."
        }
    }

    public func setIncluded(_ draftID: String, include: Bool) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var copy = drafts
        copy[index].include = include
        drafts = copy
    }

    public func setSplit(_ draftID: String, split: AutoPETVCaseManifestEntry.Split) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var copy = drafts
        copy[index].split = split
        drafts = copy
    }

    public func setTracer(_ draftID: String, tracer: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var copy = drafts
        copy[index].tracer = tracer
        drafts = copy
    }

    public func setCenter(_ draftID: String, center: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var copy = drafts
        copy[index].center = center
        drafts = copy
    }

    public func buildPackage(from viewer: ViewerViewModel) async {
        await runPackageOperation(kind: .packageOnly, viewer: viewer)
    }

    public func launchTraining(from viewer: ViewerViewModel) async {
        await runPackageOperation(kind: .training, viewer: viewer)
    }

    public func launchValidation(from viewer: ViewerViewModel) async {
        await runPackageOperation(kind: .validation, viewer: viewer)
    }

    private func runPackageOperation(kind: AutoPETVExperimentRunRecord.Kind,
                                     viewer: ViewerViewModel) async {
        isRunning = true
        defer { isRunning = false }

        do {
            let sources = try AutoPETVManifestBuilder.makePackageSources(
                drafts: drafts,
                volumes: viewer.activeSessionVolumes,
                labelMaps: viewer.labeling.labelMaps
            )
            var exp = experiment
            exp.updatedAt = Date()
            let packageRoot = store.rootURL.appendingPathComponent("Packages", isDirectory: true)

            switch kind {
            case .packageOnly:
                let package = try await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                    try AutoPETVDGXPipeline.buildPackage(experiment: exp,
                                                         caseSources: sources,
                                                         rootURL: packageRoot)
                }.value
                let run = AutoPETVExperimentRunRecord(
                    experimentID: exp.id,
                    kind: .packageOnly,
                    status: .succeeded,
                    finishedAt: Date(),
                    localPackagePath: package.localURL.path,
                    remotePackagePath: package.remotePath,
                    command: package.trainCommand,
                    metadata: ["caseCount": "\(sources.count)"]
                )
                try store.upsertExperiment(exp)
                try store.upsertRun(run)
                lastPackage = package
                lastRun = run
                experiment = exp
                reloadStore()
                statusMessage = "Built AutoPET V package with \(sources.count) case\(sources.count == 1 ? "" : "s")."

            case .training:
                let cfg = try requireDGXConfig()
                let store = self.store
                statusMessage = "Uploading AutoPET V package and launching DGX training..."
                let run = try await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                    try AutoPETVDGXPipeline.launchTrainingOnDGX(
                        experiment: exp,
                        caseSources: sources,
                        dgx: cfg,
                        packageRoot: packageRoot,
                        store: store,
                        logSink: { _ in }
                    )
                }.value
                lastRun = run
                experiment = exp
                reloadStore()
                statusMessage = run.status == .succeeded
                    ? "DGX training finished."
                    : "DGX training ended with \(run.status.rawValue)."

            case .validation:
                let cfg = try requireDGXConfig()
                let store = self.store
                statusMessage = "Uploading AutoPET V package and launching DGX validation..."
                let run = try await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                    try AutoPETVDGXPipeline.launchValidationOnDGX(
                        experiment: exp,
                        caseSources: sources,
                        dgx: cfg,
                        packageRoot: packageRoot,
                        store: store,
                        logSink: { _ in }
                    )
                }.value
                lastRun = run
                experiment = exp
                reloadStore()
                statusMessage = "DGX validation finished with \(run.validation.count) case report\(run.validation.count == 1 ? "" : "s")."
            }
        } catch {
            statusMessage = "AutoPET V: \(error.localizedDescription)"
        }
    }

    private func requireDGXConfig() throws -> DGXSparkConfig {
        let cfg = DGXSparkConfig.load()
        if let message = cfg.readinessMessage {
            throw NSError(domain: "AutoPETVExperiment",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return cfg
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date())
    }
}
