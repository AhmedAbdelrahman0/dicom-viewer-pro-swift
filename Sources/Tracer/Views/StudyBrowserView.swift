import SwiftUI
import SwiftData

private enum StudyBrowserMode: String, CaseIterable, Identifiable {
    case worklist
    case viewer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .worklist: return "Worklist"
        case .viewer: return "Viewer"
        }
    }

    var systemImage: String {
        switch self {
        case .worklist: return "list.clipboard"
        case .viewer: return "rectangle.3.group"
        }
    }
}

struct StudyBrowserView: View {
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var vm: ViewerViewModel
    let onImportFolder: () -> Void
    let onIndexFolder: () -> Void
    let onImportVolume: () -> Void
    let onImportOverlay: () -> Void

    @State private var browserMode: StudyBrowserMode = .worklist
    @State private var searchText: String = ""
    @State private var indexedSeries: [PACSIndexedSeriesSnapshot] = []
    @State private var indexedTotalCount: Int = 0
    @State private var indexFetchLimit: Int = 5_000
    @State private var statusFilter: WorklistStatusFilter = .all
    @State private var modalityFilter: String = "All"
    @State private var dateFilter: WorklistDateFilter = .all
    @State private var studyStatuses: [String: WorklistStudyStatus] = [:]
    @State private var expandedStudyIDs: Set<String> = []

    private let indexPageSize = 5_000
    private let statusDefaultsKey = "Tracer.WorklistStudyStatuses"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !vm.recentVolumes.isEmpty {
                recentVolumesStrip
                Divider()
            }

