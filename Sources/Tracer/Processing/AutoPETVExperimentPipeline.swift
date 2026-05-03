import Foundation

public struct AutoPETVExperimentConfig: Codable, Identifiable, Hashable, Sendable {
    public static let defaultSparkDatasetRoot = "/home/ahmed/datasets/autopet5/current"
    public static let defaultSparkModelEnvironmentFile = "/home/ahmed/datasets/autopet5/model_access.env"
    public static let defaultSparkContainerDatasetMount = "/data/autopet5"

    public enum PromptEncoding: String, Codable, CaseIterable, Sendable {
        case edt
        case binary

        public func challengeEncoding(distanceMM: Double) -> AutoPETVChallenge.PromptEncoding {
            switch self {
            case .edt:
                return .distanceTransform(maxDistanceMM: distanceMM)
            case .binary:
                return .binary
            }
        }
    }

    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var datasetID: String
    public var promptEncoding: PromptEncoding
    public var promptDistanceMM: Double
    public var maxInteractionSteps: Int
    public var maxForegroundScribblesPerStep: Int
    public var maxBackgroundScribblesPerStep: Int
    public var nnunetConfiguration: String
    public var folds: [String]
    public var baseModelID: String
    public var remoteExperimentRoot: String
    public var useSparkDatasetRoot: Bool
    public var sparkDatasetRoot: String
    public var sparkModelEnvironmentFile: String
    public var sparkContainerDatasetMount: String
    public var sparkCaseLimit: Int
    public var sparkValidationFraction: Double
    public var notes: String

    public init(id: UUID = UUID(),
                name: String = "AutoPET V experiment",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                datasetID: String = "Dataset998_AutoPETV",
                promptEncoding: PromptEncoding = .edt,
                promptDistanceMM: Double = 40,
                maxInteractionSteps: Int = 4,
                maxForegroundScribblesPerStep: Int = 3,
                maxBackgroundScribblesPerStep: Int = 3,
                nnunetConfiguration: String = "3d_fullres",
                folds: [String] = ["0"],
                baseModelID: String = "AutoPET-V-2026",
                remoteExperimentRoot: String = "~/tracer-autopetv-experiments",
                useSparkDatasetRoot: Bool = false,
                sparkDatasetRoot: String = AutoPETVExperimentConfig.defaultSparkDatasetRoot,
                sparkModelEnvironmentFile: String = AutoPETVExperimentConfig.defaultSparkModelEnvironmentFile,
                sparkContainerDatasetMount: String = AutoPETVExperimentConfig.defaultSparkContainerDatasetMount,
                sparkCaseLimit: Int = 0,
                sparkValidationFraction: Double = 0.2,
                notes: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.datasetID = datasetID
        self.promptEncoding = promptEncoding
        self.promptDistanceMM = promptDistanceMM
        self.maxInteractionSteps = maxInteractionSteps
        self.maxForegroundScribblesPerStep = maxForegroundScribblesPerStep
        self.maxBackgroundScribblesPerStep = maxBackgroundScribblesPerStep
        self.nnunetConfiguration = nnunetConfiguration
        self.folds = folds
        self.baseModelID = baseModelID
        self.remoteExperimentRoot = remoteExperimentRoot
        self.useSparkDatasetRoot = useSparkDatasetRoot
        self.sparkDatasetRoot = sparkDatasetRoot
        self.sparkModelEnvironmentFile = sparkModelEnvironmentFile
        self.sparkContainerDatasetMount = sparkContainerDatasetMount
        self.sparkCaseLimit = sparkCaseLimit
        self.sparkValidationFraction = sparkValidationFraction
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, datasetID, promptEncoding, promptDistanceMM
        case maxInteractionSteps, maxForegroundScribblesPerStep, maxBackgroundScribblesPerStep
        case nnunetConfiguration, folds, baseModelID, remoteExperimentRoot
        case useSparkDatasetRoot, sparkDatasetRoot, sparkModelEnvironmentFile
        case sparkContainerDatasetMount, sparkCaseLimit, sparkValidationFraction, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "AutoPET V experiment"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        datasetID = try c.decodeIfPresent(String.self, forKey: .datasetID) ?? "Dataset998_AutoPETV"
        promptEncoding = try c.decodeIfPresent(PromptEncoding.self, forKey: .promptEncoding) ?? .edt
        promptDistanceMM = try c.decodeIfPresent(Double.self, forKey: .promptDistanceMM) ?? 40
        maxInteractionSteps = try c.decodeIfPresent(Int.self, forKey: .maxInteractionSteps) ?? 4
        maxForegroundScribblesPerStep = try c.decodeIfPresent(Int.self, forKey: .maxForegroundScribblesPerStep) ?? 3
        maxBackgroundScribblesPerStep = try c.decodeIfPresent(Int.self, forKey: .maxBackgroundScribblesPerStep) ?? 3
        nnunetConfiguration = try c.decodeIfPresent(String.self, forKey: .nnunetConfiguration) ?? "3d_fullres"
        folds = try c.decodeIfPresent([String].self, forKey: .folds) ?? ["0"]
        baseModelID = try c.decodeIfPresent(String.self, forKey: .baseModelID) ?? "AutoPET-V-2026"
        remoteExperimentRoot = try c.decodeIfPresent(String.self, forKey: .remoteExperimentRoot) ?? "~/tracer-autopetv-experiments"
        useSparkDatasetRoot = try c.decodeIfPresent(Bool.self, forKey: .useSparkDatasetRoot) ?? false
        sparkDatasetRoot = try c.decodeIfPresent(String.self, forKey: .sparkDatasetRoot) ?? Self.defaultSparkDatasetRoot
        sparkModelEnvironmentFile = try c.decodeIfPresent(String.self, forKey: .sparkModelEnvironmentFile) ?? Self.defaultSparkModelEnvironmentFile
        sparkContainerDatasetMount = try c.decodeIfPresent(String.self, forKey: .sparkContainerDatasetMount) ?? Self.defaultSparkContainerDatasetMount
        sparkCaseLimit = try c.decodeIfPresent(Int.self, forKey: .sparkCaseLimit) ?? 0
        sparkValidationFraction = try c.decodeIfPresent(Double.self, forKey: .sparkValidationFraction) ?? 0.2
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(datasetID, forKey: .datasetID)
        try c.encode(promptEncoding, forKey: .promptEncoding)
        try c.encode(promptDistanceMM, forKey: .promptDistanceMM)
        try c.encode(maxInteractionSteps, forKey: .maxInteractionSteps)
        try c.encode(maxForegroundScribblesPerStep, forKey: .maxForegroundScribblesPerStep)
        try c.encode(maxBackgroundScribblesPerStep, forKey: .maxBackgroundScribblesPerStep)
        try c.encode(nnunetConfiguration, forKey: .nnunetConfiguration)
        try c.encode(folds, forKey: .folds)
        try c.encode(baseModelID, forKey: .baseModelID)
        try c.encode(remoteExperimentRoot, forKey: .remoteExperimentRoot)
        try c.encode(useSparkDatasetRoot, forKey: .useSparkDatasetRoot)
        try c.encode(sparkDatasetRoot, forKey: .sparkDatasetRoot)
        try c.encode(sparkModelEnvironmentFile, forKey: .sparkModelEnvironmentFile)
        try c.encode(sparkContainerDatasetMount, forKey: .sparkContainerDatasetMount)
        try c.encode(sparkCaseLimit, forKey: .sparkCaseLimit)
        try c.encode(sparkValidationFraction, forKey: .sparkValidationFraction)
        try c.encode(notes, forKey: .notes)
    }
}

public struct AutoPETVCaseManifestEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Split: String, Codable, CaseIterable, Sendable {
        case train
        case validation
        case test
    }

    public var id: String { caseID }
    public var caseID: String
    public var split: Split
    public var ctPath: String
    public var petPath: String
    public var labelPath: String?
    public var tracer: String
    public var center: String
    public var notes: String

    public init(caseID: String,
                split: Split,
                ctPath: String,
                petPath: String,
                labelPath: String? = nil,
                tracer: String = "",
                center: String = "",
                notes: String = "") {
        self.caseID = caseID
        self.split = split
        self.ctPath = ctPath
        self.petPath = petPath
        self.labelPath = labelPath
        self.tracer = tracer
        self.center = center
        self.notes = notes
    }
}

public struct AutoPETVCasePackageSource: Identifiable, Sendable {
    public var id: String { caseID }
    public var caseID: String
    public var split: AutoPETVCaseManifestEntry.Split
    public var ctVolume: ImageVolume
    public var petVolume: ImageVolume
    public var labelMap: LabelMap?
    public var labelParentVolume: ImageVolume?
    public var tracer: String
    public var center: String
    public var notes: String

