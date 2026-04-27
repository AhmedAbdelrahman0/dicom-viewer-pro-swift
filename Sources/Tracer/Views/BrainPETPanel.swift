import SwiftUI
import UniformTypeIdentifiers

struct BrainPETPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var tracer: BrainPETTracer = .fdg
    @State private var tauThreshold: Double = 1.34
    @State private var showNormalDatabaseImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            if let report = vm.brainPETReport {
                reportView(report)
            } else {
                emptyState
            }
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
                                             tauSUVRThreshold: tauThreshold)
            } label: {
                Label("Analyze", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.labeling.activeLabelMap == nil || vm.activePETQuantificationVolume == nil)

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
}
