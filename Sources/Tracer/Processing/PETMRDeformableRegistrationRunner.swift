import Foundation
import simd

public enum PETMRDeformableBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case internalBodyEnvelope
    case simpleITKMI
    case brainsFit
    case itkSnapGreedy
    case antsSyN
    case synthMorph
    case voxelMorph
    case customScript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .internalBodyEnvelope: return "Internal body warp"
        case .simpleITKMI: return "SimpleITK MI"
        case .brainsFit: return "3D Slicer BRAINSFit"
        case .itkSnapGreedy: return "ITK-SNAP Greedy"
        case .antsSyN: return "ANTs SyN"
        case .synthMorph: return "SynthMorph"
        case .voxelMorph: return "VoxelMorph"
        case .customScript: return "Custom script"
        }
    }

    public var needsExternalRunner: Bool {
        self != .internalBodyEnvelope
    }

    public var defaultExecutableName: String {
        switch self {
        case .internalBodyEnvelope: return ""
        case .simpleITKMI: return "python3"
        case .brainsFit:
            let slicerPath = "/Applications/Slicer.app/Contents/lib/Slicer-5.10/cli-modules/BRAINSFit"
            return FileManager.default.isExecutableFile(atPath: slicerPath) ? slicerPath : "BRAINSFit"
        case .itkSnapGreedy:
            let itkSnapPath = "/Applications/ITK-SNAP.app/Contents/bin/greedy"
            return FileManager.default.isExecutableFile(atPath: itkSnapPath) ? itkSnapPath : "greedy"
        case .antsSyN: return "antsRegistration"
        case .synthMorph: return "mri_synthmorph"
        case .voxelMorph: return "python3"
        case .customScript: return ""
        }
    }

    public var adapterHelp: String {
        switch self {
        case .internalBodyEnvelope:
            return "Uses Tracer's built-in body-envelope alignment. No external tools required."
        case .simpleITKMI:
            return "Runs a local Python SimpleITK Mattes mutual-information rigid precision-polish after PET has been prealigned to the MR grid. Add --allow-scale in extra args only when scale is intentional."
        case .brainsFit:
            return "Runs 3D Slicer's BRAINSFit on Tracer's staged orthonormal PET/MR grid. Best used as a rigid, brain-cropped multimodal refinement candidate."
        case .itkSnapGreedy:
            return "Runs ITK-SNAP's Greedy affine plus stationary-velocity deformable refinement on Tracer's staged PET/MR grid, then QA-selects the result against the other candidates."
        case .antsSyN:
            return "Runs antsRegistration with rigid/affine/SyN stages and reads the warped PET NIfTI output."
        case .synthMorph:
            return "Runs a SynthMorph-compatible wrapper. The app passes --fixed, --moving, --output, --transform, and optional --model."
        case .voxelMorph:
            return "Runs a VoxelMorph-compatible Python wrapper. The app passes --fixed, --moving, --output, --transform, and optional --model."
        case .customScript:
            return "Runs any executable that accepts --fixed, --moving, --output, --transform, and optional --model."
        }
    }
}

public enum PETMRRegistrationMetricPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case multimodalMI
    case sameContrastCC
    case hybridMIAndCC

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .multimodalMI: return "Multimodal MI"
        case .sameContrastCC: return "Same-contrast CC"
        case .hybridMIAndCC: return "Hybrid MI + CC"
        }
    }

    public var helpText: String {
        switch self {
        case .multimodalMI:
            return "Mutual information for PET/MR, CT/MR, and other cross-modality registration."
        case .sameContrastCC:
            return "Local cross-correlation for same-modality or similar-contrast images."
        case .hybridMIAndCC:
            return "Uses mutual information plus cross-correlation when the modalities share enough anatomy."
        }
    }
}

public struct PETMRDeformableRegistrationConfiguration: Equatable, Sendable {
    public var backend: PETMRDeformableBackend
    public var executablePath: String
    public var modelPath: String
    public var extraArguments: String
    public var timeoutSeconds: Double
    public var metricPreset: PETMRRegistrationMetricPreset

    public init(backend: PETMRDeformableBackend = .simpleITKMI,
                executablePath: String = "",
                modelPath: String = "",
                extraArguments: String = "",
                timeoutSeconds: Double = 900,
                metricPreset: PETMRRegistrationMetricPreset = .multimodalMI) {
        self.backend = backend
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.extraArguments = extraArguments
        self.timeoutSeconds = timeoutSeconds
        self.metricPreset = metricPreset
    }