    public init(caseID: String,
                split: AutoPETVCaseManifestEntry.Split,
                ctVolume: ImageVolume,
                petVolume: ImageVolume,
                labelMap: LabelMap? = nil,
                labelParentVolume: ImageVolume? = nil,
                tracer: String = "",
                center: String = "",
                notes: String = "") {
        self.caseID = caseID
        self.split = split
        self.ctVolume = ctVolume
        self.petVolume = petVolume
        self.labelMap = labelMap
        self.labelParentVolume = labelParentVolume
        self.tracer = tracer
        self.center = center
        self.notes = notes
    }
}

public struct AutoPETVTrainingManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var generator: String
    public var experiment: AutoPETVExperimentConfig
    public var cases: [AutoPETVCaseManifestEntry]

    public init(version: Int = 1,
                generator: String = "Tracer AutoPET V",
                experiment: AutoPETVExperimentConfig,
                cases: [AutoPETVCaseManifestEntry]) {
        self.version = version
        self.generator = generator
        self.experiment = experiment
        self.cases = cases
    }

    public var trainingCases: [AutoPETVCaseManifestEntry] {
        cases.filter { $0.split == .train }
    }

    public var validationCases: [AutoPETVCaseManifestEntry] {
        cases.filter { $0.split == .validation }
    }
}

public struct AutoPETVStepMetricRecord: Codable, Equatable, Sendable {
    public var stepIndex: Int
    public var dice: Double?
    public var dmm: Double?
    public var truePositiveLesions: Int
    public var falsePositiveLesions: Int
    public var falseNegativeLesions: Int
    public var falsePositiveVolumeML: Double
    public var falseNegativeVolumeML: Double
    public var predictionLesions: Int
    public var referenceLesions: Int

    public init(_ metrics: AutoPETVWorkbench.StepMetrics) {
        self.stepIndex = metrics.stepIndex
        self.dice = metrics.dice
        self.dmm = metrics.dmm
        self.truePositiveLesions = metrics.truePositiveLesions
        self.falsePositiveLesions = metrics.falsePositiveLesions
        self.falseNegativeLesions = metrics.falseNegativeLesions
        self.falsePositiveVolumeML = metrics.falsePositiveVolumeML
        self.falseNegativeVolumeML = metrics.falseNegativeVolumeML
        self.predictionLesions = metrics.predictionLesions
        self.referenceLesions = metrics.referenceLesions
    }
}

public struct AutoPETVCaseValidationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { caseID }
    public var caseID: String
    public var steps: [AutoPETVStepMetricRecord]
    public var aucDice: Double?
    public var aucDMM: Double?
    public var failureTags: [String]
    public var assistantBrief: String

    public init(caseID: String,
                steps: [AutoPETVStepMetricRecord],
                aucDice: Double?,
                aucDMM: Double?,
                failureTags: [String],
                assistantBrief: String) {
        self.caseID = caseID
        self.steps = steps
        self.aucDice = aucDice
        self.aucDMM = aucDMM
        self.failureTags = failureTags
        self.assistantBrief = assistantBrief
    }

    public init(_ report: AutoPETVWorkbench.InteractionReport) {
        self.init(
            caseID: report.caseID,
            steps: report.steps.map(AutoPETVStepMetricRecord.init),
            aucDice: report.aucDice,
            aucDMM: report.aucDMM,
            failureTags: report.failureTags.map(\.rawValue),
            assistantBrief: report.assistantBrief
        )
    }
}

public struct AutoPETVExperimentRunRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case prepare
        case training
        case validation
        case packageOnly
    }

    public enum Status: String, Codable, CaseIterable, Sendable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
    }

    public var id: UUID
    public var experimentID: UUID
    public var kind: Kind
    public var status: Status
    public var startedAt: Date
    public var finishedAt: Date?
    public var localPackagePath: String
    public var remotePackagePath: String
    public var command: String
    public var stdoutTail: String
    public var stderrTail: String
    public var validation: [AutoPETVCaseValidationRecord]
    public var metadata: [String: String]

    public init(id: UUID = UUID(),
                experimentID: UUID,
                kind: Kind,
                status: Status = .queued,
                startedAt: Date = Date(),
                finishedAt: Date? = nil,
                localPackagePath: String = "",
                remotePackagePath: String = "",
                command: String = "",
                stdoutTail: String = "",
                stderrTail: String = "",
                validation: [AutoPETVCaseValidationRecord] = [],
                metadata: [String: String] = [:]) {
        self.id = id
        self.experimentID = experimentID
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.localPackagePath = localPackagePath
        self.remotePackagePath = remotePackagePath
        self.command = command
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.validation = validation
        self.metadata = metadata
    }
}

public struct AutoPETVExperimentBundle: Codable, Equatable, Sendable {
    public var version: Int
    public var generator: String
    public var experiments: [AutoPETVExperimentConfig]
    public var runs: [AutoPETVExperimentRunRecord]
    public var modifiedAt: Date

    public init(version: Int = 1,
                generator: String = "Tracer",
                experiments: [AutoPETVExperimentConfig] = [],
                runs: [AutoPETVExperimentRunRecord] = [],
                modifiedAt: Date = Date()) {
        self.version = version
        self.generator = generator
        self.experiments = experiments
        self.runs = runs
        self.modifiedAt = modifiedAt
    }
}

public struct AutoPETVExperimentStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = AutoPETVExperimentStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("AutoPETVExperiments", isDirectory: true)
    }

    public var bundleURL: URL {
        rootURL.appendingPathComponent("autopetv-experiments.json")
    }

    public func loadBundle() throws -> AutoPETVExperimentBundle {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return AutoPETVExperimentBundle()
        }
        let data = try Data(contentsOf: bundleURL)
        return try JSONDecoder().decode(AutoPETVExperimentBundle.self, from: data)
    }

    public func saveBundle(_ bundle: AutoPETVExperimentBundle) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var copy = bundle
        copy.modifiedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(copy).write(to: bundleURL, options: [.atomic])
    }

    public func upsertExperiment(_ experiment: AutoPETVExperimentConfig) throws {
        var bundle = try loadBundle()
        var copy = experiment
        copy.updatedAt = Date()
        if let index = bundle.experiments.firstIndex(where: { $0.id == experiment.id }) {
            bundle.experiments[index] = copy
        } else {
            bundle.experiments.append(copy)
        }
        try saveBundle(bundle)
    }

    public func upsertRun(_ run: AutoPETVExperimentRunRecord) throws {
        var bundle = try loadBundle()
        if let index = bundle.runs.firstIndex(where: { $0.id == run.id }) {
            bundle.runs[index] = run
        } else {
            bundle.runs.append(run)
        }
        try saveBundle(bundle)
    }
}

public enum AutoPETVDGXPipeline {
    private static let validationResultsFilename = "validation_results.json"

    public struct Package: Equatable, Sendable {
        public let localURL: URL
        public let remotePath: String
        public let manifestURL: URL
        public let prepareCommand: String
        public let trainCommand: String
        public let validateCommand: String
    }

    public static func buildPackage(experiment: AutoPETVExperimentConfig,
                                    cases: [AutoPETVCaseManifestEntry],
                                    rootURL: URL) throws -> Package {
        let safeName = safeComponent(experiment.name)
        let localURL = rootURL.appendingPathComponent("\(safeName)-\(experiment.id.uuidString)",
                                                      isDirectory: true)
        let scriptsURL = localURL.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)

