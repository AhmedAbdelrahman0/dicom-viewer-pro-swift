import Foundation

/// Classifier that shells out to a user-supplied Python binary that reads a
/// JSON payload from stdin (containing the lesion VOI + metadata) and
/// writes a JSON response to stdout.
///
/// This gets Tracer access to the pyradiomics + sklearn / XGBoost /
/// PyTorch universe without requiring on-device conversion. Intended for
/// researchers who already have a training pipeline set up — they point
/// the classifier at a script like:
///
/// ```python
/// # classifier_cli.py
/// import json, sys, numpy as np, joblib
/// payload = json.load(sys.stdin)
/// vol   = np.array(payload["pixels"],
///                  dtype=np.float32).reshape(payload["shape"])
/// mask  = np.array(payload["mask"],   dtype=np.uint16).reshape(payload["shape"])
/// model = joblib.load(payload["modelPath"])
/// probs = model.predict_proba(features(vol, mask))[0]
/// print(json.dumps({
///     "classes":     ["benign", "malignant"],
///     "probabilities": probs.tolist(),
///     "rationale":   "pyradiomics + sklearn RF",
///     "features":    feats_dict
/// }))
/// ```
///
/// The protocol expects UTF-8 JSON on stdout with at least:
///   ```json
///   { "classes": [...], "probabilities": [...] }
///   ```
/// `rationale` and `features` are optional.
public final class SubprocessLesionClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    public struct Spec: Sendable {
        public var executablePath: String
        public var arguments: [String]
        /// Optional environment variables merged on top of the inherited
        /// env. Typical use: `PYTHONPATH` / `VIRTUAL_ENV`.
        public var environment: [String: String]
        /// Hard ceiling — if the subprocess hasn't produced output by now,
        /// we kill it and raise `.inferenceFailed("timeout")`.
        public var timeoutSeconds: TimeInterval
        /// Include raw voxel pixels in the stdin payload. Turn off (and
        /// pass a file path via `arguments`) if your script prefers to
        /// read from disk for very large VOIs.
        public var sendPixelsOverStdin: Bool

        public init(executablePath: String,
                    arguments: [String] = [],
                    environment: [String: String] = [:],
                    timeoutSeconds: TimeInterval = 120,
                    sendPixelsOverStdin: Bool = true) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.timeoutSeconds = timeoutSeconds
            self.sendPixelsOverStdin = sendPixelsOverStdin
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "") {
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
        guard FileManager.default.isExecutableFile(atPath: spec.executablePath) else {
            throw ClassificationError.modelUnavailable(
                "No executable at \(spec.executablePath)"
            )
        }

        let start = Date()

        // 1. Crop the VOI to keep the JSON payload small.
        let crop = MONAITransforms.crop(volume, to: bounds)
        let maskVoxels = Self.cropMaskVoxels(mask: mask, classID: classID, bounds: bounds)
        let payload: [String: Any] = [
            "shape": [crop.depth, crop.height, crop.width],
            "spacing": [crop.spacing.x, crop.spacing.y, crop.spacing.z],
            "modality": crop.modality,
            "classID": Int(classID),
            "bounds": [
                "minX": bounds.minX, "maxX": bounds.maxX,
                "minY": bounds.minY, "maxY": bounds.maxY,
                "minZ": bounds.minZ, "maxZ": bounds.maxZ
            ],
            "pixels": spec.sendPixelsOverStdin ? crop.pixels.map { Double($0) } : [],
            "mask": spec.sendPixelsOverStdin ? maskVoxels : []
        ]
        let stdinData = try JSONSerialization.data(withJSONObject: payload)

        // 2. Spawn the process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            throw ClassificationError.inferenceFailed(
                "launch failed: \(error.localizedDescription)"
            )
        }

        // Feed payload, close stdin.
        try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
        try stdinPipe.fileHandleForWriting.close()

        let timedOut = await ProcessWaiter.wait(
            for: process,
            timeoutSeconds: spec.timeoutSeconds
        )

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let stdoutData = stdoutBuffer.data()
        let stderr = stderrBuffer.string()

        if timedOut {
            throw ClassificationError.inferenceFailed(
                "subprocess timed out after \(Int(spec.timeoutSeconds))s\(stderr.isEmpty ? "" : ": \(stderr)")"
            )
        }

        guard process.terminationStatus == 0 else {
            throw ClassificationError.inferenceFailed(
                "subprocess exited \(process.terminationStatus): \(stderr)"
            )
        }

        // 3. Parse the response JSON.
        guard let obj = try? JSONSerialization.jsonObject(with: stdoutData),
              let dict = obj as? [String: Any] else {
            throw ClassificationError.inferenceFailed(
                "subprocess produced non-JSON output: \(String(data: stdoutData, encoding: .utf8) ?? "<binary>")"
            )
        }
        guard let classes = dict["classes"] as? [String],
              let probs = dict["probabilities"] as? [Double],
              classes.count == probs.count else {
            throw ClassificationError.inferenceFailed(
                "subprocess JSON missing `classes` / `probabilities` arrays or they differ in length"
            )
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

    private static func cropMaskVoxels(mask: LabelMap,
                                       classID: UInt16,
                                       bounds: MONAITransforms.VoxelBounds) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(bounds.width * bounds.height * bounds.depth)
        for z in bounds.minZ...bounds.maxZ {
            for y in bounds.minY...bounds.maxY {
                let rowStart = z * mask.height * mask.width + y * mask.width
                for x in bounds.minX...bounds.maxX {
                    out.append(mask.voxels[rowStart + x] == classID ? 1 : 0)
                }
            }
        }
        return out
    }
}