    public var isExternalConfigured: Bool {
        guard backend.needsExternalRunner else { return false }
        return !resolvedExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var resolvedExecutable: String {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? backend.defaultExecutableName : trimmed
    }

    public var readinessMessage: String {
        if !backend.needsExternalRunner {
            return "Internal body-envelope fallback is ready."
        }
        let exe = resolvedExecutable
        guard !exe.isEmpty else {
            return "\(backend.displayName) needs an executable or wrapper path."
        }
        if exe.contains("/") && !FileManager.default.isExecutableFile(atPath: exe) {
            return "\(backend.displayName) executable is not runnable: \(exe)"
        }
        if backend == .simpleITKMI {
            return "SimpleITK MI will run via \(exe). Requires the Python SimpleITK package."
        }
        if backend == .brainsFit {
            return "BRAINSFit will run via \(exe). Requires 3D Slicer or BRAINSFit on PATH."
        }
        if backend == .itkSnapGreedy {
            return "ITK-SNAP Greedy will run via \(exe). Requires ITK-SNAP's greedy executable or greedy on PATH."
        }
        return "\(backend.displayName) will run via \(exe)."
    }
}

public struct PETMRDeformableRegistrationResult: Sendable {
    public let warpedMoving: ImageVolume
    public let backend: PETMRDeformableBackend
    public let note: String
    public let stdout: String
    public let stderr: String
    public let durationSeconds: Double
    public let deformationQuality: DeformationFieldQuality?
}

public enum PETMRDeformableRegistrationError: Error, LocalizedError {
    case notConfigured(String)
    case launchFailed(String)
    case timedOut(Double, String)
    case failed(exitCode: Int32, stderr: String)
    case cancelled
    case outputMissing(String)
    case outputLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .launchFailed(let message):
            return "Could not launch deformable registration: \(message)"
        case .timedOut(let timeout, let stderr):
            return "Deformable registration timed out after \(Int(timeout))s\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .failed(let exitCode, let stderr):
            return "Deformable registration exited \(exitCode): \(stderr.isEmpty ? "<no stderr>" : stderr)"
        case .cancelled:
            return "Deformable registration was cancelled."
        case .outputMissing(let path):
            return "Deformable registration did not produce output: \(path)"
        case .outputLoadFailed(let message):
            return "Could not load deformable output: \(message)"
        }
    }
}

public enum PETMRDeformableRegistrationRunner {

