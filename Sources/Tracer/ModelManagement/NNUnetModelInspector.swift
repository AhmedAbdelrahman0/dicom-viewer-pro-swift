import Foundation

/// Inspects an unpacked nnU-Net v2 model folder without copying the weights.
///
/// The important case for Tracer is the legacy PET Segmentator LesionTracer
/// bundle, which already contains a valid trained-model folder:
///
/// `Dataset222_AutoPETIII_2024/autoPET3_Trainer__nnUNetResEncUNetLPlansMultiTalent__3d_fullres_bs3`
///
/// Those checkpoints are several gigabytes, so the model manager should link
/// them in place instead of ingesting them into Application Support.
public enum NNUnetModelInspector {

    public struct Artifact: Hashable, Sendable {
        public let modelFolder: URL
        public let datasetDirectory: URL
        public let resultsDirectory: URL
        public let bundledPythonRoot: URL?
        public let displayName: String
        public let datasetID: String
        public let trainerName: String
        public let plansName: String
        public let configuration: String
        public let folds: [String]
        public let labelNames: [Int: String]
        public let channelNames: [Int: String]
        public let sizeBytes: Int
    }

    public enum InspectorError: Error, LocalizedError {
        case noModelFolder(URL)

        public var errorDescription: String? {
            switch self {
            case .noModelFolder(let url):
                return "No nnU-Net trained-model folder was found under \(url.path)."
            }
        }
    }

    public static let segmentatorRoot = URL(
        fileURLWithPath: "/Users/ahmedabdelrahman/Desktop/AI/Medical AI/PET segmentator",
        isDirectory: true
    )

    public static var knownSegmentatorSearchRoots: [URL] {
        [
            segmentatorRoot.appendingPathComponent("LesionTracer_model", isDirectory: true),
            segmentatorRoot
        ]
    }

    public static func knownSegmentatorLesionTracerArtifact() -> Artifact? {
        for root in knownSegmentatorSearchRoots {
            if let artifact = try? inspect(root),
               artifact.datasetID.lowercased().contains("autopetiii")
                || artifact.datasetID.lowercased().contains("autopet3")
                || artifact.modelFolder.lastPathComponent.lowercased().contains("autopet3") {
                return artifact
            }
        }
        return nil
    }

    public static func inspect(_ url: URL) throws -> Artifact {
        let standardized = url.standardizedFileURL
        if isTrainedModelFolder(standardized) {
            return try makeArtifact(modelFolder: standardized)
        }

        if let known = knownLesionTracerModelFolder(under: standardized),
           isTrainedModelFolder(known) {
            return try makeArtifact(modelFolder: known)
        }

        if let discovered = shallowModelFolder(under: standardized) {
            return try makeArtifact(modelFolder: discovered)
        }

        throw InspectorError.noModelFolder(standardized)
    }