        let manifest = AutoPETVTrainingManifest(experiment: experiment, cases: cases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = localURL.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])

        try write(trainingScript, to: scriptsURL.appendingPathComponent("train_autopetv.py"))
        try write(validationScript, to: scriptsURL.appendingPathComponent("validate_autopetv.py"))
        try write(commonScript, to: scriptsURL.appendingPathComponent("autopetv_common.py"))
        try write(requirements, to: localURL.appendingPathComponent("requirements.txt"))
        try write(readme(experiment: experiment), to: localURL.appendingPathComponent("README.md"))

        let remotePath = "\(experiment.remoteExperimentRoot)/\(safeName)-\(experiment.id.uuidString)"
        return Package(
            localURL: localURL,
            remotePath: remotePath,
            manifestURL: manifestURL,
            prepareCommand: remoteCommand(remotePath: remotePath,
                                          scriptName: "train_autopetv.py",
                                          experiment: experiment,
                                          extraArguments: ["--prepare-only"]),
            trainCommand: remoteCommand(remotePath: remotePath,
                                        scriptName: "train_autopetv.py",
                                        experiment: experiment),
            validateCommand: remoteCommand(remotePath: remotePath,
                                           scriptName: "validate_autopetv.py",
                                           experiment: experiment)
        )
    }

    public static func buildPackage(experiment: AutoPETVExperimentConfig,
                                    caseSources: [AutoPETVCasePackageSource],
                                    rootURL: URL) throws -> Package {
        let cases = caseSources.map { source -> AutoPETVCaseManifestEntry in
            let folder = safeComponent(source.caseID)
            return AutoPETVCaseManifestEntry(
                caseID: safeCaseID(source.caseID),
                split: source.split,
                ctPath: "data/\(folder)/ct.mha",
                petPath: "data/\(folder)/pet.mha",
                labelPath: source.labelMap == nil ? nil : "data/\(folder)/label.mha",
                tracer: source.tracer,
                center: source.center,
                notes: source.notes
            )
        }
        let package = try buildPackage(experiment: experiment, cases: cases, rootURL: rootURL)
        try writeCaseSources(caseSources, into: package.localURL)
        return package
    }

    @discardableResult
    public static func launchPrepareOnDGX(experiment: AutoPETVExperimentConfig,
                                          cases: [AutoPETVCaseManifestEntry],
                                          dgx: DGXSparkConfig,
                                          packageRoot: URL = FileManager.default.temporaryDirectory,
                                          store: AutoPETVExperimentStore? = nil,
                                          timeoutSeconds: TimeInterval? = nil,
                                          logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, cases: cases, rootURL: packageRoot)
        return try launchPrepareOnDGX(experiment: experiment,
                                      package: package,
                                      caseCount: cases.count,
                                      dgx: dgx,
                                      store: store,
                                      timeoutSeconds: timeoutSeconds,
                                      logSink: logSink)
    }

    @discardableResult
    public static func launchPrepareOnDGX(experiment: AutoPETVExperimentConfig,
                                          caseSources: [AutoPETVCasePackageSource],
                                          dgx: DGXSparkConfig,
                                          packageRoot: URL = FileManager.default.temporaryDirectory,
                                          store: AutoPETVExperimentStore? = nil,
                                          timeoutSeconds: TimeInterval? = nil,
                                          logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, caseSources: caseSources, rootURL: packageRoot)
        return try launchPrepareOnDGX(experiment: experiment,
                                      package: package,
                                      caseCount: caseSources.count,
                                      dgx: dgx,
                                      store: store,
                                      timeoutSeconds: timeoutSeconds,
                                      logSink: logSink)
    }

    @discardableResult
    public static func launchTrainingOnDGX(experiment: AutoPETVExperimentConfig,
                                           cases: [AutoPETVCaseManifestEntry],
                                           dgx: DGXSparkConfig,
                                           packageRoot: URL = FileManager.default.temporaryDirectory,
                                           store: AutoPETVExperimentStore? = nil,
                                           timeoutSeconds: TimeInterval? = nil,
                                           logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, cases: cases, rootURL: packageRoot)
        let executor = RemoteExecutor(config: dgx)
        var run = AutoPETVExperimentRunRecord(
            experimentID: experiment.id,
            kind: .training,
            status: .running,
            localPackagePath: package.localURL.path,
            remotePackagePath: package.remotePath,
            command: package.trainCommand,
            metadata: [
                "datasetID": experiment.datasetID,
                "promptEncoding": experiment.promptEncoding.rawValue,
                "promptDistanceMM": String(experiment.promptDistanceMM),
                "caseCount": String(cases.count)
            ]
        )
        try store?.upsertExperiment(experiment)
        try store?.upsertRun(run)

        do {
            try executor.uploadDirectory(package.localURL, toRemote: package.remotePath)
            let result = try executor.run(package.trainCommand,
                                          timeoutSeconds: timeoutSeconds,
                                          logSink: logSink)
            run.finishedAt = Date()
            run.stdoutTail = tail(String(data: result.stdout, encoding: .utf8) ?? "")
            run.stderrTail = tail(result.stderr)
            run.status = result.exitCode == 0 ? .succeeded : .failed
            if result.exitCode != 0 {
                try store?.upsertRun(run)
                throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        } catch {
            run.finishedAt = Date()
            run.status = .failed
            run.stderrTail = tail(error.localizedDescription)
            try? store?.upsertRun(run)
            throw error
        }

        try store?.upsertRun(run)
        return run
    }

    @discardableResult
    public static func launchTrainingOnDGX(experiment: AutoPETVExperimentConfig,
                                           caseSources: [AutoPETVCasePackageSource],
                                           dgx: DGXSparkConfig,
                                           packageRoot: URL = FileManager.default.temporaryDirectory,
                                           store: AutoPETVExperimentStore? = nil,
                                           timeoutSeconds: TimeInterval? = nil,
                                           logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, caseSources: caseSources, rootURL: packageRoot)
        return try launchTrainingOnDGX(experiment: experiment,
                                       package: package,
                                       caseCount: caseSources.count,
                                       dgx: dgx,
                                       store: store,
                                       timeoutSeconds: timeoutSeconds,
                                       logSink: logSink)
    }

    @discardableResult
    public static func launchValidationOnDGX(experiment: AutoPETVExperimentConfig,
                                             cases: [AutoPETVCaseManifestEntry],
                                             dgx: DGXSparkConfig,
                                             packageRoot: URL = FileManager.default.temporaryDirectory,
                                             store: AutoPETVExperimentStore? = nil,
                                             timeoutSeconds: TimeInterval? = nil,
                                             logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, cases: cases, rootURL: packageRoot)
        let executor = RemoteExecutor(config: dgx)
        var run = AutoPETVExperimentRunRecord(
            experimentID: experiment.id,
            kind: .validation,
            status: .running,
            localPackagePath: package.localURL.path,
            remotePackagePath: package.remotePath,
            command: package.validateCommand,
            metadata: [
                "datasetID": experiment.datasetID,
                "promptEncoding": experiment.promptEncoding.rawValue,
                "promptDistanceMM": String(experiment.promptDistanceMM),
                "caseCount": String(cases.count)
            ]
        )
        try store?.upsertExperiment(experiment)
        try store?.upsertRun(run)

        do {
            try executor.uploadDirectory(package.localURL, toRemote: package.remotePath)
            let result = try executor.run(package.validateCommand,
                                          timeoutSeconds: timeoutSeconds,
                                          logSink: logSink)
            run.finishedAt = Date()
            run.stdoutTail = tail(String(data: result.stdout, encoding: .utf8) ?? "")
            run.stderrTail = tail(result.stderr)
            run.status = result.exitCode == 0 ? .succeeded : .failed
            if result.exitCode != 0 {
                try store?.upsertRun(run)
                throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }

            let localResults = package.localURL
                .appendingPathComponent("work", isDirectory: true)
                .appendingPathComponent(validationResultsFilename)
            try executor.downloadFile("\(package.remotePath)/work/\(validationResultsFilename)",
                                      toLocal: localResults)
            run.validation = try loadValidationRecords(from: localResults)
        } catch {
            run.finishedAt = Date()
            run.status = .failed
            run.stderrTail = tail(error.localizedDescription)
            try? store?.upsertRun(run)
            throw error
        }

        try store?.upsertRun(run)
        return run
    }

    @discardableResult
    public static func launchValidationOnDGX(experiment: AutoPETVExperimentConfig,
                                             caseSources: [AutoPETVCasePackageSource],
                                             dgx: DGXSparkConfig,
                                             packageRoot: URL = FileManager.default.temporaryDirectory,
                                             store: AutoPETVExperimentStore? = nil,
                                             timeoutSeconds: TimeInterval? = nil,
                                             logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> AutoPETVExperimentRunRecord {
        let package = try buildPackage(experiment: experiment, caseSources: caseSources, rootURL: packageRoot)
        return try launchValidationOnDGX(experiment: experiment,
                                         package: package,
                                         caseCount: caseSources.count,
                                         dgx: dgx,
                                         store: store,
                                         timeoutSeconds: timeoutSeconds,
                                         logSink: logSink)
    }

    public static func loadValidationRecords(from url: URL) throws -> [AutoPETVCaseValidationRecord] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ValidationEnvelope.self, from: data) {
            return envelope.validation
        }
        return try decoder.decode([AutoPETVCaseValidationRecord].self, from: data)
    }

    private static func remoteCommand(remotePath: String,
                                      scriptName: String,
                                      experiment: AutoPETVExperimentConfig,
                                      extraArguments: [String] = []) -> String {
        let quotedPath = RemoteExecutor.shellPath(remotePath)
        let sourceEnv = experiment.sparkModelEnvironmentFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let envPrefix = sourceEnv.isEmpty
            ? ""
            : "if [ -f \(RemoteExecutor.shellPath(sourceEnv)) ]; then . \(RemoteExecutor.shellPath(sourceEnv)); fi; "
        let arguments = extraArguments.joined(separator: " ")
        let suffix = arguments.isEmpty ? "" : " \(arguments)"
        return "\(envPrefix)cd \(quotedPath) && python3 scripts/\(scriptName) --manifest manifest.json --workdir work\(suffix)"
    }

    private static func launchPrepareOnDGX(experiment: AutoPETVExperimentConfig,
                                           package: Package,
                                           caseCount: Int,
                                           dgx: DGXSparkConfig,
                                           store: AutoPETVExperimentStore?,
                                           timeoutSeconds: TimeInterval?,
                                           logSink: @escaping @Sendable (String) -> Void) throws -> AutoPETVExperimentRunRecord {
        let executor = RemoteExecutor(config: dgx)
        var run = AutoPETVExperimentRunRecord(
            experimentID: experiment.id,
            kind: .prepare,
            status: .running,
            localPackagePath: package.localURL.path,
            remotePackagePath: package.remotePath,
            command: package.prepareCommand,
            metadata: runMetadata(experiment: experiment, caseCount: caseCount)
        )
        try store?.upsertExperiment(experiment)
        try store?.upsertRun(run)

        do {
            try executor.uploadDirectory(package.localURL, toRemote: package.remotePath)
            let result = try executor.run(package.prepareCommand,
                                          timeoutSeconds: timeoutSeconds,
                                          logSink: logSink)
            run.finishedAt = Date()
            run.stdoutTail = tail(String(data: result.stdout, encoding: .utf8) ?? "")
            run.stderrTail = tail(result.stderr)
            run.status = result.exitCode == 0 ? .succeeded : .failed
            if result.exitCode != 0 {
                try store?.upsertRun(run)
                throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        } catch {
            run.finishedAt = Date()
            run.status = .failed
            run.stderrTail = tail(error.localizedDescription)
            try? store?.upsertRun(run)
            throw error
        }

        try store?.upsertRun(run)
        return run
    }

    private static func launchTrainingOnDGX(experiment: AutoPETVExperimentConfig,
                                            package: Package,
                                            caseCount: Int,
                                            dgx: DGXSparkConfig,
                                            store: AutoPETVExperimentStore?,
                                            timeoutSeconds: TimeInterval?,
                                            logSink: @escaping @Sendable (String) -> Void) throws -> AutoPETVExperimentRunRecord {
        let executor = RemoteExecutor(config: dgx)
        var run = AutoPETVExperimentRunRecord(
            experimentID: experiment.id,
            kind: .training,
            status: .running,
            localPackagePath: package.localURL.path,
            remotePackagePath: package.remotePath,
            command: package.trainCommand,
            metadata: runMetadata(experiment: experiment, caseCount: caseCount)
        )
        try store?.upsertExperiment(experiment)
        try store?.upsertRun(run)

        do {
            try executor.uploadDirectory(package.localURL, toRemote: package.remotePath)
            let result = try executor.run(package.trainCommand,
                                          timeoutSeconds: timeoutSeconds,
                                          logSink: logSink)
            run.finishedAt = Date()
            run.stdoutTail = tail(String(data: result.stdout, encoding: .utf8) ?? "")
            run.stderrTail = tail(result.stderr)
            run.status = result.exitCode == 0 ? .succeeded : .failed
            if result.exitCode != 0 {
                try store?.upsertRun(run)
                throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
        } catch {
            run.finishedAt = Date()
            run.status = .failed
            run.stderrTail = tail(error.localizedDescription)
            try? store?.upsertRun(run)
            throw error
        }

        try store?.upsertRun(run)
        return run
    }

    private static func launchValidationOnDGX(experiment: AutoPETVExperimentConfig,
                                              package: Package,
                                              caseCount: Int,
                                              dgx: DGXSparkConfig,
                                              store: AutoPETVExperimentStore?,
                                              timeoutSeconds: TimeInterval?,
                                              logSink: @escaping @Sendable (String) -> Void) throws -> AutoPETVExperimentRunRecord {
        let executor = RemoteExecutor(config: dgx)
        var run = AutoPETVExperimentRunRecord(
            experimentID: experiment.id,
            kind: .validation,
            status: .running,
            localPackagePath: package.localURL.path,
            remotePackagePath: package.remotePath,
            command: package.validateCommand,
            metadata: runMetadata(experiment: experiment, caseCount: caseCount)
        )
        try store?.upsertExperiment(experiment)
        try store?.upsertRun(run)

        do {
            try executor.uploadDirectory(package.localURL, toRemote: package.remotePath)
            let result = try executor.run(package.validateCommand,
                                          timeoutSeconds: timeoutSeconds,
                                          logSink: logSink)
            run.finishedAt = Date()
            run.stdoutTail = tail(String(data: result.stdout, encoding: .utf8) ?? "")
            run.stderrTail = tail(result.stderr)
            run.status = result.exitCode == 0 ? .succeeded : .failed
            if result.exitCode != 0 {
                try store?.upsertRun(run)
                throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }

            let localResults = package.localURL
                .appendingPathComponent("work", isDirectory: true)
                .appendingPathComponent(validationResultsFilename)
            try executor.downloadFile("\(package.remotePath)/work/\(validationResultsFilename)",
                                      toLocal: localResults)
            run.validation = try loadValidationRecords(from: localResults)
        } catch {
            run.finishedAt = Date()
            run.status = .failed
            run.stderrTail = tail(error.localizedDescription)
            try? store?.upsertRun(run)
            throw error
        }

        try store?.upsertRun(run)
        return run
    }

    private static func writeCaseSources(_ sources: [AutoPETVCasePackageSource],
                                         into packageURL: URL) throws {
        for source in sources {
            let caseURL = packageURL
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent(safeComponent(source.caseID), isDirectory: true)
            try FileManager.default.createDirectory(at: caseURL, withIntermediateDirectories: true)
            try MetaImageIO.write(source.ctVolume, to: caseURL.appendingPathComponent("ct.mha"))
            try MetaImageIO.write(source.petVolume, to: caseURL.appendingPathComponent("pet.mha"))
            if let labelMap = source.labelMap {
                let parent = labelParent(for: labelMap, source: source)
                try MetaImageIO.writeLabelMap(labelMap,
                                              to: caseURL.appendingPathComponent("label.mha"),
                                              parentVolume: parent,
                                              binary: true)
            }
        }
    }

    private static func labelParent(for labelMap: LabelMap,
                                    source: AutoPETVCasePackageSource) -> ImageVolume {
        if let explicit = source.labelParentVolume,
           sameGrid(labelMap, explicit) {
            return explicit
        }
        if sameGrid(labelMap, source.petVolume) {
            return source.petVolume
        }
        return source.ctVolume
    }

    private static func sameGrid(_ labelMap: LabelMap, _ volume: ImageVolume) -> Bool {
        labelMap.width == volume.width
            && labelMap.height == volume.height
            && labelMap.depth == volume.depth
    }

    private static func runMetadata(experiment: AutoPETVExperimentConfig,
                                    caseCount: Int) -> [String: String] {
        [
            "datasetID": experiment.datasetID,
            "promptEncoding": experiment.promptEncoding.rawValue,
            "promptDistanceMM": String(experiment.promptDistanceMM),
            "caseCount": String(caseCount),
            "useSparkDatasetRoot": experiment.useSparkDatasetRoot ? "true" : "false",
            "sparkDatasetRoot": experiment.sparkDatasetRoot,
            "sparkModelEnvironmentFile": experiment.sparkModelEnvironmentFile
        ]
    }

    private static func write(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else { return }
        try data.write(to: url, options: [.atomic])
    }

    private static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let chars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "autopetv" : cleaned
    }

    private static func safeCaseID(_ raw: String) -> String {
        let component = safeComponent(raw)
        let prefixed = component.first?.isNumber == true ? "case-\(component)" : component
        return prefixed.replacingOccurrences(of: ".", with: "-")
    }

    private static func tail(_ text: String, limit: Int = 8000) -> String {
        text.count > limit ? String(text.suffix(limit)) : text
    }

    private static func readme(experiment: AutoPETVExperimentConfig) -> String {
        """
        # \(experiment.name)

        AutoPET V DGX Spark package generated by Tracer. It is designed to run
        beside your local app while the DGX does the heavy lifting.

        - Dataset ID: \(experiment.datasetID)
        - Prompt encoding: \(experiment.promptEncoding.rawValue)
        - Prompt distance: \(experiment.promptDistanceMM) mm
        - Interaction steps: \(experiment.maxInteractionSteps)
        - Spark dataset root: \(experiment.sparkDatasetRoot)
        - Model env file: \(experiment.sparkModelEnvironmentFile)

        Expected Python packages on the DGX are listed in `requirements.txt`.
        The scripts accept MHA/MHD/NIfTI inputs, write an nnU-Net v2 dataset
        with CT, PET, foreground-prompt, and background-prompt channels, then
        train and validate interaction curves.

        Spark dataset mode:

        If `manifest.json` has no explicit cases and the experiment has
        `useSparkDatasetRoot=true`, the scripts discover cases from
        `\(experiment.sparkDatasetRoot)`. For Docker/container jobs, mount it
        as:

        ```bash
        -v \(experiment.sparkDatasetRoot):\(experiment.sparkContainerDatasetMount):ro
        ```

        Run on DGX:

        ```bash
        source \(experiment.sparkModelEnvironmentFile)
        python3 -m pip install -r requirements.txt
        python3 scripts/train_autopetv.py --manifest manifest.json --workdir work --prepare-only
        python3 scripts/train_autopetv.py --manifest manifest.json --workdir work
        python3 scripts/validate_autopetv.py --manifest manifest.json --workdir work
        ```

        Validation writes `work/\(validationResultsFilename)` for Tracer import.
        """
    }

    private struct ValidationEnvelope: Codable {
        var validation: [AutoPETVCaseValidationRecord]
    }

    private static let requirements = #"""
numpy
scipy
SimpleITK
nnunetv2
"""#

    private static let commonScript = #"""
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


def require_imaging_stack():
    try:
        import numpy as np
        import SimpleITK as sitk
        from scipy import ndimage as ndi
    except ImportError as exc:
        raise RuntimeError(
            "AutoPET V DGX scripts require numpy, scipy, and SimpleITK. "
            "Install with: python3 -m pip install -r requirements.txt"
        ) from exc
    return np, sitk, ndi


@dataclass
class Manifest:
    raw: dict

    @property
    def experiment(self):
        return self.raw["experiment"]

    @property
    def cases(self):
        explicit = self.raw.get("cases", [])
        if explicit:
            return explicit
        if not self.experiment.get("useSparkDatasetRoot", False):
            return []
        root = self.experiment.get("sparkDatasetRoot") or "/home/ahmed/datasets/autopet5/current"
        limit = int(self.experiment.get("sparkCaseLimit", 0) or 0)
        validation_fraction = float(self.experiment.get("sparkValidationFraction", 0.2) or 0.2)
        return discover_cases_from_dataset(root, limit=limit, validation_fraction=validation_fraction)

    @property
    def train_cases(self):
        return [c for c in self.cases if c.get("split") == "train"]

    @property
    def validation_cases(self):
        return [c for c in self.cases if c.get("split") == "validation"]

    @property
    def labeled_cases(self):
        return [c for c in self.cases if c.get("split") in ("train", "validation")]


def load_manifest(path):
    with open(path, "r", encoding="utf-8") as f:
        return Manifest(json.load(f))


def require_existing(path, field):
    if path is None:
        raise ValueError(f"Missing {field}")
    p = Path(path).expanduser()
    if not p.exists():
        raise FileNotFoundError(f"{field} does not exist: {p}")
    return p


def discover_cases_from_dataset(root, limit=0, validation_fraction=0.2):
    root = require_existing(root, "sparkDatasetRoot")
    cases = discover_nnunet_cases(root)
    if not cases:
        cases = discover_folder_cases(root)
    cases = sorted(cases, key=lambda c: c["caseID"])
    if limit > 0:
        cases = cases[:limit]
    assign_splits(cases, validation_fraction)
    if not cases:
        raise RuntimeError(
            f"No AutoPET cases discovered under {root}. Expected nnU-Net imagesTr/labelsTr "
            "or per-case folders containing CT, PET/SUV, and label/seg files."
        )
    return cases


def discover_nnunet_cases(root):
    cases = []
    images_tr = root / "imagesTr"
    labels_tr = root / "labelsTr"
    if not images_tr.exists() or not labels_tr.exists():
        return cases
    for ct_path in sorted(images_tr.glob("*_0000.nii*")):
        case_id = ct_path.name.split("_0000")[0]
        pet_path = first_existing([
            images_tr / f"{case_id}_0001.nii.gz",
            images_tr / f"{case_id}_0001.nii",
        ])
        label_path = first_existing([
            labels_tr / f"{case_id}.nii.gz",
            labels_tr / f"{case_id}.nii",
            labels_tr / f"{case_id}.mha",
            labels_tr / f"{case_id}.mhd",
        ])
        if pet_path and label_path:
            cases.append(case_entry(case_id, ct_path, pet_path, label_path))
    return cases


def discover_folder_cases(root):
    cases = []
    for folder in sorted([p for p in root.rglob("*") if p.is_dir()]):
        files = [p for p in folder.iterdir() if p.is_file() and image_suffix(p.name)]
        if len(files) < 2:
            continue
        ct = best_file(files, include=("ct",), exclude=("pet", "suv", "label", "seg", "mask"))
        pet = best_file(files, include=("pet", "suv"), exclude=("label", "seg", "mask"))
        label = best_file(files, include=("label", "seg", "mask", "tumor", "lesion"), exclude=("ct", "pet", "suv"))
        if ct and pet and label:
            cases.append(case_entry(folder.name, ct, pet, label))
    return cases


def case_entry(case_id, ct_path, pet_path, label_path):
    lower = f"{case_id} {pet_path.name}".lower()
    tracer = "PSMA" if "psma" in lower else ("FDG" if "fdg" in lower else "")
    return {
        "caseID": sanitize_case_id(case_id),
        "split": "train",
        "ctPath": str(ct_path),
        "petPath": str(pet_path),
        "labelPath": str(label_path),
        "tracer": tracer,
        "center": "",
        "notes": "discovered from Spark dataset root",
    }


def assign_splits(cases, validation_fraction):
    if not cases:
        return
    fraction = min(max(validation_fraction, 0.0), 0.9)
    validation_count = max(1, int(round(len(cases) * fraction))) if len(cases) > 1 else 0
    split_at = max(0, len(cases) - validation_count)
    for index, case in enumerate(cases):
        case["split"] = "validation" if index >= split_at else "train"


def first_existing(paths):
    for path in paths:
        if path.exists():
            return path
    return None


def best_file(files, include, exclude=()):
    ranked = []
    for path in files:
        lower = path.name.lower()
        if not any(token in lower for token in include):
            continue
        if any(token in lower for token in exclude):
            continue
        ranked.append((len(lower), lower, path))
    return sorted(ranked)[0][2] if ranked else None


def image_suffix(name):
    lower = name.lower()
    return lower.endswith((".nii", ".nii.gz", ".mha", ".mhd", ".nrrd"))


def sanitize_case_id(raw):
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", str(raw)).strip("-")
    return cleaned or "autopet-case"


def prompt_summary(manifest):
    exp = manifest.experiment
    return {
        "encoding": exp.get("promptEncoding", "edt"),
        "distance_mm": exp.get("promptDistanceMM", 40),
        "max_steps": exp.get("maxInteractionSteps", 4),
        "max_fg": exp.get("maxForegroundScribblesPerStep", 3),
        "max_bg": exp.get("maxBackgroundScribblesPerStep", 3),
    }


def dataset_number(dataset_id):
    match = re.match(r"Dataset([0-9]+)_", dataset_id)
    if not match:
        raise ValueError(f"nnU-Net datasetID must look like Dataset998_Name, got {dataset_id}")
    return int(match.group(1))


def dataset_dir_name(dataset_id):
    return dataset_id


def nnunet_roots(workdir, args=None):
    raw = Path(getattr(args, "nnunet_raw", "") or os.environ.get("nnUNet_raw", "") or workdir / "nnUNet_raw").expanduser()
    pre = Path(getattr(args, "nnunet_preprocessed", "") or os.environ.get("nnUNet_preprocessed", "") or workdir / "nnUNet_preprocessed").expanduser()
    res = Path(getattr(args, "nnunet_results", "") or os.environ.get("nnUNet_results", "") or workdir / "nnUNet_results").expanduser()
    for p in (raw, pre, res):
        p.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["nnUNet_raw"] = str(raw)
    env["nnUNet_preprocessed"] = str(pre)
    env["nnUNet_results"] = str(res)
    return raw, pre, res, env


def structure18(np):
    zz, yy, xx = np.indices((3, 3, 3)) - 1
    return (np.abs(zz) + np.abs(yy) + np.abs(xx)) <= 2


def read_image(path):
    _, sitk, _ = require_imaging_stack()
    return sitk.ReadImage(str(require_existing(path, "image")))


def image_array(image, dtype=None):
    np, sitk, _ = require_imaging_stack()
    arr = sitk.GetArrayFromImage(image)
    return arr.astype(dtype) if dtype is not None else arr


def ensure_same_geometry(reference, moving, field):
    mismatch = geometry_mismatch(reference, moving)
    if mismatch:
        name, ref, mov = mismatch
        raise ValueError(f"{field} {name} does not match CT/PET reference: {mov} vs {ref}")


def geometry_mismatch(reference, moving):
    if reference.GetSize() != moving.GetSize():
        return ("size", reference.GetSize(), moving.GetSize())

    def close_tuple(a, b, tolerance):
        return len(a) == len(b) and all(abs(float(x) - float(y)) <= tolerance for x, y in zip(a, b))

    checks = [
        ("spacing", reference.GetSpacing(), moving.GetSpacing(), 1e-4),
        ("origin", reference.GetOrigin(), moving.GetOrigin(), 1e-3),
        ("direction", reference.GetDirection(), moving.GetDirection(), 1e-5),
    ]
    for name, ref, mov, tolerance in checks:
        if not close_tuple(ref, mov, tolerance):
            return (name, ref, mov)
    return None


def resample_to_reference(moving, reference, field, pixel_kind="float"):
    mismatch = geometry_mismatch(reference, moving)
    if not mismatch:
        return moving
    _, sitk, _ = require_imaging_stack()
    name, ref, mov = mismatch
    print(json.dumps({
        "stage": "resample_to_reference",
        "field": field,
        "mismatch": name,
        "moving": str(mov),
        "reference": str(ref),
        "interpolator": "nearest" if pixel_kind == "label" else "linear",
    }), flush=True)
    interpolator = sitk.sitkNearestNeighbor if pixel_kind == "label" else sitk.sitkLinear
    output_type = sitk.sitkUInt8 if pixel_kind == "label" else sitk.sitkFloat32
    resampled = sitk.Resample(moving,
                              reference,
                              sitk.Transform(),
                              interpolator,
                              0,
                              output_type)
    return resampled


def cast_label(label_image):
    np, sitk, _ = require_imaging_stack()
    arr = sitk.GetArrayFromImage(label_image)
    arr = (arr > 0).astype(np.uint8)
    out = sitk.GetImageFromArray(arr)
    out.CopyInformation(label_image)
    return out


def write_like(array, reference, path, pixel_kind="float"):
    np, sitk, _ = require_imaging_stack()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if pixel_kind == "label":
        img = sitk.GetImageFromArray(array.astype(np.uint8))
    else:
        img = sitk.GetImageFromArray(array.astype(np.float32))
    img.CopyInformation(reference)
    sitk.WriteImage(img, str(path))
    return path


def point_to_dict(point):
    z, y, x = point
    return {"x": int(x), "y": int(y), "z": int(z)}


def suppression_radius(spacing_xyz, min_distance_mm):
    np, _, _ = require_imaging_stack()
    if spacing_xyz is None:
        return (8, 8, 8)
    spacing_zyx = (
        max(float(spacing_xyz[2]), 1e-6),
        max(float(spacing_xyz[1]), 1e-6),
        max(float(spacing_xyz[0]), 1e-6),
    )
    return tuple(max(1, int(np.ceil(min_distance_mm / spacing))) for spacing in spacing_zyx)


def suppress_box(scores, point, radius):
    z, y, x = point
    z0, z1 = max(0, z - radius[0]), min(scores.shape[0], z + radius[0] + 1)
    y0, y1 = max(0, y - radius[1]), min(scores.shape[1], y + radius[1] + 1)
    x0, x1 = max(0, x - radius[2]), min(scores.shape[2], x + radius[2] + 1)
    scores[z0:z1, y0:y1, x0:x1] = -float("inf")


def top_pet_points(mask, pet_arr, max_points, spacing_xyz=None, min_distance_mm=30):
    np, _, _ = require_imaging_stack()
    if max_points <= 0 or not np.any(mask):
        return []
    scores = pet_arr.astype(np.float32, copy=True)
    scores[~mask] = -float("inf")
    radius = suppression_radius(spacing_xyz, min_distance_mm)
    points = []
    for _ in range(max_points):
        flat_index = int(np.argmax(scores))
        best = float(scores.flat[flat_index])
        if not np.isfinite(best):
            break
        point = tuple(int(v) for v in np.unravel_index(flat_index, scores.shape))
        points.append(point)
        suppress_box(scores, point, radius)
    return points


def foreground_points(label_arr, pet_arr, max_points, spacing_xyz=None):
    return top_pet_points(label_arr > 0,
                          pet_arr,
                          max_points,
                          spacing_xyz=spacing_xyz,
                          min_distance_mm=30)


def background_points(label_arr, pet_arr, max_points, spacing_xyz=None):
    return top_pet_points(label_arr == 0,
                          pet_arr,
                          max_points,
                          spacing_xyz=spacing_xyz,
                          min_distance_mm=40)


def prompt_channel(shape, spacing_xyz, points, experiment):
    np, _, ndi = require_imaging_stack()
    encoding = experiment.get("promptEncoding", "edt")
    if not points:
        return np.zeros(shape, dtype=np.float32)
    if encoding == "binary":
        out = np.zeros(shape, dtype=np.float32)
        for z, y, x in points:
            if 0 <= z < shape[0] and 0 <= y < shape[1] and 0 <= x < shape[2]:
                out[z, y, x] = 1.0
        return out

    max_distance = float(experiment.get("promptDistanceMM", 40) or 40)
    out = np.zeros(shape, dtype=np.float32)
    spacing_zyx = (
        float(spacing_xyz[2]),
        float(spacing_xyz[1]),
        float(spacing_xyz[0]),
    )
    radius = [max(1, int(np.ceil(max_distance / spacing))) for spacing in spacing_zyx]
    for z, y, x in points:
        if not (0 <= z < shape[0] and 0 <= y < shape[1] and 0 <= x < shape[2]):
            continue
        z0, z1 = max(0, z - radius[0]), min(shape[0], z + radius[0] + 1)
        y0, y1 = max(0, y - radius[1]), min(shape[1], y + radius[1] + 1)
        x0, x1 = max(0, x - radius[2]), min(shape[2], x + radius[2] + 1)
        zz, yy, xx = np.ogrid[z0:z1, y0:y1, x0:x1]
        distance = np.sqrt(
            ((zz - z) * spacing_zyx[0]) ** 2
            + ((yy - y) * spacing_zyx[1]) ** 2
            + ((xx - x) * spacing_zyx[2]) ** 2
        )
        values = np.maximum(0, 1.0 - distance / max_distance).astype(np.float32)
        region = out[z0:z1, y0:y1, x0:x1]
        np.maximum(region, values, out=region)
    return out


def initial_scribbles(label_arr, pet_arr, experiment, spacing_xyz=None):
    fg_max = int(experiment.get("maxForegroundScribblesPerStep", 3) or 3)
    bg_max = int(experiment.get("maxBackgroundScribblesPerStep", 3) or 3)
    return (
        foreground_points(label_arr, pet_arr, max(1, min(fg_max, 1)), spacing_xyz=spacing_xyz),
        background_points(label_arr, pet_arr, max(1, min(bg_max, 1)), spacing_xyz=spacing_xyz),
    )


def simulated_corrective_scribbles(pred_arr, label_arr, pet_arr, experiment, spacing_xyz=None):
    fg_max = int(experiment.get("maxForegroundScribblesPerStep", 3) or 3)
    bg_max = int(experiment.get("maxBackgroundScribblesPerStep", 3) or 3)
    missed = (label_arr > 0) & (pred_arr == 0)
    false_positive = (pred_arr > 0) & (label_arr == 0)
    return (
        foreground_points(missed, pet_arr, fg_max, spacing_xyz=spacing_xyz),
        foreground_points(false_positive, pet_arr, bg_max, spacing_xyz=spacing_xyz),
    )


def write_nnunet_case(ct_image, pet_image, fg_points, bg_points, case_id, out_dir, experiment):
    np, _, _ = require_imaging_stack()
    ensure_same_geometry(ct_image, pet_image, "PET")
    ct_arr = image_array(ct_image, np.float32)
    pet_arr = image_array(pet_image, np.float32)
    spacing = ct_image.GetSpacing()
    fg_arr = prompt_channel(ct_arr.shape, spacing, fg_points, experiment)
    bg_arr = prompt_channel(ct_arr.shape, spacing, bg_points, experiment)
    out_dir = Path(out_dir)
    write_like(ct_arr, ct_image, out_dir / f"{case_id}_0000.nii.gz")
    write_like(pet_arr, ct_image, out_dir / f"{case_id}_0001.nii.gz")
    write_like(fg_arr, ct_image, out_dir / f"{case_id}_0002.nii.gz")
    write_like(bg_arr, ct_image, out_dir / f"{case_id}_0003.nii.gz")


def expected_case_outputs(case, dataset_dir):
    case_id = case["caseID"]
    split = case.get("split", "train")
    images_dir = dataset_dir / ("imagesTs" if split == "test" else "imagesTr")
    outputs = [images_dir / f"{case_id}_{channel:04d}.nii.gz" for channel in range(4)]
    if case.get("labelPath"):
        outputs.append(dataset_dir / "labelsTr" / f"{case_id}.nii.gz")
    return outputs


def case_outputs_exist(case, dataset_dir):
    return all(path.exists() for path in expected_case_outputs(case, dataset_dir))


def prepare_case_for_nnunet(case, dataset_dir, experiment):
    np, _, _ = require_imaging_stack()
    case_id = case["caseID"]
    split = case.get("split", "train")
    ct_image = read_image(case["ctPath"])
    pet_image = read_image(case["petPath"])
    pet_image = resample_to_reference(pet_image,
                                      ct_image,
                                      f"{case_id} PET",
                                      pixel_kind="float")
    ensure_same_geometry(ct_image, pet_image, f"{case_id} PET")
    pet_arr = image_array(pet_image, np.float32)

    label_arr = None
    if case.get("labelPath"):
        label_image = cast_label(read_image(case["labelPath"]))
        label_image = resample_to_reference(label_image,
                                            ct_image,
                                            f"{case_id} label",
                                            pixel_kind="label")
        ensure_same_geometry(ct_image, label_image, f"{case_id} label")
        label_arr = image_array(label_image, np.uint8)
    elif split in ("train", "validation"):
        raise ValueError(f"{case_id} is {split} but has no labelPath")

    if label_arr is None:
        fg_points, bg_points = [], []
    else:
        fg_points = foreground_points(label_arr,
                                      pet_arr,
                                      int(experiment.get("maxForegroundScribblesPerStep", 3) or 3),
                                      spacing_xyz=ct_image.GetSpacing())
        bg_points = background_points(label_arr,
                                      pet_arr,
                                      int(experiment.get("maxBackgroundScribblesPerStep", 3) or 3),
                                      spacing_xyz=ct_image.GetSpacing())

    images_dir = dataset_dir / ("imagesTs" if split == "test" else "imagesTr")
    write_nnunet_case(ct_image, pet_image, fg_points, bg_points, case_id, images_dir, experiment)
    if label_arr is not None:
        write_like(label_arr, ct_image, dataset_dir / "labelsTr" / f"{case_id}.nii.gz", pixel_kind="label")


def write_dataset_json(dataset_dir, dataset_id, num_training):
    dataset = {
        "channel_names": {
            "0": "CT",
            "1": "PET",
            "2": "foreground_prompt",
            "3": "background_prompt",
        },
        "labels": {
            "background": 0,
            "tumor": 1,
        },
        "numTraining": int(num_training),
        "file_ending": ".nii.gz",
        "overwrite_image_reader_writer": "SimpleITKIO",
    }
    (dataset_dir / "dataset.json").write_text(json.dumps(dataset, indent=2), encoding="utf-8")


def write_splits(preprocessed_root, dataset_id, train_cases, validation_cases):
    split_dir = Path(preprocessed_root) / dataset_dir_name(dataset_id)
    split_dir.mkdir(parents=True, exist_ok=True)
    payload = [{
        "train": [c["caseID"] for c in train_cases],
        "val": [c["caseID"] for c in validation_cases],
    }]
    (split_dir / "splits_final.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")


def prepare_nnunet_dataset(manifest, workdir, args=None):
    raw, pre, res, env = nnunet_roots(workdir, args)
    dataset_id = manifest.experiment["datasetID"]
    dataset_dir = raw / dataset_dir_name(dataset_id)
    for subdir in ("imagesTr", "labelsTr", "imagesTs"):
        (dataset_dir / subdir).mkdir(parents=True, exist_ok=True)
    cases = manifest.cases
    for index, case in enumerate(cases, start=1):
        print(json.dumps({
            "stage": "prepare_case",
            "index": index,
            "total": len(cases),
            "caseID": case["caseID"],
            "split": case.get("split", "train"),
        }), flush=True)
        skipped = False
        if case_outputs_exist(case, dataset_dir):
            skipped = True
        else:
            prepare_case_for_nnunet(case, dataset_dir, manifest.experiment)
        print(json.dumps({
            "stage": "prepare_case_done",
            "index": index,
            "total": len(cases),
            "caseID": case["caseID"],
            "split": case.get("split", "train"),
            "skipped": skipped,
        }), flush=True)
    write_dataset_json(dataset_dir, dataset_id, len(manifest.labeled_cases))
    write_splits(pre, dataset_id, manifest.train_cases, manifest.validation_cases)
    return {
        "dataset_id": dataset_id,
        "dataset_number": dataset_number(dataset_id),
        "dataset_dir": str(dataset_dir),
        "nnUNet_raw": str(raw),
        "nnUNet_preprocessed": str(pre),
        "nnUNet_results": str(res),
        "env": env,
    }


def run_command(command, env, cwd=None):
    print("+ " + " ".join(str(c) for c in command), flush=True)
    completed = subprocess.run(command, cwd=cwd, env=env)
    if completed.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {completed.returncode}: {' '.join(command)}")


def require_command(name):
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"Required command not found on PATH: {name}")
    return found


