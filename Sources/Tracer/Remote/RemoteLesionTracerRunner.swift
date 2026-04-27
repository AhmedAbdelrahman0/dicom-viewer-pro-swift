import Foundation
import SwiftUI

/// DGX-backed runner for the legacy PET Segmentator / LesionTracer workflow.
///
/// This is intentionally separate from `RemoteNNUnetRunner`: the absorbed
/// Segmentator app used a model-folder entry point, a custom nnU-Net source
/// tree, a PyTorch 2.6+ checkpoint compatibility patch, and CT + SUV channels.
/// Keeping those assumptions in one runner makes the production path explicit
/// while the generic runner remains suitable for stock `nnUNetv2_predict`.
public final class RemoteLesionTracerRunner: @unchecked Sendable {

    public struct Configuration: Sendable {
        public static let defaultSourcePath = "/home/ahmed/tracer-registry/sources/autopet-3-nnunet"
        public static let defaultModelFolder = "/home/ahmed/tracer-registry/models/lesiontracer-autopetiii/Dataset222_AutoPETIII_2024/autoPET3_Trainer__nnUNetResEncUNetLPlansMultiTalent__3d_fullres_bs3"
        public static let defaultWorkerImage = "tracer-lesiontracer:latest"
        public static let defaultBaseImage = "nvcr.io/nvidia/pytorch:25.03-py3"

        public var dgx: DGXSparkConfig
        public var sourcePath: String
        public var modelFolder: String
        public var workerImage: String
        public var baseImage: String
        public var folds: [String]
        public var disableTestTimeAugmentation: Bool
        public var timeoutSeconds: TimeInterval
        public var bootstrapWorkerImage: Bool
        public var removeRemoteScratch: Bool