    public static func isTrainedModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        let datasetJSON = url.appendingPathComponent("dataset.json")
        let plansJSON = url.appendingPathComponent("plans.json")
        guard fm.fileExists(atPath: datasetJSON.path),
              fm.fileExists(atPath: plansJSON.path) else {
            return false
        }
        return !folds(in: url).isEmpty
    }

    // MARK: - Discovery

    private static func knownLesionTracerModelFolder(under root: URL) -> URL? {
        let relative = [
            "Dataset222_AutoPETIII_2024",
            "autoPET3_Trainer__nnUNetResEncUNetLPlansMultiTalent__3d_fullres_bs3"
        ].joined(separator: "/")

        let candidates = [
            root.appendingPathComponent(relative, isDirectory: true),
            root.appendingPathComponent("LesionTracer_model/\(relative)", isDirectory: true)
        ]
        return candidates.first(where: isTrainedModelFolder)
    }

    private static func shallowModelFolder(under root: URL) -> URL? {
        let fm = FileManager.default
        if isTrainedModelFolder(root) { return root }

        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for child in children where child.isDirectoryURL {
            if isTrainedModelFolder(child) { return child }
        }

        // nnU-Net results layout: <results>/<DatasetXXX>/<trainer__plans__config>
        for dataset in children where dataset.isDirectoryURL && dataset.lastPathComponent.lowercased().hasPrefix("dataset") {
            guard let modelFolders = try? fm.contentsOfDirectory(
                at: dataset,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if let match = modelFolders.first(where: isTrainedModelFolder) {
                return match
            }
        }

        return nil
    }

    private static func makeArtifact(modelFolder: URL) throws -> Artifact {
        let datasetDirectory = modelFolder.deletingLastPathComponent()
        let resultsDirectory = datasetDirectory.deletingLastPathComponent()
        let parts = modelFolder.lastPathComponent.components(separatedBy: "__")
        let trainer = parts.first ?? ""
        let plans = parts.count > 1 ? parts[1] : ""
        let rawConfiguration = parts.count > 2 ? parts.dropFirst(2).joined(separator: "__") : "3d_fullres"
        let configuration = normalizedConfiguration(rawConfiguration)
        let labelsAndChannels = try parseDatasetJSON(at: modelFolder.appendingPathComponent("dataset.json"))
        let folderSize = directorySize(modelFolder)

        return Artifact(
            modelFolder: modelFolder,
            datasetDirectory: datasetDirectory,
            resultsDirectory: resultsDirectory,
            bundledPythonRoot: bundledPythonRoot(for: modelFolder),
            displayName: displayName(datasetID: datasetDirectory.lastPathComponent, trainer: trainer),
            datasetID: datasetDirectory.lastPathComponent,
            trainerName: trainer,
            plansName: plans,
            configuration: configuration,
            folds: folds(in: modelFolder),
            labelNames: labelsAndChannels.labels,
            channelNames: labelsAndChannels.channels,
            sizeBytes: folderSize
        )
    }

    private static func normalizedConfiguration(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("3d_cascade_fullres") { return "3d_cascade_fullres" }
        if lower.contains("3d_fullres") { return "3d_fullres" }
        if lower.contains("3d_lowres") { return "3d_lowres" }
        if lower.contains("2d") { return "2d" }
        return raw.isEmpty ? "3d_fullres" : raw
    }

    private static func displayName(datasetID: String, trainer: String) -> String {
        if datasetID.lowercased().contains("autopetiii") || trainer.lowercased().contains("autopet3") {
            return "LesionTracer AutoPET III"
        }
        return datasetID
    }

    private static func folds(in modelFolder: URL) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: modelFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.compactMap { child -> String? in
            guard child.isDirectoryURL,
                  child.lastPathComponent.hasPrefix("fold_"),
                  fm.fileExists(atPath: child.appendingPathComponent("checkpoint_final.pth").path) else {
                return nil
            }
            return String(child.lastPathComponent.dropFirst("fold_".count))
        }
        .sorted { lhs, rhs in
            if let li = Int(lhs), let ri = Int(rhs) { return li < ri }
            return lhs < rhs
        }
    }

    private static func parseDatasetJSON(at url: URL) throws -> (labels: [Int: String], channels: [Int: String]) {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            return ([:], [:])
        }

        var labels: [Int: String] = [:]
        if let labelDict = dict["labels"] as? [String: Any] {
            for (name, rawID) in labelDict {
                if let id = rawID as? Int {
                    labels[id] = name
                } else if let stringID = rawID as? String, let id = Int(stringID) {
                    labels[id] = name
                }
            }
        }

        var channels: [Int: String] = [:]
        let channelDict = (dict["channel_names"] as? [String: Any])
            ?? (dict["modality"] as? [String: Any])
            ?? [:]
        for (rawIndex, rawName) in channelDict {
            guard let index = Int(rawIndex) else { continue }
            if let name = rawName as? String {
                channels[index] = name
            }
        }

        return (labels, channels)
    }

    private static func directorySize(_ url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total > Int64(Int.max) ? Int.max : Int(total)
    }

    private static func bundledPythonRoot(for modelFolder: URL) -> URL? {
        let roots = [
            modelFolder.deletingLastPathComponent().deletingLastPathComponent(),
            modelFolder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ]

        for root in roots {
            let direct = root.appendingPathComponent("autopet-3-submission", isDirectory: true)
            if hasNNUnetPackage(direct) { return direct }
            if hasNNUnetPackage(root) { return root }
        }
        return nil
    }

    private static func hasNNUnetPackage(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("nnunetv2").path)
    }
}

private extension URL {
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
