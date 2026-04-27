import SwiftUI

struct OncologyReviewPanel: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actions

            if let review = vm.activePETOncologyReview {
                reviewCard(review)
            } else {
                emptyReview
            }

            if let qa = vm.activeSegmentationQualityReport {
                qualityCard(qa)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("PET Oncology Review", systemImage: "flame")
                .font(.headline)
            Text("Summarizes active PET labels into TMTV, TLG, SUVmax, target lesions, and QA signals.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                _ = vm.refreshActivePETOncologyReview()
                _ = vm.refreshActiveSegmentationQuality()
            } label: {
                Label("Review", systemImage: "checklist.checked")
                    .frame(maxWidth: .infinity)
            }
            .disabled(vm.labeling.activeLabelMap == nil)

            Button {
                vm.captureActiveSegmentationRun(engine: "Oncology Review", backend: "Tracer")
            } label: {
                Label("Save Run", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled(vm.labeling.activeLabelMap == nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var emptyReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No active review yet", systemImage: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Create or load a PET-aligned label map, then run Review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.viewportBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func reviewCard(_ review: PETOncologyReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(review.summary, systemImage: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metric("TMTV", String(format: "%.1f mL", review.totalMetabolicTumorVolumeML))
                metric("TLG", String(format: "%.1f", review.totalLesionGlycolysis))
                metric("SUVmax", String(format: "%.2f", review.maxSUV))
                metric("SUVmean", String(format: "%.2f", review.weightedMeanSUV))
            }

            if !review.workflowFlags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(review.workflowFlags) { flag in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(for: flag.severity))
                                .foregroundStyle(color(for: flag.severity))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flag.title)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(flag.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if !review.targetLesions.isEmpty {
                Divider()
                Text("Target Lesions")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(review.targetLesions) { lesion in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(lesion.id) \(lesion.compactSummary)")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                        Text(lesion.boundsDescription)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
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

    private func qualityCard(_ report: SegmentationQualityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Segmentation QA: \(report.compactSummary)", systemImage: icon(for: report.status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(for: report.status))
            metric("Largest", String(format: "%.2f mL", report.largestComponentML))
            metric("Tiny islands", "\(report.tinyComponentCount)")
            metric("Edge touches", "\(report.edgeTouchingComponentCount)")
            if !report.warnings.isEmpty {
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(TracerTheme.viewportBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.monospaced())
        }
    }

    private func icon(for severity: PETOncologyReview.WorkflowFlag.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .review: return "exclamationmark.triangle"
        case .highPriority: return "exclamationmark.octagon"
        }
    }

    private func color(for severity: PETOncologyReview.WorkflowFlag.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .review: return .orange
        case .highPriority: return .red
        }
    }

    private func icon(for status: SegmentationQualityReport.Status) -> String {
        switch status {
        case .pass: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .fail: return "xmark.octagon"
        }
    }

    private func color(for status: SegmentationQualityReport.Status) -> Color {
        switch status {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }
}
