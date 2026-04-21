import SwiftUI
import SwiftData

struct StudyBrowserView: View {
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var vm: ViewerViewModel
    let onImportFolder: () -> Void
    let onIndexFolder: () -> Void
    let onImportVolume: () -> Void
    let onImportOverlay: () -> Void

    @State private var searchText: String = ""
    @State private var indexedSeries: [PACSIndexedSeriesSnapshot] = []
    @State private var indexedTotalCount: Int = 0
    @State private var indexFetchLimit: Int = 500
    private let indexPageSize = 500

    var body: some View {
        VStack(spacing: 0) {
            headerButtons
            Divider()

            List {
                if !indexedSeries.isEmpty {
                    Section("Mini-PACS Index") {
                        ForEach(indexedSeries) { entry in
                            Button {
                                Task { await vm.openIndexedSeries(entry) }
                            } label: {
                                PACSIndexedSeriesRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteIndexedSeries(id: entry.id)
                                } label: {
                                    Label("Remove from Index", systemImage: "trash")
                                }
                            }
                        }

                        if indexedTotalCount > indexedSeries.count {
                            Button {
                                indexFetchLimit += indexPageSize
                                reloadIndexResults()
                            } label: {
                                Label("Show more (\(indexedSeries.count)/\(indexedTotalCount))",
                                      systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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

                if indexedTotalCount == 0 && vm.loadedSeries.isEmpty && vm.loadedVolumes.isEmpty {
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
        .task {
            reloadIndexResults()
        }
        .onChange(of: searchText) { _, _ in
            indexFetchLimit = indexPageSize
            reloadIndexResults()
        }
        .onChange(of: vm.indexRevision) { _, _ in
            reloadIndexResults()
        }
    }

    private var filteredSeries: [DICOMSeries] {
        if searchText.isEmpty { return vm.loadedSeries }
        return vm.loadedSeries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.patientName.localizedCaseInsensitiveContains(searchText) ||
            $0.studyDescription.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var headerButtons: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Worklist")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(indexedTotalCount) indexed · \(vm.loadedSeries.count) scanned")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if let indexProgress = vm.indexProgress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView()
                        .controlSize(.small)
                    Text(indexProgress.statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

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

    private func reloadIndexResults() {
        do {
            indexedSeries = try modelContext.fetch(indexFetchDescriptor(limit: indexFetchLimit)).map(\.snapshot)
            indexedTotalCount = try modelContext.fetchCount(indexFetchDescriptor(limit: nil))
        } catch {
            indexedSeries = []
            indexedTotalCount = 0
            vm.statusMessage = "Index fetch error: \(error.localizedDescription)"
        }
    }

    private func indexFetchDescriptor(limit: Int?) -> FetchDescriptor<PACSIndexedSeries> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sort = [
            SortDescriptor(\PACSIndexedSeries.indexedAt, order: .reverse),
            SortDescriptor(\PACSIndexedSeries.patientName),
            SortDescriptor(\PACSIndexedSeries.studyDate, order: .reverse),
        ]
        var descriptor: FetchDescriptor<PACSIndexedSeries>
        if query.isEmpty {
            descriptor = FetchDescriptor(sortBy: sort)
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.searchableTextLower.contains(query) },
                sortBy: sort
            )
        }
        if let limit {
            descriptor.fetchLimit = limit
        }
        return descriptor
    }

    private func deleteIndexedSeries(id: String) {
        do {
            var descriptor = FetchDescriptor<PACSIndexedSeries>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let entry = try modelContext.fetch(descriptor).first {
                modelContext.delete(entry)
                try modelContext.save()
                reloadIndexResults()
            }
        } catch {
            vm.statusMessage = "Index delete error: \(error.localizedDescription)"
        }
    }
}

private struct PACSIndexedSeriesRow: View {
    let entry: PACSIndexedSeriesSnapshot

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
