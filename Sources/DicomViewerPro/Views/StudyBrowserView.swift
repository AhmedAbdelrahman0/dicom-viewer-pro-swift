import SwiftUI
import SwiftData

struct StudyBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PACSIndexedSeries.indexedAt, order: .reverse) private var indexedSeries: [PACSIndexedSeries]

    @ObservedObject var vm: ViewerViewModel
    let onImportFolder: () -> Void
    let onIndexFolder: () -> Void
    let onImportVolume: () -> Void
    let onImportOverlay: () -> Void

    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerButtons
            Divider()

            List {
                if !indexedSeries.isEmpty {
                    Section("Mini-PACS Index") {
                        ForEach(filteredIndexedSeries) { entry in
                            Button {
                                Task { await vm.openIndexedSeries(entry.snapshot) }
                            } label: {
                                PACSIndexedSeriesRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    modelContext.delete(entry)
                                    try? modelContext.save()
                                } label: {
                                    Label("Remove from Index", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !vm.loadedSeries.isEmpty {
                    Section("DICOM Studies") {
                        ForEach(filteredSeries) { series in
                            Button {
                                Task { await vm.openSeries(series) }
                            } label: {
                                SeriesRow(series: series)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !vm.loadedVolumes.isEmpty {
                    Section("Loaded Volumes") {
                        ForEach(vm.loadedVolumes) { v in
                            Button {
                                vm.displayVolume(v)
                            } label: {
                                VolumeRow(volume: v)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if indexedSeries.isEmpty && vm.loadedSeries.isEmpty && vm.loadedVolumes.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("No studies loaded")
                                .foregroundColor(.secondary)
                            Text("Open or index a DICOM folder or NIfTI file to begin")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .searchable(text: $searchText, prompt: "Search…")
        }
        .navigationTitle("Studies")
    }

    private var filteredSeries: [DICOMSeries] {
        if searchText.isEmpty { return vm.loadedSeries }
        return vm.loadedSeries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.patientName.localizedCaseInsensitiveContains(searchText) ||
            $0.studyDescription.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredIndexedSeries: [PACSIndexedSeries] {
        if searchText.isEmpty { return indexedSeries }
        return indexedSeries.filter {
            $0.searchableText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var headerButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onImportFolder()
                } label: {
                    Label("Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    onImportVolume()
                } label: {
                    Label("File", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button {
                    onIndexFolder()
                } label: {
                    Label("Index", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onImportOverlay()
                } label: {
                    Label("Overlay", systemImage: "square.2.stack.3d")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.currentVolume == nil)
            }
        }
        .padding(8)
    }
}

private struct PACSIndexedSeriesRow: View {
    let entry: PACSIndexedSeries

    var body: some View {
        HStack(spacing: 10) {
            modalityBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.seriesDescription.isEmpty ? "Series" : entry.seriesDescription)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.patientName.isEmpty ? entry.kind.displayName : entry.patientName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if !entry.studyDate.isEmpty {
                        Text(entry.studyDate)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Text(entry.kind == .dicom ? "\(entry.instanceCount)" : entry.kind.displayName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var modalityBadge: some View {
        Text(Modality.normalize(entry.modality).displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .cornerRadius(3)
    }

    private var badgeColor: Color {
        switch Modality.normalize(entry.modality) {
        case .CT: return .blue
        case .MR: return .purple
        case .PT: return .orange
        case .SEG: return .green
        default: return .gray
        }
    }
}

private struct SeriesRow: View {
    let series: DICOMSeries

    var body: some View {
        HStack(spacing: 10) {
            modalityBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(series.description.isEmpty ? "Series" : series.description)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(series.patientName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if !series.studyDate.isEmpty {
                        Text(series.studyDate)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Text("\(series.instanceCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var modalityBadge: some View {
        Text(Modality.normalize(series.modality).displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .cornerRadius(3)
    }

    private var badgeColor: Color {
        switch Modality.normalize(series.modality) {
        case .CT: return .blue
        case .MR: return .purple
        case .PT: return .orange
        case .SEG: return .green
        default: return .gray
        }
    }
}

private struct VolumeRow: View {
    let volume: ImageVolume

    var body: some View {
        HStack(spacing: 10) {
            modalityBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.seriesDescription.isEmpty ? "Volume" : volume.seriesDescription)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(volume.width)×\(volume.height)×\(volume.depth)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var modalityBadge: some View {
        Text(Modality.normalize(volume.modality).displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .cornerRadius(3)
    }

    private var badgeColor: Color {
        switch Modality.normalize(volume.modality) {
        case .CT: return .blue
        case .MR: return .purple
        case .PT: return .orange
        case .SEG: return .green
        default: return .gray
        }
    }
}