def load_label_array(path):
    np, sitk, _ = require_imaging_stack()
    image = sitk.ReadImage(str(path))
    arr = (sitk.GetArrayFromImage(image) > 0).astype(np.uint8)
    return image, arr


def connected_components(mask):
    np, _, ndi = require_imaging_stack()
    labels, count = ndi.label(mask > 0, structure=structure18(np))
    return labels, int(count)


def compute_step_metrics(pred_arr, label_arr, spacing_xyz, step_index, overlap_threshold=0.1):
    np, _, _ = require_imaging_stack()
    pred = pred_arr > 0
    label = label_arr > 0
    pred_count = int(np.count_nonzero(pred))
    label_count = int(np.count_nonzero(label))
    intersection = int(np.count_nonzero(pred & label))
    dice = None if label_count == 0 else (2.0 * intersection / (pred_count + label_count) if pred_count + label_count > 0 else 0.0)

    pred_labels, pred_components = connected_components(pred)
    label_labels, label_components = connected_components(label)
    overlaps = {}
    overlap_pred = set()
    overlap_label = set()
    for gt_id in range(1, label_components + 1):
        gt_mask = label_labels == gt_id
        pred_ids = np.unique(pred_labels[gt_mask])
        for pred_id in pred_ids:
            if pred_id == 0:
                continue
            overlap = int(np.count_nonzero(gt_mask & (pred_labels == pred_id)))
            if overlap > 0:
                overlaps[(gt_id, int(pred_id))] = overlap
                overlap_label.add(gt_id)
                overlap_pred.add(int(pred_id))

    matched_gt = set()
    matched_pred = set()
    for (gt_id, pred_id), overlap in overlaps.items():
        gt_size = int(np.count_nonzero(label_labels == gt_id))
        pred_size = int(np.count_nonzero(pred_labels == pred_id))
        union = gt_size + pred_size - overlap
        if union > 0 and overlap / union >= overlap_threshold:
            matched_gt.add(gt_id)
            matched_pred.add(pred_id)

    tp = len(matched_gt)
    fp = pred_components - len(matched_pred)
    fn = label_components - tp
    dmm = None if tp + fn == 0 else (0.0 if tp == 0 else 2.0 * tp / (2 * tp + fp + fn))
    voxel_ml = float(spacing_xyz[0]) * float(spacing_xyz[1]) * float(spacing_xyz[2]) / 1000.0
    fpv = sum(int(np.count_nonzero(pred_labels == comp)) * voxel_ml for comp in range(1, pred_components + 1) if comp not in overlap_pred)
    fnv = sum(int(np.count_nonzero(label_labels == comp)) * voxel_ml for comp in range(1, label_components + 1) if comp not in overlap_label)
    return {
        "stepIndex": int(step_index),
        "dice": dice,
        "dmm": dmm,
        "truePositiveLesions": int(tp),
        "falsePositiveLesions": int(fp),
        "falseNegativeLesions": int(fn),
        "falsePositiveVolumeML": float(fpv),
        "falseNegativeVolumeML": float(fnv),
        "predictionLesions": int(pred_components),
        "referenceLesions": int(label_components),
    }


