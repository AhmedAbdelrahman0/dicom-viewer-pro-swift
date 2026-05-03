import Foundation

public enum GAAINReferenceTracer: String, CaseIterable, Identifiable, Codable, Sendable {
    case pib
    case florbetapir
    case florbetaben
    case flutemetamol
    case nav4694
    case fdg
    case mri
    case voi
    case metadata
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pib: return "PiB"
        case .florbetapir: return "Florbetapir / Amyvid"
        case .florbetaben: return "Florbetaben"
        case .flutemetamol: return "Flutemetamol"
        case .nav4694: return "NAV4694"
        case .fdg: return "FDG"
        case .mri: return "MRI support"
        case .voi: return "VOI / atlas"
        case .metadata: return "Metadata"
        case .unknown: return "Unknown"
        }
    }

    public var brainPETTracer: BrainPETTracer? {
        switch self {
        case .pib: return .amyloidPIB
        case .florbetapir: return .amyloidFlorbetapir
        case .florbetaben: return .amyloidFlorbetaben
        case .flutemetamol: return .amyloidFlutemetamol
        case .fdg: return .fdg
        case .nav4694, .mri, .voi, .metadata, .unknown:
            return nil
        }
    }

    public var isPETTracer: Bool {
        switch self {
        case .pib, .florbetapir, .florbetaben, .flutemetamol, .nav4694, .fdg:
            return true
        case .mri, .voi, .metadata, .unknown:
            return false
        }
    }
}

public enum GAAINReferenceModality: String, Codable, Sendable {
    case pet
    case mri
    case voi
    case metadata
    case unknown
}

public enum GAAINReferenceCohort: String, Codable, Sendable {
    case youngControl
    case elderControl
    case alzheimersDisease
    case otherControl
    case mixed
    case unknown

    public var displayName: String {
        switch self {
        case .youngControl: return "Young control"
        case .elderControl: return "Elder control"
        case .alzheimersDisease: return "Alzheimer disease"
        case .otherControl: return "Other control"
        case .mixed: return "Mixed"
        case .unknown: return "Unknown"
        }
    }
}

public struct GAAINReferenceFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { filename }

    public let filename: String
    public let sourceURL: String?
    public let localPath: String
    public let expectedByteCount: Int64?
    public let actualByteCount: Int64?
    public let contentType: String?
    public let lastModified: String?
    public let tracer: GAAINReferenceTracer
    public let modality: GAAINReferenceModality
    public let cohort: GAAINReferenceCohort

    public var isComplete: Bool {
        guard let expectedByteCount else { return actualByteCount != nil }
        return actualByteCount == expectedByteCount
    }

    public var isImaging: Bool {
        modality == .pet || modality == .mri || modality == .voi
    }
}

public struct GAAINReferenceTracerSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: GAAINReferenceTracer { tracer }

    public let tracer: GAAINReferenceTracer
    public let fileCount: Int
    public let completeFileCount: Int
    public let expectedBytes: Int64
    public let actualBytes: Int64
}

public struct GAAINReferenceDatasetSummary: Codable, Equatable, Sendable {
    public let rootPath: String
    public let manifestPath: String?
    public let generatedAt: Date
    public let files: [GAAINReferenceFile]
    public let tracerSummaries: [GAAINReferenceTracerSummary]

    public var totalExpectedBytes: Int64 {
        files.compactMap(\.expectedByteCount).reduce(0, +)
    }

    public var totalActualBytes: Int64 {
        files.compactMap(\.actualByteCount).reduce(0, +)
    }

    public var completeFileCount: Int {
        files.filter(\.isComplete).count
    }

    public var missingFiles: [GAAINReferenceFile] {
        files.filter { $0.actualByteCount == nil }
    }

    public var incompleteFiles: [GAAINReferenceFile] {
        files.filter { !$0.isComplete }
    }
}

public struct GAAINReferenceBuildJob: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tracer: GAAINReferenceTracer
    public let brainPETTracer: BrainPETTracer?
    public let inputFiles: [String]
    public let supportFiles: [String]
    public let recommendedReferenceRegions: [String]
    public let plannedOutputs: [String]
    public let steps: [String]
    public let gpuRecommended: Bool
}

