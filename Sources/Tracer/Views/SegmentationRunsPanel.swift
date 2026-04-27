import SwiftUI

struct SegmentationRunsPanel: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actions
            Divider()
            if vm.segmentationRuns.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.segmentationRuns) { record in
                        SegmentationRunRow(record: record)
                            .environmentObject(vm)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Segmentation Registry", systemImage: "externaldrive.badge.icloud")
                .font(.headline)
            Text("Saved runs are indexed by study, so model outputs can be reopened separately from measurements and manual edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                vm.captureActiveSegmentationRun()
            } label: {
                Label("Save Active", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled(vm.labeling.activeLabelMap == nil)

            Button {
                vm.refreshSegmentationRuns()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No saved segmentation runs for this study", systemImage: "tray")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Run LesionTracer, nnU-Net, MONAI Label, or save the active label map to populate this registry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

private struct SegmentationRunRow: View {
    @EnvironmentObject var vm: ViewerViewModel
    let record: SegmentationRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(TracerTheme.label)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(record.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(record.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Button {
                    vm.loadSegmentationRun(id: record.id)
                } label: {
                    Label("Load", systemImage: "arrow.down.doc")
                }
                .labelStyle(.iconOnly)
                .help("Load this segmentation run into the active label-map list")

                Button(role: .destructive) {
                    vm.deleteSegmentationRun(id: record.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Remove this saved segmentation run from the registry")
            }

            if !record.metadata.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.metadata.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .firstTextBaseline) {
                                Text(key)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                Text(record.metadata[key] ?? "")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text("Metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(9)
        .background(TracerTheme.viewportBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