    public static func register(fixed: ImageVolume,
                                movingPrealigned: ImageVolume,
                                configuration: PETMRDeformableRegistrationConfiguration) async throws -> PETMRDeformableRegistrationResult {
        guard configuration.backend.needsExternalRunner else {
            throw PETMRDeformableRegistrationError.notConfigured("Internal body-envelope mode does not launch an external runner.")
        }
        guard configuration.isExternalConfigured else {
            throw PETMRDeformableRegistrationError.notConfigured(configuration.readinessMessage)
        }

        let start = Date()
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("TracerPETMRRegistration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let stage = externalRegistrationStage(fixed: fixed, movingPrealigned: movingPrealigned)

        let fixedURL = workDir.appendingPathComponent("fixed_mr.nii")
        let movingURL = workDir.appendingPathComponent("moving_pet_prealigned.nii")
        let warpedURL = workDir.appendingPathComponent("warped_pet.nii")
        let transformURL = workDir.appendingPathComponent("deformable_transform.tfm")
        let qaURL = workDir.appendingPathComponent("registration_qa.json")

        try NIfTIWriter.writeFloat32(stage.fixedForExternal, to: fixedURL)
        try NIfTIWriter.writeFloat32(stage.movingForExternal, to: movingURL)

        let command = try commandLine(configuration: configuration,
                                      fixedURL: fixedURL,
                                      movingURL: movingURL,
                                      warpedURL: warpedURL,
                                      transformURL: transformURL,
                                      qaURL: qaURL,
                                      workDir: workDir)
        let output = try await run(command: command,
                                   workDir: workDir,
                                   timeoutSeconds: configuration.timeoutSeconds)

        guard fm.fileExists(atPath: warpedURL.path) else {
            throw PETMRDeformableRegistrationError.outputMissing(warpedURL.path)
        }

        let warped: ImageVolume
        do {
            warped = try NIfTILoader.load(warpedURL, modalityHint: movingPrealigned.modality)
        } catch {
            throw PETMRDeformableRegistrationError.outputLoadFailed(error.localizedDescription)
        }
        let warpedOnFixedGrid: ImageVolume
        let gridNote: String
        if ImageVolumeGeometry.gridsMatch(stage.fixedForExternal, warped) {
            if let finalTarget = stage.finalTarget {
                warpedOnFixedGrid = VolumeResampler.resample(overlay: warped,
                                                             toMatch: finalTarget,
                                                             mode: .linear)
                gridNote = "; used orthonormal external staging and resampled output back to MR geometry"
            } else {
                warpedOnFixedGrid = warped
                gridNote = ""
            }
        } else {
            warpedOnFixedGrid = VolumeResampler.resample(overlay: warped, toMatch: fixed, mode: .linear)
            gridNote = "; output grid was resampled to fixed MR geometry"
        }
        let deformationQuality = RegistrationQualityAssurance.loadDeformationQualitySidecar(from: qaURL)
        let optimizerNote = optimizerSummary(from: deformationQuality?.notes ?? [])

        return PETMRDeformableRegistrationResult(
            warpedMoving: warpedOnFixedGrid,
            backend: configuration.backend,
            note: "\(configuration.backend.displayName) deformable registration finished in \(String(format: "%.1f", Date().timeIntervalSince(start)))s\(gridNote)\(optimizerNote)",
            stdout: output.stdout,
            stderr: output.stderr,
            durationSeconds: Date().timeIntervalSince(start),
            deformationQuality: deformationQuality
        )
    }

    private struct ExternalRegistrationStage {
        let fixedForExternal: ImageVolume
        let movingForExternal: ImageVolume
        let finalTarget: ImageVolume?
    }

    private static func externalRegistrationStage(fixed: ImageVolume,
                                                  movingPrealigned: ImageVolume) -> ExternalRegistrationStage {
        guard let externalGrid = orthonormalRegistrationGrid(for: fixed) else {
            return ExternalRegistrationStage(
                fixedForExternal: fixed,
                movingForExternal: movingPrealigned,
                finalTarget: nil
            )
        }

        let fixedForExternal = VolumeResampler.resample(source: fixed,
                                                        target: externalGrid,
                                                        mode: .linear)
        let movingForExternal = VolumeResampler.resample(source: movingPrealigned,
                                                         target: externalGrid,
                                                         mode: .linear)
        return ExternalRegistrationStage(
            fixedForExternal: fixedForExternal,
            movingForExternal: movingForExternal,
            finalTarget: fixed
        )
    }

    private static func orthonormalRegistrationGrid(for fixed: ImageVolume) -> ImageVolume? {
        guard !directionIsOrthonormal(fixed.direction) else { return nil }
        let direction = orthonormalizedDirection(fixed.direction)
        let centerVoxel = SIMD3<Double>(
            Double(max(0, fixed.width - 1)) / 2,
            Double(max(0, fixed.height - 1)) / 2,
            Double(max(0, fixed.depth - 1)) / 2
        )
        let centerWorld = fixed.worldPoint(voxel: centerVoxel)
        let centerOffset = direction * SIMD3<Double>(
            centerVoxel.x * fixed.spacing.x,
            centerVoxel.y * fixed.spacing.y,
            centerVoxel.z * fixed.spacing.z
        )
        let origin = centerWorld - centerOffset
        return ImageVolume(
            pixels: [Float](repeating: 0, count: fixed.width * fixed.height * fixed.depth),
            depth: fixed.depth,
            height: fixed.height,
            width: fixed.width,
            spacing: (fixed.spacing.x, fixed.spacing.y, fixed.spacing.z),
            origin: (origin.x, origin.y, origin.z),
            direction: direction,
            modality: fixed.modality,
            seriesUID: fixed.seriesUID + "_external_orthonormal_grid",
            studyUID: fixed.studyUID,
            patientID: fixed.patientID,
            patientName: fixed.patientName,
            seriesDescription: fixed.seriesDescription + " (external orthonormal grid)",
            studyDescription: fixed.studyDescription,
            suvScaleFactor: fixed.suvScaleFactor,
            sourceFiles: fixed.sourceFiles
        )
    }

    private static func directionIsOrthonormal(_ direction: simd_double3x3,
                                               tolerance: Double = 1e-4) -> Bool {
        let columns = [direction[0], direction[1], direction[2]]
        for column in columns where abs(simd_length(column) - 1) > tolerance {
            return false
        }
        for lhs in 0..<3 {
            for rhs in (lhs + 1)..<3 where abs(simd_dot(columns[lhs], columns[rhs])) > tolerance {
                return false
            }
        }
        return true
    }

    private static func orthonormalizedDirection(_ direction: simd_double3x3) -> simd_double3x3 {
        let x = normalized(direction[0], fallback: SIMD3<Double>(1, 0, 0))
        var y = direction[1] - x * simd_dot(direction[1], x)
        y = normalized(y, fallback: orthogonalFallback(to: x))
        var z = simd_cross(x, y)
        z = normalized(z, fallback: direction[2])
        if simd_dot(z, direction[2]) < 0 {
            z = -z
        }
        y = simd_cross(z, x)
        if simd_dot(y, direction[1]) < 0 {
            y = -y
            z = -z
        }
        return simd_double3x3(x, y, z)
    }

    private static func orthogonalFallback(to x: SIMD3<Double>) -> SIMD3<Double> {
        let candidate = abs(x.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        return normalized(candidate - x * simd_dot(candidate, x), fallback: SIMD3<Double>(0, 1, 0))
    }

    private static func normalized(_ vector: SIMD3<Double>,
                                   fallback: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(vector)
        guard length.isFinite, length > 1e-12 else { return fallback }
        return vector / length
    }

    private static func optimizerSummary(from notes: [String]) -> String {
        func value(prefix: String) -> String? {
            notes.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }

        var parts: [String] = []
        if let iterations = value(prefix: "optimizerIterations=") {
            parts.append("iterations \(iterations)")
        }
        if let attempt = value(prefix: "maskAttempt=") {
            parts.append("attempt \(attempt)")
        }
        if let metric = value(prefix: "metricValue=") {
            parts.append("metric \(metric)")
        }
        guard !parts.isEmpty else { return "" }
        return "; " + parts.joined(separator: ", ")
    }

    private struct CommandLine {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private static func commandLine(configuration: PETMRDeformableRegistrationConfiguration,
                                    fixedURL: URL,
                                    movingURL: URL,
                                    warpedURL: URL,
                                    transformURL: URL,
                                    qaURL: URL,
                                    workDir: URL) throws -> CommandLine {
        let exe = configuration.resolvedExecutable
        let fixed = fixedURL.path
        let moving = movingURL.path
        let warped = warpedURL.path
        let transform = transformURL.path
        let extra = shellLikeSplit(configuration.extraArguments)

        switch configuration.backend {
        case .simpleITKMI:
            let scriptURL = workDir.appendingPathComponent("simpleitk_petmr_registration.py")
            try simpleITKRegistrationScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            var environment = ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            environment["ITK_NIFTI_SFORM_PERMISSIVE"] = "1"
            environment["PYTHONUNBUFFERED"] = "1"
            return CommandLine(
                executable: exe,
                arguments: [
                    scriptURL.path,
                    "--fixed", fixed,
                    "--moving", moving,
                    "--output", warped,
                    "--transform", transform,
                    "--qa", qaURL.path,
                    "--metric", configuration.metricPreset.rawValue
                ] + extra,
                environment: environment
            )

        case .brainsFit:
            return CommandLine(
                executable: exe,
                arguments: [
                    "--fixedVolume", fixed,
                    "--movingVolume", moving,
                    "--outputVolume", warped,
                    "--outputTransform", transform,
                    "--transformType", "Rigid",
                    "--initializeTransformMode", "Off",
                    "--maskProcessingMode", "ROIAUTO",
                    "--ROIAutoDilateSize", "4",
                    "--costMetric", brainsFitCostMetric(configuration.metricPreset),
                    "--numberOfSamples", "200000",
                    "--numberOfHistogramBins", "64",
                    "--numberOfIterations", "1500",
                    "--maximumStepLength", "0.20",
                    "--minimumStepLength", "0.005",
                    "--interpolationMode", "Linear",
                    "--outputVolumePixelType", "float",
                    "--failureExitCode", "0",
                    "--writeTransformOnFailure"
                ] + extra,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .itkSnapGreedy:
            let affineURL = workDir.appendingPathComponent("greedy_affine.mat")
            let warpURL = workDir.appendingPathComponent("greedy_warp.nii")
            let scriptURL = workDir.appendingPathComponent("greedy_petmr_registration.sh")
            let threads = max(1, ResourcePolicy.load().cpuWorkerLimit)
            let metric = greedyMetric(configuration.metricPreset)
            let extraText = extra.map(shellQuote).joined(separator: " ")
            let extraLine = extraText.isEmpty ? "" : " \(extraText)"
            let script = """
            #!/bin/zsh
            set -euo pipefail
            GREEDY=\(shellQuote(exe))
            FIXED=\(shellQuote(fixed))
            MOVING=\(shellQuote(moving))
            AFFINE=\(shellQuote(affineURL.path))
            WARP=\(shellQuote(warpURL.path))
            WARPED=\(shellQuote(warped))
            QA=\(shellQuote(qaURL.path))
            START=$(date +%s)
            "$GREEDY" -d 3 -float -a -m \(metric) -i "$FIXED" "$MOVING" -o "$AFFINE" -dof 7 -ia-identity -n 100x50x20 -e 0.25x0.1x0.05 -threads \(threads) -V 1\(extraLine)
            "$GREEDY" -d 3 -float -m \(metric) -i "$FIXED" "$MOVING" -it "$AFFINE" -o "$WARP" -n 60x30x10 -e 0.35x0.18x0.08 -s 2mm 1mm -sv -threads \(threads) -V 1\(extraLine)
            "$GREEDY" -d 3 -float -rf "$FIXED" -ri LINEAR -rt float -rm "$MOVING" "$WARPED" -r "$WARP" "$AFFINE" -threads \(threads) -V 0
            DURATION=$(($(date +%s)-START))
            python3 - <<PY
            import json
            with open(r"$QA", "w", encoding="utf-8") as handle:
                json.dump({"notes": [
                    "ITK-SNAP Greedy affine+SV deformable refinement",
                    "metric=\(metric)",
                    "transform=GreedyDOF7+SV",
                    "durationSeconds=" + str($DURATION)
                ]}, handle, indent=2)
            PY
            echo "ITK-SNAP Greedy PET/MR registration complete"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return CommandLine(
                executable: "/bin/zsh",
                arguments: [scriptURL.path],
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .antsSyN:
            let prefix = workDir.appendingPathComponent("ants_").path
            let synMetric = antsSyNMetricArguments(configuration.metricPreset, fixed: fixed, moving: moving)
            return CommandLine(
                executable: exe,
                arguments: [
                    "--dimensionality", "3",
                    "--float", "1",
                    "--interpolation", "Linear",
                    "--output", "[\(prefix),\(warped)]",
                    "--initial-moving-transform", "[\(fixed),\(moving),1]",
                    "--transform", "Rigid[0.1]",
                    "--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]",
                    "--convergence", "[100x50x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox",
                    "--transform", "Affine[0.1]",
                    "--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]",
                    "--convergence", "[100x50x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox",
                    "--transform", "SyN[0.08,3,0]",
                ] + synMetric + [
                    "--convergence", "[60x40x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox"
                ] + extra,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .synthMorph, .voxelMorph, .customScript:
            var args = [
                "--fixed", fixed,
                "--moving", moving,
                "--output", warped,
                "--transform", transform
            ]
            let model = configuration.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                args += ["--model", model]
            }
            args += extra
            return CommandLine(
                executable: exe,
                arguments: args,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .internalBodyEnvelope:
            return CommandLine(executable: "", arguments: [], environment: [:])
        }
    }

    private static func brainsFitCostMetric(_ preset: PETMRRegistrationMetricPreset) -> String {
        switch preset {
        case .sameContrastCC:
            return "NC"
        case .multimodalMI, .hybridMIAndCC:
            return "MMI"
        }
    }

    private static func greedyMetric(_ preset: PETMRRegistrationMetricPreset) -> String {
        switch preset {
        case .sameContrastCC:
            return "NCC 4x4x4"
        case .multimodalMI, .hybridMIAndCC:
            return "NMI"
        }
    }

    private static func antsSyNMetricArguments(_ preset: PETMRRegistrationMetricPreset,
                                               fixed: String,
                                               moving: String) -> [String] {
        switch preset {
        case .multimodalMI:
            return ["--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]"]
        case .sameContrastCC:
            return ["--metric", "CC[\(fixed),\(moving),1,4]"]
        case .hybridMIAndCC:
            return [
                "--metric", "MI[\(fixed),\(moving),0.7,32,Regular,0.25]",
                "--metric", "CC[\(fixed),\(moving),0.3,4]"
            ]
        }
    }

    private static let simpleITKRegistrationScript = #"""
import argparse
import json
import os
import sys
import time

import numpy as np
import SimpleITK as sitk


def robust_normalize(image, positive_only=False):
    arr = sitk.GetArrayViewFromImage(image)
    values = arr[np.isfinite(arr)]
    if positive_only:
        values = values[values > 0]
    if values.size < 32:
        values = arr[np.isfinite(arr)]
    if values.size == 0:
        return sitk.RescaleIntensity(image, 0, 1)
    lo = float(np.percentile(values, 0.5))
    hi = float(np.percentile(values, 99.5))
    if not np.isfinite(lo):
        lo = float(np.nanmin(values))
    if not np.isfinite(hi) or hi <= lo:
        hi = float(np.nanmax(values))
    if hi <= lo:
        hi = lo + 1.0
    return sitk.RescaleIntensity(sitk.Clamp(image, lowerBound=lo, upperBound=hi), 0, 1)


def registration_mask_or_none(image, threshold=0.035):
    mask = sitk.BinaryThreshold(image, lowerThreshold=threshold, upperThreshold=1.0, insideValue=1, outsideValue=0)
    mask = sitk.Cast(mask, sitk.sitkUInt8)
    voxels = int(np.count_nonzero(sitk.GetArrayViewFromImage(mask)))
    minimum = max(128, int(np.prod(image.GetSize()) * 0.0005))
    return mask if voxels >= minimum else None


def configured_registration(args, initial, fixed_mask, moving_mask, sampling, seed):
    registration = sitk.ImageRegistrationMethod()
    if args.metric == "sameContrastCC":
        registration.SetMetricAsCorrelation()
    else:
        registration.SetMetricAsMattesMutualInformation(numberOfHistogramBins=max(16, args.bins))
    registration.SetMetricSamplingStrategy(registration.RANDOM)
    registration.SetMetricSamplingPercentage(max(0.005, min(0.60, sampling)), seed=seed)
    if fixed_mask is not None:
        registration.SetMetricFixedMask(fixed_mask)
    if moving_mask is not None:
        registration.SetMetricMovingMask(moving_mask)
    registration.SetInterpolator(sitk.sitkLinear)
    registration.SetOptimizerAsGradientDescentLineSearch(
        learningRate=1.0,
        numberOfIterations=max(10, args.iterations),
        convergenceMinimumValue=1e-5,
        convergenceWindowSize=10,
    )
    registration.SetOptimizerScalesFromPhysicalShift()
    registration.SetShrinkFactorsPerLevel([6, 3, 1])
    registration.SetSmoothingSigmasPerLevel([3, 1, 0])
    registration.SmoothingSigmasAreSpecifiedInPhysicalUnitsOn()
    registration.SetInitialTransform(initial, inPlace=False)
    return registration


def main():
    parser = argparse.ArgumentParser(description="Tracer PET/MR SimpleITK registration worker")
    parser.add_argument("--fixed", required=True)
    parser.add_argument("--moving", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--transform", required=True)
    parser.add_argument("--qa", required=True)
    parser.add_argument("--metric", default="multimodalMI")
    parser.add_argument("--sampling", type=float, default=0.03)
    parser.add_argument("--iterations", type=int, default=80)
    parser.add_argument("--bins", type=int, default=48)
    parser.add_argument("--seed", type=int, default=13)
    parser.add_argument("--allow-scale", action="store_true")
    args, _ = parser.parse_known_args()

    os.environ.setdefault("ITK_NIFTI_SFORM_PERMISSIVE", "1")
    start = time.time()
    fixed = sitk.ReadImage(args.fixed, sitk.sitkFloat32)
    moving = sitk.ReadImage(args.moving, sitk.sitkFloat32)
    fixed_metric = robust_normalize(fixed, positive_only=True)
    moving_metric = robust_normalize(moving, positive_only=True)

    transform_type = sitk.Similarity3DTransform() if args.allow_scale else sitk.Euler3DTransform()
    initial = sitk.CenteredTransformInitializer(
        fixed_metric,
        moving_metric,
        transform_type,
        sitk.CenteredTransformInitializerFilter.GEOMETRY,
    )

    fixed_mask = registration_mask_or_none(fixed_metric)
    moving_mask = registration_mask_or_none(moving_metric)
    attempts = [
        ("fixed-mask", fixed_mask, None, max(args.sampling, 0.08)),
        ("unmasked-broad", None, None, max(args.sampling, 0.18)),
        ("fixed+moving-mask", fixed_mask, moving_mask, max(args.sampling, 0.12)),
    ]
    warnings = []
    registration = None
    final_transform = None
    winning_attempt = None
    for attempt_index, (name, attempt_fixed_mask, attempt_moving_mask, sampling) in enumerate(attempts):
        if attempt_fixed_mask is None and "fixed" in name:
            warnings.append(name + " skipped: fixed mask was empty")
            continue
        if attempt_moving_mask is None and "moving" in name:
            warnings.append(name + " skipped: moving mask was empty")
            continue
        registration = configured_registration(
            args,
            initial,
            attempt_fixed_mask,
            attempt_moving_mask,
            sampling,
            args.seed + attempt_index,
        )
        try:
            final_transform = registration.Execute(fixed_metric, moving_metric)
            winning_attempt = name
            break
        except Exception as exc:
            message = name + " failed: " + str(exc)
            warnings.append(message)
            print("SimpleITK retry:", message, file=sys.stderr)
    if final_transform is None or registration is None:
        raise RuntimeError("all SimpleITK PET/MR registration attempts failed: " + " | ".join(warnings))
    warped = sitk.Resample(moving, fixed, final_transform, sitk.sitkLinear, 0.0, sitk.sitkFloat32)
    sitk.WriteImage(warped, args.output)
    try:
        sitk.WriteTransform(final_transform, args.transform)
    except Exception as exc:
        with open(args.transform, "w", encoding="utf-8") as handle:
            handle.write(str(final_transform))
            handle.write("\n")
            handle.write(str(exc))

    report = {
        "notes": [
            "SimpleITK rigid precision-polish",
            "metric=" + args.metric,
            "transform=" + ("Similarity3D" if args.allow_scale else "Euler3D"),
            "maskAttempt=" + str(winning_attempt),
            "optimizerIterations=" + str(registration.GetOptimizerIteration()),
            "metricValue=" + str(registration.GetMetricValue()),
            "durationSeconds=" + format(time.time() - start, ".3f"),
        ] + warnings
    }
    with open(args.qa, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
    print("SimpleITK PET/MR registration complete")
    print("metric", registration.GetMetricValue(), "iterations", registration.GetOptimizerIteration())


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("SimpleITK PET/MR registration failed:", exc, file=sys.stderr)
        raise
"""#

    private static func run(command: CommandLine,
                            workDir: URL,
                            timeoutSeconds: Double) async throws -> (stdout: String, stderr: String) {
        let executablePath: String
        let arguments: [String]
        if command.executable.contains("/") {
            executablePath = command.executable
            arguments = command.arguments
        } else {
            executablePath = "/usr/bin/env"
            arguments = [command.executable] + command.arguments
        }

        do {
            let result = try await LocalWorkerProcess().run(WorkerProcessRequest(
                executablePath: executablePath,
                arguments: arguments,
                environment: command.environment,
                workingDirectory: workDir,
                timeoutSeconds: max(1, timeoutSeconds),
                streamStdout: false,
                streamStderr: true
            ))
            return (result.stdout, result.stderr)
        } catch WorkerProcessError.cancelled {
            throw PETMRDeformableRegistrationError.cancelled
        } catch WorkerProcessError.launchFailed(let message) {
            throw PETMRDeformableRegistrationError.launchFailed(message)
        } catch WorkerProcessError.timedOut(_, let stderr) {
            throw PETMRDeformableRegistrationError.timedOut(timeoutSeconds, stderr)
        } catch WorkerProcessError.nonZeroExit(let exitCode, let stderr) {
            throw PETMRDeformableRegistrationError.failed(exitCode: exitCode, stderr: stderr)
        }
    }

    private static func shellLikeSplit(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func shellQuote(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