public struct GAAINReferenceBuildPlan: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let sourceRoot: String
    public let outputRoot: String
    public let fileCount: Int
    public let totalBytes: Int64
    public let jobs: [GAAINReferenceBuildJob]
    public let notes: [String]
}

public struct GAAINReferenceBuildPackage: Codable, Equatable, Sendable {
    public let rootURL: URL
    public let planURL: URL
    public let workerScriptURL: URL
    public let runScriptURL: URL
    public let readmeURL: URL
    public let summary: GAAINReferenceDatasetSummary
    public let plan: GAAINReferenceBuildPlan
}

public enum GAAINReferencePipelineError: Error, LocalizedError {
    case missingManifest(URL)
    case emptyManifest(URL)
    case noCompleteImagingFiles(URL)

    public var errorDescription: String? {
        switch self {
        case .missingManifest(let url):
            return "GAAIN manifest was not found at \(url.path)."
        case .emptyManifest(let url):
            return "GAAIN manifest at \(url.path) did not contain downloadable files."
        case .noCompleteImagingFiles(let url):
            return "No complete GAAIN imaging archives were found under \(url.path)."
        }
    }
}

public enum GAAINReferencePipeline {
    public static func defaultDownloadRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("NormalDatabases", isDirectory: true)
            .appendingPathComponent("InternetDownloads", isDirectory: true)
            .appendingPathComponent("GAAIN-Centiloid", isDirectory: true)
    }

    public static func defaultPackageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("ReferenceBuilds", isDirectory: true)
            .appendingPathComponent("GAAIN-Centiloid", isDirectory: true)
    }

    public static func discover(root: URL = defaultDownloadRoot(),
                                now: Date = Date()) throws -> GAAINReferenceDatasetSummary {
        let manifestURL = root.appendingPathComponent("download_manifest.tsv")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw GAAINReferencePipelineError.missingManifest(manifestURL)
        }
        let rows = try parseManifest(manifestURL)
        guard !rows.isEmpty else {
            throw GAAINReferencePipelineError.emptyManifest(manifestURL)
        }
        let files = rows.map { row in
            makeReferenceFile(root: root, row: row)
        }
        return GAAINReferenceDatasetSummary(
            rootPath: root.path,
            manifestPath: manifestURL.path,
            generatedAt: now,
            files: files.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending },
            tracerSummaries: makeTracerSummaries(files: files)
        )
    }

    public static func makeBuildPlan(summary: GAAINReferenceDatasetSummary,
                                     outputRoot: URL = defaultPackageRoot(),
                                     now: Date = Date()) throws -> GAAINReferenceBuildPlan {
        let complete = summary.files.filter(\.isComplete)
        guard complete.contains(where: \.isImaging) else {
            throw GAAINReferencePipelineError.noCompleteImagingFiles(URL(fileURLWithPath: summary.rootPath))
        }

        let support = complete.filter {
            $0.modality == .voi || $0.modality == .metadata || $0.modality == .mri
        }.map(\.filename).sorted()
        let tracerJobs = GAAINReferenceTracer.allCases.compactMap { tracer -> GAAINReferenceBuildJob? in
            guard tracer.isPETTracer else { return nil }
            let tracerFiles = complete
                .filter { $0.tracer == tracer && $0.modality == .pet }
                .map(\.filename)
                .sorted()
            guard !tracerFiles.isEmpty else { return nil }
            return GAAINReferenceBuildJob(
                id: "gaain-\(tracer.rawValue)-reference",
                title: "\(tracer.displayName) reference build",
                tracer: tracer,
                brainPETTracer: tracer.brainPETTracer,
                inputFiles: tracerFiles,
                supportFiles: support,
                recommendedReferenceRegions: referenceRegions(for: tracer),
                plannedOutputs: plannedOutputs(for: tracer),
                steps: buildSteps(for: tracer),
                gpuRecommended: true
            )
        }

        return GAAINReferenceBuildPlan(
            id: "gaain-centiloid-reference-\(Int(now.timeIntervalSince1970))",
            createdAt: now,
            sourceRoot: summary.rootPath,
            outputRoot: outputRoot.path,
            fileCount: complete.count,
            totalBytes: summary.totalActualBytes,
            jobs: tracerJobs,
            notes: [
                "This package builds research reference artifacts from user-downloaded GAAIN Centiloid materials.",
                "Tracer does not bundle GAAIN data; users are responsible for applicable data-use, citation, sharing, and non-clinical/research-use terms.",
                "Clinical use requires local validation, scanner harmonization checks, and operator QC.",
                "The worker emits Tracer CSV normal databases when NIfTI PET and VOI masks are on the same grid; otherwise it records QC failures for registration follow-up."
            ]
        )
    }

    public static func remoteExecutionPlan(from plan: GAAINReferenceBuildPlan,
                                           sourceRoot: String,
                                           outputRoot: String) -> GAAINReferenceBuildPlan {
        GAAINReferenceBuildPlan(
            id: plan.id,
            createdAt: plan.createdAt,
            sourceRoot: sourceRoot,
            outputRoot: outputRoot,
            fileCount: plan.fileCount,
            totalBytes: plan.totalBytes,
            jobs: plan.jobs,
            notes: plan.notes + [
                "Remote execution plan generated by Tracer. Source and output roots are remote workstation paths."
            ]
        )
    }

    public static func writeBuildPackage(root: URL = defaultDownloadRoot(),
                                         packageRoot: URL = defaultPackageRoot(),
                                         now: Date = Date()) throws -> GAAINReferenceBuildPackage {
        let summary = try discover(root: root, now: now)
        let plan = try makeBuildPlan(summary: summary, outputRoot: packageRoot, now: now)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let planURL = packageRoot.appendingPathComponent("gaain_reference_build_plan.json")
        try encoder.encode(plan).write(to: planURL, options: .atomic)

        let workerURL = packageRoot.appendingPathComponent("gaain_reference_build.py")
        try Data(workerScript.utf8).write(to: workerURL, options: .atomic)

        let runURL = packageRoot.appendingPathComponent("run_gaain_reference_build.sh")
        try Data(runScript(planURL: planURL).utf8).write(to: runURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workerURL.path)

        let readmeURL = packageRoot.appendingPathComponent("README.md")
        try Data(readme(summary: summary, plan: plan).utf8).write(to: readmeURL, options: .atomic)

        return GAAINReferenceBuildPackage(
            rootURL: packageRoot,
            planURL: planURL,
            workerScriptURL: workerURL,
            runScriptURL: runURL,
            readmeURL: readmeURL,
            summary: summary,
            plan: plan
        )
    }

    // MARK: - Manifest parsing

    private struct ManifestRow {
        var filename: String
        var sourceURL: String
        var status: String
        var contentLength: Int64?
        var contentType: String?
        var lastModified: String?
    }

    private static func parseManifest(_ url: URL) throws -> [ManifestRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [] }
        if lines[0].lowercased().hasPrefix("filename\t") {
            lines.removeFirst()
        }
        return lines.compactMap { line in
            let pieces = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count >= 4 else { return nil }
            return ManifestRow(
                filename: pieces[0],
                sourceURL: pieces[1],
                status: pieces[2],
                contentLength: Int64(pieces[3]),
                contentType: pieces.count > 4 && !pieces[4].isEmpty ? pieces[4] : nil,
                lastModified: pieces.count > 5 && !pieces[5].isEmpty ? pieces[5] : nil
            )
        }
    }

    private static func makeReferenceFile(root: URL, row: ManifestRow) -> GAAINReferenceFile {
        let localURL = root.appendingPathComponent(row.filename)
        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
        let classification = classify(filename: row.filename)
        return GAAINReferenceFile(
            filename: row.filename,
            sourceURL: row.sourceURL,
            localPath: localURL.path,
            expectedByteCount: row.contentLength,
            actualByteCount: byteCount,
            contentType: row.contentType,
            lastModified: row.lastModified,
            tracer: classification.tracer,
            modality: classification.modality,
            cohort: classification.cohort
        )
    }

    private static func makeTracerSummaries(files: [GAAINReferenceFile]) -> [GAAINReferenceTracerSummary] {
        GAAINReferenceTracer.allCases.compactMap { tracer in
            let matching = files.filter { $0.tracer == tracer }
            guard !matching.isEmpty else { return nil }
            return GAAINReferenceTracerSummary(
                tracer: tracer,
                fileCount: matching.count,
                completeFileCount: matching.filter(\.isComplete).count,
                expectedBytes: matching.compactMap(\.expectedByteCount).reduce(0, +),
                actualBytes: matching.compactMap(\.actualByteCount).reduce(0, +)
            )
        }
        .sorted { $0.tracer.displayName < $1.tracer.displayName }
    }

    private static func classify(filename: String) -> (tracer: GAAINReferenceTracer, modality: GAAINReferenceModality, cohort: GAAINReferenceCohort) {
        let lower = filename.lowercased()
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let modality: GAAINReferenceModality
        if ["xlsx", "txt", "docx"].contains(ext) {
            modality = .metadata
        } else if lower.contains("voi") || lower.contains("centiloid_std") {
            modality = .voi
        } else if lower.contains("mr") || lower.contains("mri") {
            modality = .mri
        } else if lower.contains("pet") || lower.contains("pib") || lower.contains("fdg") || lower.contains("fbb") || lower.contains("florbetapir") || lower.contains("_c11_") || lower.contains("_f18_") || lower.contains("nav_") {
            modality = .pet
        } else {
            modality = .unknown
        }

        let tracer: GAAINReferenceTracer
        if modality == .metadata {
            tracer = metadataTracer(filename: lower)
        } else if modality == .voi {
            tracer = .voi
        } else if modality == .mri {
            tracer = .mri
        } else if lower.contains("florbetapir") || lower.contains("avid") {
            tracer = .florbetapir
        } else if lower.contains("fbb") || lower.contains("florbetaben") {
            tracer = .florbetaben
        } else if lower.contains("flutemetamol") || lower.contains("_f18_") {
            tracer = .flutemetamol
        } else if lower.contains("nav") {
            tracer = .nav4694
        } else if lower.contains("fdg") {
            tracer = .fdg
        } else if lower.contains("pib") || lower.contains("_c11_") || lower.contains("pet_5070") || lower.hasPrefix("yc_pet") || lower.hasPrefix("ad_pet") {
            tracer = .pib
        } else {
            tracer = .unknown
        }

        let cohort: GAAINReferenceCohort
        if lower.contains("yc") || lower.contains("young") || lower.contains("yhv") {
            cohort = .youngControl
        } else if lower.contains("elder") || lower.contains("_e-") || lower.contains("project_e-") {
            cohort = .elderControl
        } else if lower.hasPrefix("ad") || lower.contains("_ad_") || lower.contains("ad-") {
            cohort = .alzheimersDisease
        } else if lower.hasPrefix("oc") {
            cohort = .otherControl
        } else if modality == .metadata || modality == .voi || modality == .mri {
            cohort = .mixed
        } else {
            cohort = .unknown
        }
        return (tracer, modality, cohort)
    }

    private static func metadataTracer(filename: String) -> GAAINReferenceTracer {
        if filename.contains("florbetapir") || filename.contains("avid") {
            return .florbetapir
        }
        if filename.contains("fbb") || filename.contains("florbetaben") {
            return .florbetaben
        }
        if filename.contains("flutemetamol") || filename.contains("gehealthcare") {
            return .flutemetamol
        }
        if filename.contains("nav") {
            return .nav4694
        }
        if filename.contains("fdg") {
            return .fdg
        }
        if filename.contains("centiloid") || filename.contains("pib") || filename.contains("petdata") || filename.contains("supplementarytable1") {
            return .pib
        }
        return .metadata
    }

    private static func referenceRegions(for tracer: GAAINReferenceTracer) -> [String] {
        switch tracer {
        case .fdg:
            return ["Pons", "Cerebellar gray", "Whole cerebellum"]
        case .pib, .florbetapir, .florbetaben, .flutemetamol, .nav4694:
            return ["Whole cerebellum", "Cerebellar gray", "Whole cerebellum + brainstem", "Pons"]
        case .mri, .voi, .metadata, .unknown:
            return []
        }
    }

    private static func plannedOutputs(for tracer: GAAINReferenceTracer) -> [String] {
        [
            "subject_inventory_\(tracer.rawValue).csv",
            "subject_suvr_\(tracer.rawValue).csv",
            "normal_database_\(tracer.rawValue)_whole_cerebellum.csv",
            "qc_\(tracer.rawValue).csv",
            "reference_manifest_\(tracer.rawValue).json"
        ]
    }

    private static func buildSteps(for tracer: GAAINReferenceTracer) -> [String] {
        [
            "Extract archives into a deterministic working directory.",
            "Index PET/MR/NIfTI/DICOM files and infer subject IDs, tracer, cohort, and acquisition window.",
            "Prefer native NIfTI inputs; convert DICOM when needed.",
            "Register PET to MRI when available, then to MNI/Centiloid template.",
            "Apply standard VOIs and reference regions: \(referenceRegions(for: tracer).joined(separator: ", ")).",
            "Compute subject SUVR tables, tracer-level mean/SD normal CSVs, and QC sidecars for Tracer import.",
            "Flag missing masks, grid mismatch, failed registration, and outlier reference uptake for operator review."
        ]
    }

    private static func runScript(planURL: URL) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        python3 "$SCRIPT_DIR/gaain_reference_build.py" --plan "\(planURL.path)" --extract
        """
    }

    private static func readme(summary: GAAINReferenceDatasetSummary,
                               plan: GAAINReferenceBuildPlan) -> String {
        let tracerLines = summary.tracerSummaries.map {
            "- \($0.tracer.displayName): \($0.completeFileCount)/\($0.fileCount) files, \(formatBytes($0.actualBytes))"
        }.joined(separator: "\n")
        return """
        # GAAIN Centiloid Data Import Package

        This package prepares Tracer brain PET reference artifacts from user-downloaded GAAIN Centiloid materials.

        Data-use notice:
        Tracer does not bundle GAAIN data. Use this package only with materials downloaded under the applicable GAAIN terms. The user is responsible for confirming permitted research/non-clinical use, citation, and sharing restrictions before building or distributing derived artifacts.

        Source root:
        `\(summary.rootPath)`

        Output root:
        `\(plan.outputRoot)`

        Files:
        - Complete: \(summary.completeFileCount)/\(summary.files.count)
        - Downloaded: \(formatBytes(summary.totalActualBytes))

        Tracers:
        \(tracerLines)

        Run locally or on a remote workstation:

        ```bash
        ./run_gaain_reference_build.sh
        ```

        The worker writes inventory CSVs, QC CSVs, Tracer normal-database CSVs when VOI masks match PET grids, and a JSON manifest per tracer. Full deformable-registration normal-map generation is intentionally a later, explicit compute stage so QC failures remain visible.
        """
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", value, units[idx])
    }

    private static let workerScript = #"""
    #!/usr/bin/env python3
    import argparse
    import csv
    import json
    import math
    import os
    import shutil
    import statistics
    import subprocess
    import sys
    import zipfile
    from pathlib import Path

    try:
        import nibabel as nib
        import numpy as np
    except Exception:
        nib = None
        np = None

    def log(message):
        print(message, flush=True)

    def load_plan(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)

    def safe_stem(path):
        name = Path(path).name
        for suffix in [".nii.gz", ".zip", ".7z", ".nii", ".xlsx", ".docx", ".txt"]:
            if name.lower().endswith(suffix):
                return name[: -len(suffix)]
        return Path(name).stem

    def ensure_extract(archive, extract_root):
        archive = Path(archive)
        target = extract_root / safe_stem(archive.name)
        target.mkdir(parents=True, exist_ok=True)
        sentinel = target / ".tracer_extract_complete"
        if sentinel.exists():
            return target
        log(f"extract {archive.name}")
        if archive.suffix.lower() == ".zip":
            with zipfile.ZipFile(archive) as zf:
                zf.extractall(target)
        elif archive.suffix.lower() == ".7z":
            seven = shutil.which("7z") or shutil.which("7zz")
            if seven is None:
                log(f"skip 7z extraction; install 7z/7zz for {archive.name}")
                return target
            subprocess.run([seven, "x", "-y", f"-o{target}", str(archive)], check=True)
        else:
            return target
        sentinel.write_text("ok\n", encoding="utf-8")
        return target

    def iter_nifti(root):
        root = Path(root)
        for pattern in ("*.nii", "*.nii.gz"):
            yield from root.rglob(pattern)

    def subject_id(path):
        stem = safe_stem(path)
        return stem.split("_")[0].replace(" ", "")

    def find_voi_masks(search_roots):
        masks = {}
        for root in search_roots:
            for p in iter_nifti(root):
                lower = p.name.lower()
                if "voi" not in lower:
                    continue
                if "ctx" in lower:
                    masks["cortical_target"] = p
                elif "whlcblbrnstm" in lower or "brainstm" in lower:
                    masks["whole_cerebellum_brainstem"] = p
                elif "whlcbl" in lower:
                    masks["whole_cerebellum"] = p
                elif "cerebgry" in lower or "cereb_gray" in lower or "cerebgry" in lower:
                    masks["cerebellar_gray"] = p
                elif "pons" in lower:
                    masks["pons"] = p
        return masks

    def load_mask(path):
        img = nib.load(str(path))
        data = np.asanyarray(img.dataobj)
        return img, data > 0

    def mean_in_mask(image_data, mask):
        values = image_data[mask]
        values = values[np.isfinite(values)]
        if values.size == 0:
            return None
        return float(values.mean())

    def write_inventory(plan, output_root, extracted_roots):
        inventory = output_root / "subject_inventory_all.csv"
        rows = []
        for root in extracted_roots:
            for p in iter_nifti(root):
                rows.append({
                    "subject": subject_id(p),
                    "path": str(p),
                    "bytes": p.stat().st_size,
                    "source_extract_root": str(root)
                })
        with inventory.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["subject", "path", "bytes", "source_extract_root"])
            writer.writeheader()
            writer.writerows(rows)
        log(f"wrote {inventory} ({len(rows)} nifti files)")
        return rows

    def files_for_job(plan, job, extract_root):
        source_root = Path(plan["sourceRoot"])
        roots = []
        for name in job["inputFiles"] + job["supportFiles"]:
            archive = source_root / name
            if archive.exists():
                roots.append(extract_root / safe_stem(archive.name))
        return roots

    def compute_job(plan, job, output_root, extract_root):
        tracer = job["tracer"]
        qc_path = output_root / f"qc_{tracer}.csv"
        suvr_path = output_root / f"subject_suvr_{tracer}.csv"
        normal_path = output_root / f"normal_database_{tracer}_whole_cerebellum.csv"
        manifest_path = output_root / f"reference_manifest_{tracer}.json"
        if nib is None or np is None:
            qc_path.write_text("status,message\nmissing_dependency,nibabel/numpy unavailable\n", encoding="utf-8")
            manifest_path.write_text(json.dumps({"tracer": tracer, "status": "missing_dependency"}, indent=2), encoding="utf-8")
            return

        roots = files_for_job(plan, job, extract_root)
        masks = find_voi_masks([extract_root])
        if "whole_cerebellum" not in masks:
            qc_path.write_text("status,message\nmissing_mask,whole_cerebellum VOI not found\n", encoding="utf-8")
            manifest_path.write_text(json.dumps({"tracer": tracer, "status": "missing_mask", "masks": list(masks)}, indent=2), encoding="utf-8")
            return

        loaded_masks = {}
        for name, path in masks.items():
            try:
                loaded_masks[name] = load_mask(path)
            except Exception as exc:
                log(f"mask load failed {path}: {exc}")

        subject_rows = []
        qc_rows = []
        for root in roots:
            for pet_path in iter_nifti(root):
                lower = pet_path.name.lower()
                if "voi" in lower or "mr" in lower or "mri" in lower:
                    continue
                try:
                    img = nib.load(str(pet_path))
                    data = np.asanyarray(img.dataobj).astype("float64")
                except Exception as exc:
                    qc_rows.append({"subject": subject_id(pet_path), "file": str(pet_path), "status": "load_failed", "message": str(exc)})
                    continue

                reference_img, reference_mask = loaded_masks["whole_cerebellum"]
                if tuple(data.shape) != tuple(reference_mask.shape):
                    qc_rows.append({
                        "subject": subject_id(pet_path),
                        "file": str(pet_path),
                        "status": "grid_mismatch",
                        "message": f"pet_shape={tuple(data.shape)} mask_shape={tuple(reference_mask.shape)}"
                    })
                    continue
                ref_mean = mean_in_mask(data, reference_mask)
                if ref_mean is None or ref_mean <= 0:
                    qc_rows.append({"subject": subject_id(pet_path), "file": str(pet_path), "status": "empty_reference", "message": "whole cerebellum mean <= 0"})
                    continue
                row = {"subject": subject_id(pet_path), "file": str(pet_path), "reference_region": "whole_cerebellum", "reference_mean": ref_mean}
                for region, (_, mask) in loaded_masks.items():
                    if tuple(mask.shape) != tuple(data.shape):
                        continue
                    mean = mean_in_mask(data, mask)
                    if mean is not None:
                        row[f"{region}_mean"] = mean
                        row[f"{region}_suvr"] = mean / ref_mean
                subject_rows.append(row)
                qc_rows.append({"subject": subject_id(pet_path), "file": str(pet_path), "status": "ok", "message": ""})

        all_fields = ["subject", "file", "reference_region", "reference_mean"]
        dynamic = sorted({k for row in subject_rows for k in row.keys() if k not in all_fields})
        with suvr_path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=all_fields + dynamic)
            writer.writeheader()
            writer.writerows(subject_rows)

        with qc_path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["subject", "file", "status", "message"])
            writer.writeheader()
            writer.writerows(qc_rows)

        normal_rows = []
        region_names = sorted({k[:-5] for k in dynamic if k.endswith("_suvr")})
        for idx, region in enumerate(region_names, start=1):
            values = [float(row[f"{region}_suvr"]) for row in subject_rows if f"{region}_suvr" in row]
            if len(values) < 2:
                continue
            normal_rows.append({
                "region": region,
                "labelID": idx,
                "meanSUVR": statistics.mean(values),
                "sdSUVR": statistics.stdev(values),
                "n": len(values),
                "ageMin": "",
                "ageMax": ""
            })
        with normal_path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["region", "labelID", "meanSUVR", "sdSUVR", "n", "ageMin", "ageMax"])
            writer.writeheader()
            writer.writerows(normal_rows)

        manifest = {
            "tracer": tracer,
            "subjects": len(subject_rows),
            "qcRows": len(qc_rows),
            "normalRegions": len(normal_rows),
            "outputs": [str(suvr_path), str(qc_path), str(normal_path)]
        }
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        log(f"wrote {tracer}: subjects={len(subject_rows)} normal_regions={len(normal_rows)}")

    def main():
        parser = argparse.ArgumentParser(description="Build Tracer GAAIN brain PET reference artifacts.")
        parser.add_argument("--plan", required=True)
        parser.add_argument("--output")
        parser.add_argument("--extract", action="store_true")
        args = parser.parse_args()

        plan = load_plan(args.plan)
        output_root = Path(args.output or plan["outputRoot"])
        output_root.mkdir(parents=True, exist_ok=True)
        extract_root = output_root / "extracted"
        extract_root.mkdir(parents=True, exist_ok=True)
        source_root = Path(plan["sourceRoot"])

        extracted_roots = []
        if args.extract:
            names = sorted({name for job in plan["jobs"] for name in (job["inputFiles"] + job["supportFiles"])})
            for name in names:
                archive = source_root / name
                if archive.exists() and archive.suffix.lower() in [".zip", ".7z"]:
                    extracted_roots.append(ensure_extract(archive, extract_root))
        else:
            extracted_roots = [p for p in extract_root.iterdir() if p.is_dir()]

        write_inventory(plan, output_root, extracted_roots)
        for job in plan["jobs"]:
            log(f"job {job['id']}")
            compute_job(plan, job, output_root, extract_root)

    if __name__ == "__main__":
        main()
    """#
}