def normalized_auc(values):
    points = [(i, v) for i, v in enumerate(values) if v is not None]
    if not points:
        return None
    if len(points) == 1:
        return float(points[0][1])
    first_x, _ = points[0]
    last_x, _ = points[-1]
    if last_x <= first_x:
        return float(points[0][1])
    area = 0.0
    for (x0, y0), (x1, y1) in zip(points[:-1], points[1:]):
        area += (x1 - x0) * (y0 + y1) / 2.0
    return float(area / (last_x - first_x))


def failure_tags(steps):
    tags = set()
    for step in steps:
        if step["referenceLesions"] > 0 and step["predictionLesions"] == 0:
            tags.add("empty_prediction_with_lesions")
        if step["referenceLesions"] == 0 and step["predictionLesions"] > 0:
            tags.add("empty_ground_truth_false_positive")
        if step["falseNegativeLesions"] > 0 or step["falseNegativeVolumeML"] >= 10:
            tags.add("missed_lesions")
        if step["falsePositiveLesions"] > 0 or step["falsePositiveVolumeML"] >= 10:
            tags.add("false_positive_burden")
        if step.get("dmm") is not None and step["dmm"] < 0.5:
            tags.add("weak_detection")
    for before, after in zip(steps[:-1], steps[1:]):
        if before.get("dice") is not None and after.get("dice") is not None and after["dice"] + 0.01 < before["dice"]:
            tags.add("dice_regression_after_scribble")
        if before.get("dmm") is not None and after.get("dmm") is not None and after["dmm"] + 0.01 < before["dmm"]:
            tags.add("dmm_regression_after_scribble")
    order = [
        "missed_lesions",
        "false_positive_burden",
        "weak_detection",
        "dice_regression_after_scribble",
        "dmm_regression_after_scribble",
        "empty_prediction_with_lesions",
        "empty_ground_truth_false_positive",
    ]
    return [tag for tag in order if tag in tags]