        public init(dgx: DGXSparkConfig,
                    sourcePath: String? = nil,
                    modelFolder: String? = nil,
                    workerImage: String? = nil,
                    baseImage: String? = nil,
                    folds: [String] = ["0", "1", "2", "3", "4"],
                    disableTestTimeAugmentation: Bool = true,
                    timeoutSeconds: TimeInterval = 7200,
                    bootstrapWorkerImage: Bool = true,
                    removeRemoteScratch: Bool = true) {
            self.dgx = dgx
            self.sourcePath = Self.nonEmpty(sourcePath) ?? Self.nonEmpty(dgx.remoteSegmentatorSourcePath) ?? Self.defaultSourcePath
            self.modelFolder = Self.nonEmpty(modelFolder) ?? Self.nonEmpty(dgx.remoteSegmentatorModelFolder) ?? Self.defaultModelFolder
            self.workerImage = Self.nonEmpty(workerImage) ?? Self.nonEmpty(dgx.remoteSegmentatorWorkerImage) ?? Self.defaultWorkerImage
            self.baseImage = Self.nonEmpty(baseImage) ?? Self.nonEmpty(dgx.remoteSegmentatorBaseImage) ?? Self.defaultBaseImage
            self.folds = folds
            self.disableTestTimeAugmentation = disableTestTimeAugmentation
            self.timeoutSeconds = timeoutSeconds
            self.bootstrapWorkerImage = bootstrapWorkerImage
            self.removeRemoteScratch = removeRemoteScratch
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case cancelled
        case geometryMismatch(String)
        case missingRemoteOutput(String)
        case remoteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "DGX Spark is not configured. Settings -> DGX Spark."
            case .cancelled:
                return "LesionTracer inference was cancelled."
            case .geometryMismatch(let message):
                return "LesionTracer input geometry mismatch: \(message)"
            case .missingRemoteOutput(let path):
                return "LesionTracer produced no output at \(path)."
            case .remoteFailed(let message):
                return "LesionTracer DGX run failed: \(message)"
            }
        }
    }

    public struct InferenceResult: @unchecked Sendable {
        public let labelMap: LabelMap
        public let durationSeconds: TimeInterval
        public let postprocess: PETLesionPostprocessor.Result?
        public let stderr: String
    }

    public private(set) var configuration: Configuration
    private let lock = NSLock()
    private var cancelled = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func resetCancel() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Runs the absorbed Segmentator LesionTracer model.
    ///
    /// `ctVolume` must be the reference grid and `petSUVVolume` must already
    /// be SUV-scaled. This preserves the single source of truth for SUV
    /// transforms in `PETEngineViewModel`.
    public func runInference(ctVolume: ImageVolume,
                             petSUVVolume: ImageVolume,
                             minimumSUV: Double,
                             minimumVolumeML: Double,
                             logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InferenceResult {
        guard configuration.dgx.isConfigured else { throw Error.notConfigured }
        resetCancel()

        for (idx, channel) in [ctVolume, petSUVVolume].enumerated() {
            if let mismatch = NNUnetRunner.gridMismatchDescription(channel,
                                                                   reference: ctVolume,
                                                                   channelIndex: idx) {
                throw Error.geometryMismatch(mismatch)
            }
        }

        let runID = "lesiontracer-\(UUID().uuidString.prefix(8))"
        let caseID = "case001"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(runID)-local", isDirectory: true)
        let localIn = localRoot.appendingPathComponent("input", isDirectory: true)
        let localOut = localRoot.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: localIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localOut, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        try NIfTIWriter.write(ctVolume, to: localIn.appendingPathComponent("\(caseID)_0000.nii"))
        try NIfTIWriter.write(petSUVVolume, to: localIn.appendingPathComponent("\(caseID)_0001.nii"))

        let dockerfileURL = localRoot.appendingPathComponent("LesionTracer.Dockerfile")
        try dockerfile().data(using: .utf8)?.write(to: dockerfileURL, options: [.atomic])
        let predictURL = localRoot.appendingPathComponent("run_predict.py")
        try predictScript(caseID: caseID).data(using: .utf8)?.write(to: predictURL, options: [.atomic])
        let launchURL = localRoot.appendingPathComponent("run_lesiontracer.sh")
        try launchScript().data(using: .utf8)?.write(to: launchURL, options: [.atomic])

        let executor = RemoteExecutor(config: configuration.dgx)
        let remoteBase = "\(configuration.dgx.remoteWorkdir)/\(runID)"
        let remoteIn = "\(remoteBase)/input"
        let remoteOut = "\(remoteBase)/results"
        defer {
            if configuration.removeRemoteScratch {
                executor.remove(remoteBase)
            }
        }

        if isCancelled { throw Error.cancelled }
        logSink("Staging CT + PET SUV channels to \(configuration.dgx.sshDestination):\(remoteBase)\n")
        try executor.ensureRemoteDirectory(remoteBase)
        try executor.uploadDirectory(localIn, toRemote: remoteIn)
        try executor.uploadFile(dockerfileURL, toRemote: "\(remoteBase)/LesionTracer.Dockerfile")
        try executor.uploadFile(predictURL, toRemote: "\(remoteBase)/run_predict.py")
        try executor.uploadFile(launchURL, toRemote: "\(remoteBase)/run_lesiontracer.sh")
        if isCancelled { throw Error.cancelled }

        let command = "bash \(RemoteExecutor.shellEscape("\(remoteBase)/run_lesiontracer.sh"))"
        let started = Date()
        let result: RemoteExecutor.RunResult
        do {
            result = try executor.run(command,
                                      timeoutSeconds: configuration.timeoutSeconds,
                                      logSink: logSink)
        } catch let error as RemoteExecutor.Error {
            throw Error.remoteFailed(error.localizedDescription)
        } catch {
            throw Error.remoteFailed(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(started)
        if isCancelled { throw Error.cancelled }
        guard result.exitCode == 0 else {
            throw Error.remoteFailed(result.stderr)
        }

        let remoteOutputGz = "\(remoteOut)/\(caseID).nii.gz"
        let remoteOutputNii = "\(remoteOut)/\(caseID).nii"
        let localOutputGz = localOut.appendingPathComponent("\(caseID).nii.gz")
        let localOutputNii = localOut.appendingPathComponent("\(caseID).nii")
        let labelURL: URL
        do {
            try executor.downloadFile(remoteOutputGz, toLocal: localOutputGz)
            labelURL = localOutputGz
        } catch {
            do {
                try executor.downloadFile(remoteOutputNii, toLocal: localOutputNii)
                labelURL = localOutputNii
            } catch {
                throw Error.missingRemoteOutput(remoteOutputGz)
            }
        }

        let labelMap = try LabelIO.loadNIfTILabelmap(from: labelURL, parentVolume: ctVolume)
        labelMap.name = "LesionTracer DGX"
        applyLesionClass(to: labelMap)
        let postprocess = try? PETLesionPostprocessor.filterComponentsBySUV(
            labelMap: labelMap,
            petSUVVolume: petSUVVolume,
            classID: 1,
            minimumSUV: minimumSUV,
            minimumVolumeML: minimumVolumeML
        )

        return InferenceResult(labelMap: labelMap,
                               durationSeconds: elapsed,
                               postprocess: postprocess,
                               stderr: result.stderr)
    }

    private func applyLesionClass(to labelMap: LabelMap) {
        if let index = labelMap.classes.firstIndex(where: { $0.labelID == 1 }) {
            labelMap.classes[index].name = "PET lesion"
            labelMap.classes[index].category = .petHotspot
            labelMap.classes[index].color = .red
            labelMap.classes[index].opacity = 0.55
        } else if labelMap.voxels.contains(1) {
            labelMap.classes.append(LabelClass(labelID: 1,
                                               name: "PET lesion",
                                               category: .petHotspot,
                                               color: .red,
                                               opacity: 0.55))
        }
    }

    private func dockerfile() -> String {
        """
        FROM \(configuration.baseImage)

        ENV PYTHONUNBUFFERED=1 \\
            PIP_NO_CACHE_DIR=1

        RUN python3 -m pip install -q "setuptools<77" wheel && \\
            python3 -m pip install --no-build-isolation --no-cache-dir -q \\
              "dynamic-network-architectures>=0.3.1,<0.4" \\
              "acvl-utils==0.2.5" \\
              batchgenerators \\
              batchgeneratorsv2 \\
              SimpleITK \\
              scikit-image \\
              einops \\
              nibabel \\
              pandas \\
              tqdm \\
              dicom2nifti \\
              imagecodecs \\
              yacs \\
              graphviz \\
              seaborn

        WORKDIR /workspace
        ENTRYPOINT []
        """
    }

    private func predictScript(caseID: String) -> String {
        let folds = configuration.folds.map { "\"\($0)\"" }.joined(separator: ", ")
        let tta = configuration.disableTestTimeAugmentation ? "\"--disable_tta\"," : ""
        return """
        import argparse
        import sys
        import torch


        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("--input", required=True)
            parser.add_argument("--output", required=True)
            parser.add_argument("--model", required=True)
            args = parser.parse_args()

            original_load = torch.load

            def patched_load(*load_args, **kwargs):
                kwargs.setdefault("weights_only", False)
                return original_load(*load_args, **kwargs)

            torch.load = patched_load
            sys.argv = [
                "nnUNetv2_predict_from_modelfolder",
                "-i", args.input,
                "-o", args.output,
                "-m", args.model,
                "-f", \(folds),
                \(tta)
                "--disable_progress_bar",
                "-npp", "1",
                "-nps", "1",
                "-device", "cuda",
            ]
            from nnunetv2.inference.predict_from_raw_data import predict_entry_point_modelfolder
            predict_entry_point_modelfolder()


        if __name__ == "__main__":
            main()
        """
    }

    private func launchScript() -> String {
        let remoteBase = "$CASE_DIR"
        let escapedWorkerImage = RemoteExecutor.shellEscape(configuration.workerImage)
        let escapedSource = RemoteExecutor.shellEscape(configuration.sourcePath)
        let escapedModel = RemoteExecutor.shellEscape(configuration.modelFolder)
        let escapedBase = RemoteExecutor.shellEscape(configuration.baseImage)
        let escapedBootstrap = configuration.bootstrapWorkerImage ? "1" : "0"
        return """
        #!/usr/bin/env bash
        set -euo pipefail

        CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
        INPUT_DIR="$CASE_DIR/input"
        OUTPUT_DIR="$CASE_DIR/results"
        SOURCE_PATH=\(escapedSource)
        MODEL_FOLDER=\(escapedModel)
        WORKER_IMAGE=\(escapedWorkerImage)
        BASE_IMAGE=\(escapedBase)
        BOOTSTRAP_IMAGE=\(escapedBootstrap)

        mkdir -p "$OUTPUT_DIR"
        echo "=== Tracer LesionTracer DGX run ==="
        date
        echo "Input: $INPUT_DIR"
        echo "Output: $OUTPUT_DIR"
        echo "Source: $SOURCE_PATH"
        echo "Model: $MODEL_FOLDER"
        echo "Worker image: $WORKER_IMAGE"
        ls -lh "$INPUT_DIR"

        test -d "$SOURCE_PATH"
        test -d "$MODEL_FOLDER"

        if [ "$BOOTSTRAP_IMAGE" = "1" ] && ! docker image inspect "$WORKER_IMAGE" >/dev/null 2>&1; then
          echo "Building reusable LesionTracer worker image from $BASE_IMAGE..."
          docker build --pull=false -t "$WORKER_IMAGE" -f "$CASE_DIR/LesionTracer.Dockerfile" "$CASE_DIR"
        fi

        echo "CUDA check and inference..."
        docker run --rm --gpus all --ipc=host \\
          --ulimit memlock=-1 --ulimit stack=67108864 --shm-size=64g \\
          -v "$INPUT_DIR:/workspace/input" \\
          -v "$OUTPUT_DIR:/workspace/results" \\
          -v "$MODEL_FOLDER:/workspace/model:ro" \\
          -v "$SOURCE_PATH:/workspace/nnunet_code:ro" \\
          -v "\(remoteBase):/workspace/case" \\
          "$WORKER_IMAGE" \\
          bash -lc '
            set -euo pipefail
            export PYTHONUNBUFFERED=1
            export PYTHONPATH=/workspace/nnunet_code:${PYTHONPATH:-}
            export nnUNet_results=/workspace
            export nnUNet_raw=/workspace/input
            export nnUNet_preprocessed=/workspace/input
            python3 - <<PY2
        import torch
        print("torch", torch.__version__)
        print("cuda", torch.cuda.is_available())
        print("device", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none")
        PY2
            python3 /workspace/case/run_predict.py \\
              --input /workspace/input \\
              --output /workspace/results \\
              --model /workspace/model
          '

        echo "=== Complete ==="
        date
        ls -lh "$OUTPUT_DIR"
        """
    }
}
