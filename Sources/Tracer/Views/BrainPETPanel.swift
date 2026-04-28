import SwiftUI
import UniformTypeIdentifiers

struct BrainPETPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var tracer: BrainPETTracer = .fdg
    @State private var anatomyMode: BrainPETAnatomyMode = .automatic
    @State private var tauThreshold: Double = 1.34
    @State private var showNormalDatabaseImporter = false
    @State private var gaainSummary: GAAINReferenceDatasetSummary?
    @State private var gaainPackage: GAAINReferenceBuildPackage?
    @State private var gaainStatus: String = ""
    @State private var isGAAINRemoteRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            if let anatomyReport = vm.brainPETAnatomyAwareReport {
                anatomyAwareSummaryView(anatomyReport)
                reportView(anatomyReport.anatomyAwareReport)
            } else if let report = vm.brainPETReport {
                reportView(report)
            } else {
                emptyState
            }
            gaainReferenceBuilder
            normalSources
        }
    }

    private var header: some View {
        HStack {
            Label("Brain PET", systemImage: "brain.head.profile")
                .font(.headline)
            Spacer()
            if let pet = vm.activePETQuantificationVolume {
                Text(pet.seriesDescription.isEmpty ? "PET" : pet.seriesDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tracer", selection: $tracer) {
                ForEach(BrainPETTracer.allCases) { tracer in
                    Text(tracer.displayName).tag(tracer)
                }
            }

            Picker("Anatomy", selection: $anatomyMode) {
                ForEach(BrainPETAnatomyMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }

            if let anatomy = vm.activeBrainPETAnatomyVolume(for: anatomyMode) {
                Label(anatomy.seriesDescription.isEmpty ? Modality.normalize(anatomy.modality).displayName : anatomy.seriesDescription,
                      systemImage: anatomyMode.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if anatomyMode != .petOnly {
                Label("No matching CT/MRI anatomy found; PET-only fallback will be used.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tracer.family == .tau {
                HStack {
                    Text("Tau threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", tauThreshold))
                        .font(.caption.monospaced())
                }
                Slider(value: $tauThreshold, in: 1.05...2.2, step: 0.01)
            }

            Button {
                vm.runActiveBrainPETAnalysis(tracer: tracer,
                                             tauSUVRThreshold: tauThreshold,
                                             anatomyMode: anatomyMode)
            } label: {
                Label("Analyze", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.activePETQuantificationVolume == nil)
            .help(vm.labeling.activeLabelMap == nil
                  ? "Analyze will prompt for a PET-aligned brain atlas label map."
                  : "Run FDG, amyloid, or tau regional brain PET analysis.")

            HStack(spacing: 8) {
                Button {
                    showNormalDatabaseImporter = true
                } label: {
                    Label("Import Norms", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    vm.clearBrainPETNormalDatabase()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.brainPETNormalDatabase == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let database = vm.brainPETNormalDatabase {
                Label(database.name, systemImage: "externaldrive.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fileImporter(isPresented: $showNormalDatabaseImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result,
               let url = urls.first {
                vm.importBrainPETNormalDatabase(from: url, tracer: tracer)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Atlas required", systemImage: "map")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Use a PET-aligned brain atlas label map for regional SUVR, Centiloid, and tau staging.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.viewportBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func anatomyAwareSummaryView(_ report: BrainPETAnatomyAwareReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(report.resolvedMode.displayName, systemImage: report.resolvedMode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(report.confidence.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(confidenceColor(report.confidence))
            }
            if let anatomy = report.anatomySeriesDescription,
               !anatomy.isEmpty {
                metric("Anatomy", anatomy)
            }
            HStack(spacing: 8) {
                comparisonColumn(title: "Standard",
                                 suvr: report.standardReport.targetSUVR,
                                 centiloid: report.standardReport.centiloid)
                comparisonColumn(title: "Anatomy-aware",
                                 suvr: report.anatomyAwareReport.targetSUVR,
                                 centiloid: report.anatomyAwareReport.centiloid)
            }
            if report.delta.targetSUVR != nil || report.delta.centiloid != nil {
                HStack(spacing: 10) {
                    if let delta = report.delta.targetSUVR {
                        metricChip("ΔSUVR", String(format: "%+.3f", delta))
                    }
                    if let delta = report.delta.centiloid {
                        metricChip("ΔCL", String(format: "%+.1f", delta))
                    }
                }
            }
            VStack(spacing: 4) {
                ForEach(report.qcMetrics) { metric in
                    HStack {
                        Image(systemName: metric.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(metric.passed ? .green : .orange)
                            .frame(width: 16)
                        Text(metric.title)
                            .font(.caption2)
                        Spacer()
                        Text(metric.value)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if !report.warnings.isEmpty {
                Divider()
                ForEach(report.warnings.prefix(3), id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(TracerTheme.viewportBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func comparisonColumn(title: String, suvr: Double?, centiloid: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(suvr.map { String(format: "SUVR %.3f", $0) } ?? "SUVR --")
                .font(.caption2.monospaced())
            if let centiloid {
                Text(String(format: "CL %.1f", centiloid))
                    .font(.caption2.monospaced())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.panelBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metricChip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(TracerTheme.accent.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func reportView(_ report: BrainPETReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.summary, systemImage: icon(for: report.family))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            metric("Reference", report.referenceRegionName)
            metric("Ref mean", String(format: "%.3f", report.referenceMean))
            if let target = report.targetSUVR {
                metric("Target SUVR", String(format: "%.3f", target))
            }
            if let centiloid = report.centiloid {
                metric("Centiloid", String(format: "%.1f", centiloid))
            }
            if let calibration = report.centiloidCalibrationName {
                metric("Calibration", calibration)
            }

            if let tau = report.tauGrade {
                Divider()
                metric("Tau grade", tau.stage)
                ForEach(tau.groups) { group in
                    HStack {
                        Image(systemName: group.positive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(group.positive ? .orange : .secondary)
                            .frame(width: 16)
                        Text(group.name)
                            .font(.caption2)
                        Spacer()
                        Text(group.meanSUVR.map { String(format: "%.3f", $0) } ?? "--")
                            .font(.caption2.monospaced())
                    }
                }
            }

            Divider()
            Text("Regions")
                .font(.system(size: 11, weight: .semibold))
            ForEach(Array(report.regions.prefix(10))) { region in
                regionRow(region, family: report.family)
            }

            if !report.warnings.isEmpty {
                Divider()
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(TracerTheme.viewportBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func regionRow(_ region: BrainPETRegionStatistic,
                           family: BrainPETAnalysisFamily) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(region.name)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.3f", region.suvr))
                    .font(.caption2.monospaced())
            }
            if let z = region.zScore {
                HStack {
                    Text("z")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", z))
                        .font(.caption2.monospaced())
                        .foregroundStyle(zColor(z, family: family))
                    if let label = region.abnormalityLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(zColor(z, family: family))
                    }
                    Spacer()
                }
            }
        }
    }

    private var normalSources: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(BrainPETNormalDatabaseCatalog.recommendedSources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(source.access) | \(source.suggestedUse)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(source.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(TracerTheme.accent)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Normal databases", systemImage: "externaldrive.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private var gaainReferenceBuilder: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        scanGAAINReferenceData()
                    } label: {
                        Label("Scan GAAIN", systemImage: "externaldrive.badge.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        exportGAAINBuildPackage()
                    } label: {
                        Label("Export Spark Job", systemImage: "shippingbox.and.arrow.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(gaainSummary == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await launchGAAINOnSpark() }
                } label: {
                    Label(isGAAINRemoteRunning ? "Running on Spark" : "Run on Spark",
                          systemImage: isGAAINRemoteRunning ? "hourglass" : "bolt.horizontal.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isGAAINRemoteRunning)

                if DGXSparkConfig.load().readinessMessage != nil,
                   let detected = DGXSparkConfig.detectedNVIDIASparkProfile(enabled: true) {
                    Button {
                        detected.save()
                        gaainStatus = "Applied detected Spark profile: \(detected.sshDestination)"
                    } label: {
                        Label("Use Detected Spark Profile", systemImage: "bolt.horizontal.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let summary = gaainSummary {
                    VStack(alignment: .leading, spacing: 5) {
                        metric("Files", "\(summary.completeFileCount)/\(summary.files.count)")
                        metric("Downloaded", formatBytes(summary.totalActualBytes))
                        ForEach(summary.tracerSummaries.prefix(6)) { tracerSummary in
                            HStack {
                                Text(tracerSummary.tracer.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(tracerSummary.completeFileCount)")
                                    .font(.caption2.monospaced())
                                Text(formatBytes(tracerSummary.actualBytes))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(TracerTheme.viewportBackground.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                if let package = gaainPackage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Spark package ready", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(package.rootURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                } else if !gaainStatus.isEmpty {
                    Text(gaainStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("GAAIN reference builder", systemImage: "cpu")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "--" : value)
                .font(.caption2.monospaced())
                .lineLimit(1)
        }
    }

    private func scanGAAINReferenceData() {
        do {
            let summary = try GAAINReferencePipeline.discover()
            gaainSummary = summary
            gaainPackage = nil
            gaainStatus = "Found \(summary.completeFileCount)/\(summary.files.count) public GAAIN files."
        } catch {
            gaainSummary = nil
            gaainPackage = nil
            gaainStatus = "GAAIN scan failed: \(error.localizedDescription)"
        }
    }

    private func exportGAAINBuildPackage() {
        let operationID = "brain-pet-gaain-reference-package"
        JobManager.shared.start(JobUpdate(
            operationID: operationID,
            kind: .brainPETReference,
            title: "GAAIN reference package",
            stage: "Exporting",
            detail: "Writing Spark/DGX build plan",
            progress: 0.2,
            systemImage: "brain.head.profile",
            canCancel: false
        ))
        do {
            let package = try GAAINReferencePipeline.writeBuildPackage()
            gaainSummary = package.summary
            gaainPackage = package
            gaainStatus = "Spark package ready at \(package.rootURL.path)"
            JobManager.shared.succeed(operationID: operationID,
                                      detail: "GAAIN package exported with \(package.plan.jobs.count) tracer job(s)")
        } catch {
            gaainPackage = nil
            gaainStatus = "GAAIN package export failed: \(error.localizedDescription)"
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(error,
                                                       code: "gaain_reference_package_failed",
                                                       recoverySuggestion: "Confirm the GAAIN downloads and manifest exist in Tracer's app-support folder.",
                                                       isRetryable: true))
        }
    }

    private func launchGAAINOnSpark() async {
        guard !isGAAINRemoteRunning else { return }
        let operationID = "brain-pet-gaain-reference-spark"
        var cfg = DGXSparkConfig.load()
        if cfg.readinessMessage != nil,
           let detected = DGXSparkConfig.detectedNVIDIASparkProfile(enabled: true) {
            detected.save()
            cfg = detected
        }
        guard cfg.enabled, cfg.isConfigured else {
            gaainStatus = cfg.readinessMessage ?? "Enable and configure DGX Spark in Settings before launching the GAAIN build."
            JobManager.shared.start(JobUpdate(
                operationID: operationID,
                kind: .brainPETReference,
                title: "GAAIN Spark build",
                stage: "Configuration",
                detail: gaainStatus,
                progress: nil,
                systemImage: "exclamationmark.triangle",
                canCancel: false
            ))
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(code: "dgx_not_configured",
                                                       message: gaainStatus,
                                                       recoverySuggestion: "Open Settings -> DGX Spark, set the host/user/workdir, and enable DGX Spark.",
                                                       isRetryable: true))
            return
        }

        isGAAINRemoteRunning = true
        gaainStatus = "Preparing GAAIN Spark build..."
        JobManager.shared.start(JobUpdate(
            operationID: operationID,
            kind: .brainPETReference,
            title: "GAAIN Spark build",
            stage: "Preparing",
            detail: "Exporting local build package",
            progress: nil,
            systemImage: "brain.head.profile",
            canCancel: false
        ))
        defer { isGAAINRemoteRunning = false }

        do {
            let package = try GAAINReferencePipeline.writeBuildPackage()
            gaainSummary = package.summary
            gaainPackage = package
            JobManager.shared.update(operationID: operationID,
                                     stage: "Spark",
                                     detail: "Uploading package and launching worker")

            let sink: @Sendable (String) -> Void = { text in
                let detail = text
                    .split(whereSeparator: \.isNewline)
                    .last
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let detail, !detail.isEmpty else { return }
                Task { @MainActor in
                    JobManager.shared.heartbeat(operationID: operationID,
                                                detail: detail)
                }
            }
            let result = try await Task.detached(priority: .utility) {
                let runner = RemoteGAAINReferenceBuilder(configuration: .init(dgx: cfg))
                return try runner.run(package: package, logSink: sink)
            }.value

            gaainStatus = "Spark build complete: \(result.artifactPaths.count) artifact(s) pulled to \(result.localOutputRoot.path)"
            JobManager.shared.succeed(operationID: operationID,
                                      detail: gaainStatus)
        } catch {
            gaainStatus = "GAAIN Spark build failed: \(error.localizedDescription)"
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(error,
                                                       code: "gaain_spark_build_failed",
                                                       recoverySuggestion: "Check Settings -> DGX Spark, Python/nibabel/numpy availability on Spark, remote disk space, and the Job Center log.",
                                                       isRetryable: true))
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    private func icon(for family: BrainPETAnalysisFamily) -> String {
        switch family {
        case .fdg: return "bolt.heart"
        case .amyloid: return "aqi.medium"
        case .tau: return "point.3.connected.trianglepath.dotted"
        case .generic: return "chart.xyaxis.line"
        }
    }

    private func zColor(_ z: Double, family: BrainPETAnalysisFamily) -> Color {
        switch family {
        case .fdg:
            return z <= -2 ? .red : .secondary
        case .amyloid, .tau:
            return z >= 2 ? .orange : .secondary
        case .generic:
            return abs(z) >= 2 ? .orange : .secondary
        }
    }

    private func confidenceColor(_ confidence: BrainPETAnatomyConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}