def assistant_brief(case_id, steps, tags):
    if not steps:
        return f"AutoPET V review for {case_id}: no validation steps available."
    last = steps[-1]
    dice_auc = normalized_auc([s.get("dice") for s in steps])
    dmm_auc = normalized_auc([s.get("dmm") for s in steps])
    return (
        f"AutoPET V review for {case_id}\n"
        f"AUC-Dice: {dice_auc if dice_auc is not None else 'n/a'}, "
        f"AUC-DMM: {dmm_auc if dmm_auc is not None else 'n/a'}\n"
        f"Final: Dice {last.get('dice')}, DMM {last.get('dmm')}, "
        f"TP {last['truePositiveLesions']}, FP {last['falsePositiveLesions']}, "
        f"FN {last['falseNegativeLesions']}\n"
        f"Tags: {', '.join(tags) if tags else 'none'}"
    )
"""#

    private static let trainingScript = #"""
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from autopetv_common import (
    dataset_dir_name,
    prepare_nnunet_dataset,
    prompt_summary,
    load_manifest,
    require_command,
    run_command,
    write_splits,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--nnunet-raw", default="")
    parser.add_argument("--nnunet-preprocessed", default="")
    parser.add_argument("--nnunet-results", default="")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--skip-preprocess", action="store_true")
    parser.add_argument("--skip-training", action="store_true")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    workdir = Path(args.workdir).expanduser()
    workdir.mkdir(parents=True, exist_ok=True)

    package = prepare_nnunet_dataset(manifest, workdir, args)
    folds = manifest.experiment.get("folds", ["0"]) or ["0"]
    configuration = manifest.experiment.get("nnunetConfiguration", "3d_fullres")

    plan = {
        "stage": "training",
        "dataset_id": package["dataset_id"],
        "dataset_dir": package["dataset_dir"],
        "nnUNet_raw": package["nnUNet_raw"],
        "nnUNet_preprocessed": package["nnUNet_preprocessed"],
        "nnUNet_results": package["nnUNet_results"],
        "nnunet_configuration": configuration,
        "folds": folds,
        "train_cases": len(manifest.train_cases),
        "validation_cases": len(manifest.validation_cases),
        "prompt": prompt_summary(manifest),
    }
    (workdir / "training_plan.json").write_text(json.dumps(plan, indent=2), encoding="utf-8")
    print(json.dumps(plan, indent=2), flush=True)

    if args.prepare_only:
        return

    if not args.skip_preprocess:
        require_command("nnUNetv2_plan_and_preprocess")
        run_command([
            "nnUNetv2_plan_and_preprocess",
            "-d", str(package["dataset_number"]),
            "--verify_dataset_integrity",
        ], env=package["env"])
        write_splits(package["nnUNet_preprocessed"], package["dataset_id"], manifest.train_cases, manifest.validation_cases)

    if not args.skip_training:
        require_command("nnUNetv2_train")
        for fold in folds:
            run_command([
                "nnUNetv2_train",
                str(package["dataset_number"]),
                configuration,
                str(fold),
                "--npz",
            ], env=package["env"])

    done = dict(plan)
    done["stage"] = "training_complete"
    (workdir / "training_complete.json").write_text(json.dumps(done, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
"""#

    private static let validationScript = #"""
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from autopetv_common import (
    assistant_brief,
    compute_step_metrics,
    initial_scribbles,
    load_label_array,
    load_manifest,
    nnunet_roots,
    normalized_auc,
    read_image,
    require_command,
    run_command,
    simulated_corrective_scribbles,
    write_nnunet_case,
    failure_tags,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--predictions-root", default="")
    parser.add_argument("--model-folder", default="")
    parser.add_argument("--checkpoint", default="")
    parser.add_argument("--nnunet-raw", default="")
    parser.add_argument("--nnunet-preprocessed", default="")
    parser.add_argument("--nnunet-results", default="")
    parser.add_argument("--skip-inference", action="store_true")
    parser.add_argument("--disable-tta", action="store_true")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    workdir = Path(args.workdir).expanduser()
    workdir.mkdir(parents=True, exist_ok=True)
    _, _, _, nnunet_env = nnunet_roots(workdir, args)
    predictions_root = Path(args.predictions_root).expanduser() if args.predictions_root else workdir / "predictions"
    input_root = workdir / "validation_inputs"
    results = []
    configuration = manifest.experiment.get("nnunetConfiguration", "3d_fullres")
    folds = manifest.experiment.get("folds", ["0"]) or ["0"]

    if not args.skip_inference:
        require_command("nnUNetv2_predict_from_modelfolder" if args.model_folder else "nnUNetv2_predict")

    for case in manifest.validation_cases:
        case_id = case["caseID"]
        ct_image = read_image(case["ctPath"])
        pet_image = read_image(case["petPath"])
        label_image, label_arr = load_label_array(case["labelPath"])
        pet_arr = __import__("SimpleITK").GetArrayFromImage(pet_image).astype("float32")
        fg_points, bg_points = initial_scribbles(label_arr,
                                                 pet_arr,
                                                 manifest.experiment,
                                                 spacing_xyz=label_image.GetSpacing())
        steps = []

        for step in range(int(manifest.experiment.get("maxInteractionSteps", 4) or 4)):
            step_input = input_root / f"step_{step}"
            step_output = predictions_root / f"step_{step}"
            step_input.mkdir(parents=True, exist_ok=True)
            step_output.mkdir(parents=True, exist_ok=True)
            write_nnunet_case(ct_image, pet_image, fg_points, bg_points, case_id, step_input, manifest.experiment)

            if not args.skip_inference:
                if args.model_folder:
                    command = [
                        "nnUNetv2_predict_from_modelfolder",
                        "-i", str(step_input),
                        "-o", str(step_output),
                        "-m", str(Path(args.model_folder).expanduser()),
                        "-f",
                    ] + [str(f) for f in folds]
                else:
                    command = [
                        "nnUNetv2_predict",
                        "-i", str(step_input),
                        "-o", str(step_output),
                        "-d", manifest.experiment["datasetID"],
                        "-c", configuration,
                        "-f",
                    ] + [str(f) for f in folds]
                if args.checkpoint:
                    command.extend(["-chk", args.checkpoint])
                if args.disable_tta:
                    command.append("--disable_tta")
                command.append("--disable_progress_bar")
                run_command(command, env=nnunet_env)

            pred_path = step_output / f"{case_id}.nii.gz"
            if not pred_path.exists():
                pred_path = step_output / f"{case_id}.nii"
            pred_image, pred_arr = load_label_array(pred_path)
            steps.append(compute_step_metrics(pred_arr, label_arr, label_image.GetSpacing(), step))
            add_fg, add_bg = simulated_corrective_scribbles(pred_arr,
                                                            label_arr,
                                                            pet_arr,
                                                            manifest.experiment,
                                                            spacing_xyz=label_image.GetSpacing())
            fg_points.extend(add_fg)
            bg_points.extend(add_bg)

        tags = failure_tags(steps)
        results.append({
            "caseID": case_id,
            "steps": steps,
            "aucDice": normalized_auc([s.get("dice") for s in steps]),
            "aucDMM": normalized_auc([s.get("dmm") for s in steps]),
            "failureTags": tags,
            "assistantBrief": assistant_brief(case_id, steps, tags),
        })

    envelope = {
        "stage": "validation_complete",
        "datasetID": manifest.experiment["datasetID"],
        "validation": results,
    }
    out = workdir / "validation_results.json"
    out.write_text(json.dumps(envelope, indent=2), encoding="utf-8")
    print(json.dumps(envelope, indent=2), flush=True)


if __name__ == "__main__":
    main()
"""#
}
