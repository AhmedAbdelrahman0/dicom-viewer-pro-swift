import Foundation

/// DGX-Spark-backed lesion classifier. Mirrors `SubprocessLesionClassifier`'s
/// stdin/stdout contract but ships the JSON payload over SSH to a user-
/// installed Python script on the DGX.
///
/// Expected remote script: reads JSON on stdin, writes JSON on stdout in the
/// same shape as the local subprocess classifier:
/// ```json
/// { "classes": [...], "probabilities": [...], "rationale": "...", "features": {...} }
/// ```
public final class RemoteLesionClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    public struct Spec: Sendable {
        public var dgx: DGXSparkConfig
        /// Absolute path to the Python script on the DGX.
        public var remoteScriptPath: String
        /// Optional command to activate a conda/venv before running the
        /// script — e.g. `"conda activate tracer"` or
        /// `"source ~/envs/radiomics/bin/activate"`.
        public var activationCommand: String
        /// Extra arguments appended after the script path.
        public var scriptArguments: [String]
        /// How long to wait for a single lesion. Generous by default
        /// because cold-starts (torch import, model load) can take 20 s.
        public var timeoutSeconds: TimeInterval

        public init(dgx: DGXSparkConfig,
                    remoteScriptPath: String,
                    activationCommand: String = "",
                    scriptArguments: [String] = [],
                    timeoutSeconds: TimeInterval = 180) {
            self.dgx = dgx
            self.remoteScriptPath = remoteScriptPath
            self.activationCommand = activationCommand
            self.scriptArguments = scriptArguments
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "Runs on user's DGX Spark via SSH") {
        self.id = id
        self.displayName = displayName
        self.spec = spec
        self.supportedModalities = supportedModalities
        self.supportedBodyRegions = supportedBodyRegions
        self.provenance = provenance
    }

    public func classify(volume: ImageVolume,
                         mask: LabelMap,
                         classID: UInt16,
                         bounds: MONAITransforms.VoxelBounds) async throws -> ClassificationResult {
        guard spec.dgx.isConfigured else {
            throw ClassificationError.modelUnavailable("DGX Spark not configured.")
        }

        let start = Date()
        let executor = RemoteExecutor(config: spec.dgx)

        // 1. Build the same JSON payload as the local subprocess classifier.
        let crop = MONAITransforms.crop(volume, to: bounds)
        var maskBytes: [Int] = []
        maskBytes.reserveCapacity(crop.depth * crop.height * crop.width)
        for z in bounds.minZ...bounds.maxZ {
            for y in bounds.minY...bounds.maxY {
                let rowStart = z * mask.height * mask.width + y * mask.width
                for x in bounds.minX...bounds.maxX {
                    maskBytes.append(mask.voxels[rowStart + x] == classID ? 1 : 0)
                }
            }
        }
        let payload: [String: Any] = [
            "shape": [crop.depth, crop.height, crop.width],
            "spacing": [crop.spacing.x, crop.spacing.y, crop.spacing.z],
            "modality": crop.modality,
            "classID": Int(classID),
            "pixels": crop.pixels.map { Double($0) },
            "mask": maskBytes
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        // 2. Upload the payload — passing via argv would blow past ARG_MAX
        //    for anything larger than a toy lesion, so we stage a file.
        let remoteBase = "\(spec.dgx.remoteWorkdir)/classify-\(UUID().uuidString.prefix(8))"
        let remotePayloadPath = "\(remoteBase)/payload.json"
        let remoteOutPath = "\(remoteBase)/result.json"
        defer { executor.remove(remoteBase) }
        try executor.ensureRemoteDirectory(remoteBase)

        let localPayload = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-classify-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: localPayload) }
        try jsonData.write(to: localPayload)
        try executor.uploadFile(localPayload, toRemote: remotePayloadPath)

        // 3. Command. Optional env activation → pipe payload into python3 → redirect to result.json.
        var parts: [String] = []
        if !spec.activationCommand.isEmpty {
            parts.append(spec.activationCommand)
            parts.append("&&")
        }
        parts.append("cat \(RemoteExecutor.shellEscape(remotePayloadPath))")
        parts.append("|")
        parts.append("python3")
        parts.append(RemoteExecutor.shellEscape(spec.remoteScriptPath))
        for arg in spec.scriptArguments {
            parts.append(RemoteExecutor.shellEscape(arg))
        }
        parts.append(">")
        parts.append(RemoteExecutor.shellEscape(remoteOutPath))
        let command = parts.joined(separator: " ")

        let runResult = try executor.run(command, timeoutSeconds: spec.timeoutSeconds)
        guard runResult.exitCode == 0 else {
            throw ClassificationError.inferenceFailed(
                "remote classifier exited \(runResult.exitCode): \(runResult.stderr)"
            )
        }

        // 4. Pull result + parse.
        let localResult = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-result-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: localResult) }
        try executor.downloadFile(remoteOutPath, toLocal: localResult)

        let data = try Data(contentsOf: localResult)
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let classes = dict["classes"] as? [String],
              let probs = dict["probabilities"] as? [Double],
              classes.count == probs.count else {
            throw ClassificationError.inferenceFailed("malformed remote classifier response")
        }

        let predictions = zip(classes, probs).map {
            LabelPrediction(label: $0.0, probability: $0.1)
        }
        return ClassificationResult(
            predictions: predictions,
            rationale: dict["rationale"] as? String,
            features: (dict["features"] as? [String: Double]) ?? [:],
            durationSeconds: Date().timeIntervalSince(start),
            classifierID: id
        )
    }
}