            Group {
                switch browserMode {
                case .worklist:
                    worklistContent
                case .viewer:
                    viewerContent
                }
            }
            .searchable(text: $searchText, prompt: browserMode == .worklist ? "Search worklist..." : "Search viewer session...")
        }
        .navigationTitle(browserMode.displayName)
        .task {
            loadStatusOverrides()
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

    // MARK: - Recent volumes strip

    /// Compact horizontal row of chips for the last `N` volumes the user
    /// has opened. Click a chip to reopen; the × button removes the chip
    /// without deleting anything on disk.
    private var recentVolumesStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recently opened")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if vm.recentVolumes.count > 1 {
                    Menu {
                        ForEach(vm.recentVolumes) { recent in
                            Button(role: .destructive) {
                                vm.removeRecent(id: recent.id)
                            } label: {
                                Label("Remove \(recent.seriesDescription)",
                                      systemImage: "minus.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }
            .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.recentVolumes) { recent in
                        recentChip(recent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .padding(.top, 4)
    }

    private func recentChip(_ recent: RecentVolume) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconForRecent(recent))
                .foregroundColor(colorForRecent(recent))
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.seriesDescription.isEmpty ? "Series" : recent.seriesDescription)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(recentSubtitle(recent))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Button {
                vm.removeRecent(id: recent.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await vm.reopenRecent(recent) }
        }
        .help(recentTooltip(recent))
    }

    private func iconForRecent(_ recent: RecentVolume) -> String {
        switch recent.kind {
        case .nifti: return "cube.box"
        case .dicom: return "square.stack.3d.up"
        }
    }

    private func colorForRecent(_ recent: RecentVolume) -> Color {
        switch Modality.normalize(recent.modality) {
        case .CT:  return .blue
        case .MR:  return .purple
        case .PT:  return .orange
        case .SEG: return .green
        default:   return .secondary
        }
    }

    private func recentSubtitle(_ recent: RecentVolume) -> String {
        let modality = Modality.normalize(recent.modality).displayName
        let patient = recent.patientName.isEmpty ? "—" : recent.patientName
        return "\(modality) · \(patient)"
    }

    private func recentTooltip(_ recent: RecentVolume) -> String {
        let lines: [String] = [
            "Reopen: \(recent.seriesDescription)",
            "Study: \(recent.studyDescription.isEmpty ? "—" : recent.studyDescription)",
            "Patient: \(recent.patientName.isEmpty ? "—" : recent.patientName)",
            "Modality: \(Modality.normalize(recent.modality).displayName)",
            "Opened: \(recent.openedAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("Panel", selection: $browserMode) {
                ForEach(StudyBrowserMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .firstTextBaseline) {
                Text(browserMode.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(headerCountText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if let indexProgress = vm.indexProgress {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                        if vm.isIndexing {
                            Button("Cancel") {
                                vm.cancelIndexing()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                    Text(indexProgress.statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            switch browserMode {
            case .worklist:
                worklistControls
            case .viewer:
                viewerControls
            }
        }
        .padding(8)
    }

    private var headerCountText: String {
        switch browserMode {
        case .worklist:
            return "\(filteredWorklistStudies.count) studies · \(indexedTotalCount) series"
        case .viewer:
            return "\(vm.loadedVolumes.count) volumes · \(vm.loadedSeries.count) scanned"
        }
    }

    private var worklistControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onIndexFolder()
                } label: {
                    Label("Index", systemImage: "externaldrive.badge.plus")
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

            HStack(spacing: 6) {
                Picker("Status", selection: $statusFilter) {
                    ForEach(WorklistStatusFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }

                Picker("Modality", selection: $modalityFilter) {
                    ForEach(modalityFilterOptions, id: \.self) { modality in
                        Text(modality).tag(modality)
                    }
                }

                Picker("Date", selection: $dateFilter) {
                    ForEach(WorklistDateFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var viewerControls: some View {
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

    private var worklistContent: some View {
        List {
            if !filteredWorklistStudies.isEmpty {
                Section("Studies") {
                    ForEach(filteredWorklistStudies) { study in
                        DisclosureGroup(isExpanded: expansionBinding(for: study.id)) {
                            WorklistStudyActions(
                                study: study,
                                onOpen: { openStudy(study) },
                                onStatus: { setStatus($0, for: study) }
                            )
                            ForEach(study.series) { series in
                                Button {
                                    setStatus(.inProgress, for: study)
                                    Task { await vm.openIndexedSeries(series) }
                                } label: {
                                    WorklistSeriesRow(entry: series)
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            WorklistStudyRow(study: study)
                        }
                        .contextMenu {
                            Button {
                                openStudy(study)
                            } label: {
                                Label("Open Study", systemImage: "rectangle.3.group")
                            }
                            Menu("Status") {
                                ForEach(WorklistStudyStatus.allCases) { status in
                                    Button(status.displayName) {
                                        setStatus(status, for: study)
                                    }
                                }
                            }
                            Button(role: .destructive) {
                                deleteIndexedStudy(study)
                            } label: {
                                Label("Remove Study from Index", systemImage: "trash")
                            }
                        }
                    }

                    if indexedTotalCount > indexedSeries.count {
                        Button {
                            indexFetchLimit += indexPageSize
                            reloadIndexResults()
                        } label: {
                            Label("Show more (\(indexedSeries.count)/\(indexedTotalCount) series)",
                                  systemImage: "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                EmptyBrowserRow(
                    systemImage: "list.clipboard",
                    title: "No worklist studies",
                    subtitle: "Index a local archive or adjust filters"
                )
            }
        }
    }

    private var viewerContent: some View {
        List {
            if !filteredLoadedVolumes.isEmpty {
                Section("Viewer Volumes") {
                    ForEach(filteredLoadedVolumes) { volume in
                        Button {
                            vm.displayVolume(volume)
                        } label: {
                            VolumeRow(volume: volume)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !filteredSeries.isEmpty {
                Section("Scanned Series") {
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

            if filteredLoadedVolumes.isEmpty && filteredSeries.isEmpty {
                EmptyBrowserRow(
                    systemImage: "rectangle.3.group",
                    title: "No viewer session",
                    subtitle: "Open a folder, file, or worklist study"
                )
            }
        }
    }

    private var worklistStudies: [PACSWorklistStudy] {
        PACSWorklistStudy.grouped(from: indexedSeries, statuses: studyStatuses)
    }

    private var filteredWorklistStudies: [PACSWorklistStudy] {
        worklistStudies.filter {
            $0.matches(
                searchText: searchText,
                statusFilter: statusFilter,
                modalityFilter: modalityFilter,
                dateFilter: dateFilter
            )
        }
    }

    private var modalityFilterOptions: [String] {
        ["All"] + Array(Set(worklistStudies.flatMap(\.modalities))).sorted()
    }

    private var filteredSeries: [DICOMSeries] {
        if searchText.isEmpty { return vm.loadedSeries }
        return vm.loadedSeries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.patientName.localizedCaseInsensitiveContains(searchText) ||
            $0.studyDescription.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredLoadedVolumes: [ImageVolume] {
        if searchText.isEmpty { return vm.loadedVolumes }
        return vm.loadedVolumes.filter {
            $0.seriesDescription.localizedCaseInsensitiveContains(searchText) ||
            $0.patientName.localizedCaseInsensitiveContains(searchText) ||
            $0.studyDescription.localizedCaseInsensitiveContains(searchText) ||
            $0.patientID.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedStudyIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedStudyIDs.insert(id)
                } else {
                    expandedStudyIDs.remove(id)
                }
            }
        )
    }

    private func openStudy(_ study: PACSWorklistStudy) {
        setStatus(.inProgress, for: study)
        Task { await vm.openWorklistStudy(study) }
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

    private func deleteIndexedStudy(_ study: PACSWorklistStudy) {
        do {
            for series in study.series {
                let id = series.id
                var descriptor = FetchDescriptor<PACSIndexedSeries>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let entry = try modelContext.fetch(descriptor).first {
                    modelContext.delete(entry)
                }
            }
            try modelContext.save()
            studyStatuses.removeValue(forKey: study.id)
            persistStatusOverrides()
            reloadIndexResults()
        } catch {
            vm.statusMessage = "Index delete error: \(error.localizedDescription)"
        }
    }

    private func setStatus(_ status: WorklistStudyStatus, for study: PACSWorklistStudy) {
        studyStatuses[study.id] = status
        persistStatusOverrides()
    }

    private func loadStatusOverrides() {
        guard let data = UserDefaults.standard.data(forKey: statusDefaultsKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            studyStatuses = [:]
            return
        }
        studyStatuses = raw.reduce(into: [:]) { out, pair in
            if let status = WorklistStudyStatus(rawValue: pair.value) {
                out[pair.key] = status
            }
        }
    }

    private func persistStatusOverrides() {
        let raw = studyStatuses.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: statusDefaultsKey)
        }
    }
}

private struct WorklistStudyActions: View {
    let study: PACSWorklistStudy
    let onOpen: () -> Void
    let onStatus: (WorklistStudyStatus) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onOpen()
            } label: {
                Label("Open", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Menu {
                ForEach(WorklistStudyStatus.allCases) { status in
                    Button(status.displayName) {
                        onStatus(status)
                    }
                }
            } label: {
                Label(study.status.displayName, systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct WorklistStudyRow: View {
    let study: PACSWorklistStudy

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                WorklistStatusBadge(status: study.status)
                Text(study.patientName.isEmpty ? "Unknown patient" : study.patientName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(study.modalitySummary.isEmpty ? "-" : study.modalitySummary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Text(study.patientID.isEmpty ? "No MRN" : study.patientID)
                if !study.accessionNumber.isEmpty {
                    Text(study.accessionNumber)
                }
                if !study.studyDate.isEmpty {
                    Text(displayDate(study.studyDate))
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)

            Text(study.studyDescription.isEmpty ? "Untitled study" : study.studyDescription)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("\(study.seriesCount) series")
                Text("\(study.instanceCount) images")
                if !study.referringPhysicianName.isEmpty {
                    Text(study.referringPhysicianName)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func displayDate(_ dicomDate: String) -> String {
        guard dicomDate.count == 8 else { return dicomDate }
        let year = dicomDate.prefix(4)
        let monthStart = dicomDate.index(dicomDate.startIndex, offsetBy: 4)
        let dayStart = dicomDate.index(dicomDate.startIndex, offsetBy: 6)
        let month = dicomDate[monthStart..<dayStart]
        let day = dicomDate[dayStart...]
        return "\(month)/\(day)/\(year)"
    }
}

private struct WorklistStatusBadge: View {
    let status: WorklistStudyStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.displayName)
    }

    private var color: Color {
        switch status {
        case .unread: return .blue
        case .inProgress: return .orange
        case .complete: return .green
        case .flagged: return .red
        }
    }
}

private struct WorklistSeriesRow: View {
    let entry: PACSIndexedSeriesSnapshot

    var body: some View {
        HStack(spacing: 10) {
            modalityBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.seriesDescription.isEmpty ? "Series" : entry.seriesDescription)
                    .font(.system(size: 11))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !entry.bodyPartExamined.isEmpty {
                        Text(entry.bodyPartExamined)
                    }
                    Text(entry.kind.displayName)
                    Text("\(entry.instanceCount) images")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 11))
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

private struct EmptyBrowserRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text(title)
                    .foregroundColor(.secondary)
                Text(subtitle)
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
