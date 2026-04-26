import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum StudyBrowserMode: String, CaseIterable, Identifiable {
    case worklist
    case archives
    case viewer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .worklist: return "Worklist"
        case .archives: return "Archives"
        case .viewer: return "Viewer"
        }
    }

    var systemImage: String {
        switch self {
        case .worklist: return "list.clipboard"
        case .archives: return "externaldrive.connected.to.line.below"
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
    @State private var indexFetchLimit: Int = 25_000
    @State private var statusFilter: WorklistStatusFilter = .all
    @State private var modalityFilter: String = "All"
    @State private var dateFilter: WorklistDateFilter = .all
    @State private var archiveFilterID: String = PACSArchiveScope.allID
    @State private var studyStatuses: [String: WorklistStudyStatus] = [:]
    @State private var expandedStudyIDs: Set<String> = []
    @State private var isDropTargeted: Bool = false

    private let indexPageSize = 25_000
    private let statusDefaultsKey = "Tracer.WorklistStudyStatuses"

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TracerTheme.hairline).frame(height: 1)

            if !vm.recentVolumes.isEmpty {
                recentVolumesStrip
                Rectangle().fill(TracerTheme.hairline).frame(height: 1)
            }

            Group {
                switch browserMode {
                case .worklist:
                    worklistContent
                case .archives:
                    archivesContent
                case .viewer:
                    viewerContent
                }
            }
            .searchable(text: $searchText, prompt: searchPrompt)
        }
        .navigationTitle(browserMode.displayName)
        .tint(TracerTheme.accent)
        .background(TracerTheme.worklistGradient)
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
        // Accept DICOM files / directories / NIfTI files dropped from Finder.
        // `UTType.fileURL` matches anything dragged off the filesystem; the
        // dispatcher below sorts volumes vs directories vs overlays.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                dropHighlightOverlay
            }
        }
    }

    private var dropHighlightOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(TracerTheme.accentBright, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(TracerTheme.accent.opacity(0.08))
            .padding(6)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 28))
                    Text("Drop DICOM folder or NIfTI file")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(TracerTheme.accentBright)
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - Drag and drop dispatcher

    /// Route one or more drag-and-drop providers to the right loader based
    /// on the URL's extension.  A folder is treated as a DICOM directory;
    /// `.nii` / `.nii.gz` is treated as a NIfTI volume; `.dcm` / `.IMA`
    /// are opened via their parent directory (nnU-Net / loader scans the
    /// whole series).  Anything else is skipped with a status message.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let resolved = url
            Task { @MainActor in
                await dispatchDroppedURL(resolved)
            }
        }
        return true
    }

    @MainActor
    private func dispatchDroppedURL(_ url: URL) async {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            vm.statusMessage = "Dropped item no longer exists at \(url.path)."
            return
        }

        let lowercased = url.lastPathComponent.lowercased()

        if isDirectory.boolValue {
            // Directory — DICOM series or a folder to index.
            await vm.loadDICOMDirectory(url: url)
            return
        }

        if NIfTILoader.isVolumeFile(url)
            || lowercased.hasSuffix(".nii")
            || lowercased.hasSuffix(".nii.gz") {
            await vm.loadNIfTI(url: url)
            return
        }

        if lowercased.hasSuffix(".dcm")
            || lowercased.hasSuffix(".ima")
            || lowercased.hasSuffix(".dicom") {
            // Single DICOM file dropped — load its parent folder as a series.
            await vm.loadDICOMDirectory(url: url.deletingLastPathComponent())
            return
        }

        vm.statusMessage = "Unsupported dropped file: \(url.lastPathComponent)"
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
                .fill(TracerTheme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(TracerTheme.hairline, lineWidth: 1)
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
        case .CT:  return TracerTheme.accent
        case .MR:  return Color(red: 0.56, green: 0.58, blue: 0.82)
        case .PT:  return TracerTheme.pet
        case .SEG: return TracerTheme.label
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
            case .archives:
                archiveControls
            case .viewer:
                viewerControls
            }
        }
        .padding(8)
        .background(TracerTheme.worklistGradient)
    }

    private var headerCountText: String {
        switch browserMode {
        case .worklist:
            return "\(filteredWorklistStudies.count) studies · \(indexedTotalCount) series"
        case .archives:
            return "\(filteredArchiveScopes.count) folders · \(worklistStudies.count) studies"
        case .viewer:
            return "\(vm.loadedVolumes.count) volumes · \(vm.loadedSeries.count) scanned"
        }
    }

    private var searchPrompt: String {
        switch browserMode {
        case .worklist:
            return "Search worklist..."
        case .archives:
            return "Search archives..."
        case .viewer:
            return "Search viewer session..."
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    worklistStatusPicker
                    worklistModalityPicker
                    worklistDatePicker
                }

                VStack(spacing: 6) {
                    worklistStatusPicker
                    HStack(spacing: 6) {
                        worklistModalityPicker
                        worklistDatePicker
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)

            if archiveFilterID != PACSArchiveScope.allID,
               let scope = archiveScopes.first(where: { $0.id == archiveFilterID }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundColor(TracerTheme.accent)
                    Text(scope.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        archiveFilterID = PACSArchiveScope.allID
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear archive filter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(TracerTheme.panelRaised)
                )
            }
        }
    }

    private var archiveControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onIndexFolder()
                } label: {
                    Label("Index Archive", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    archiveFilterID = PACSArchiveScope.allID
                    browserMode = .worklist
                } label: {
                    Label("All Studies", systemImage: "list.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Browse indexed roots, collections, and study folders")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var worklistStatusPicker: some View {
        Picker("Status", selection: $statusFilter) {
            ForEach(WorklistStatusFilter.allCases) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
    }

    private var worklistModalityPicker: some View {
        Picker("Modality", selection: $modalityFilter) {
            ForEach(modalityFilterOptions, id: \.self) { modality in
                Text(modality).tag(modality)
            }
        }
    }

    private var worklistDatePicker: some View {
        Picker("Date", selection: $dateFilter) {
            ForEach(WorklistDateFilter.allCases) { filter in
                Text(filter.displayName).tag(filter)
            }
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
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
    }

    private var archivesContent: some View {
        List {
            if !availableLocalArchiveShortcuts.isEmpty {
                Section("Local Datasets") {
                    ForEach(availableLocalArchiveShortcuts) { shortcut in
                        Button {
                            indexLocalArchive(shortcut)
                        } label: {
                            LocalArchiveShortcutRow(shortcut: shortcut)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isIndexing)
                    }
                }
            }

            if !filteredArchiveScopes.isEmpty {
                Section("Indexed Archives") {
                    ForEach(filteredArchiveScopes) { scope in
                        Button {
                            archiveFilterID = scope.id
                            browserMode = .worklist
                        } label: {
                            ArchiveScopeRow(scope: scope)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                archiveFilterID = scope.id
                                browserMode = .worklist
                            } label: {
                                Label("Show Studies", systemImage: "list.clipboard")
                            }
                            Button {
                                searchText = scope.title
                                browserMode = .worklist
                            } label: {
                                Label("Search This Name", systemImage: "magnifyingglass")
                            }
                        }
                    }
                }
            } else {
                EmptyBrowserRow(
                    systemImage: "externaldrive.connected.to.line.below",
                    title: "No indexed archives",
                    subtitle: "Index an archive root to browse collections and study folders"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
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
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
    }

    private var worklistStudies: [PACSWorklistStudy] {
        PACSWorklistStudy.grouped(from: indexedSeries, statuses: studyStatuses)
    }

    private var filteredWorklistStudies: [PACSWorklistStudy] {
        worklistStudies.filter {
            if archiveFilterID != PACSArchiveScope.allID,
               PACSArchiveScope.scopeID(for: $0) != archiveFilterID {
                return false
            }
            return $0.matches(
                searchText: searchText,
                statusFilter: statusFilter,
                modalityFilter: modalityFilter,
                dateFilter: dateFilter
            )
        }
    }

    private var archiveScopes: [PACSArchiveScope] {
        PACSArchiveScope.grouped(from: worklistStudies)
    }

    private var availableLocalArchiveShortcuts: [LocalArchiveShortcut] {
        LocalArchiveShortcut.known.filter(\.exists)
    }

    private var filteredArchiveScopes: [PACSArchiveScope] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return archiveScopes }
        return archiveScopes.filter { scope in
            scope.title.lowercased().contains(query)
            || scope.subtitle.lowercased().contains(query)
            || scope.path.lowercased().contains(query)
            || scope.modalitySummary.lowercased().contains(query)
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

    private func indexLocalArchive(_ shortcut: LocalArchiveShortcut) {
        guard !vm.isIndexing else { return }
        browserMode = .archives
        vm.statusMessage = "Indexing \(shortcut.title)..."
        Task { @MainActor in
            await vm.indexDirectory(url: shortcut.url, modelContext: modelContext)
            reloadIndexResults()
        }
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
        case .unread: return TracerTheme.accent
        case .inProgress: return TracerTheme.warning
        case .complete: return TracerTheme.label
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
        case .CT: return TracerTheme.accent
        case .MR: return Color(red: 0.56, green: 0.58, blue: 0.82)
        case .PT: return TracerTheme.pet
        case .SEG: return TracerTheme.label
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

private struct PACSArchiveScope: Identifiable, Hashable {
    static let allID = "__all_archives__"

    let id: String
    let path: String
    let title: String
    let subtitle: String
    let studyCount: Int
    let seriesCount: Int
    let instanceCount: Int
    let modalities: [String]

    var modalitySummary: String {
        modalities.joined(separator: "/")
    }

    static func grouped(from studies: [PACSWorklistStudy]) -> [PACSArchiveScope] {
        struct Accumulator {
            var path: String
            var studyIDs = Set<String>()
            var seriesCount = 0
            var instanceCount = 0
            var modalities = Set<String>()
        }

        var grouped: [String: Accumulator] = [:]
        for study in studies {
            let path = archivePath(for: study)
            var acc = grouped[path] ?? Accumulator(path: path)
            acc.studyIDs.insert(study.id)
            acc.seriesCount += study.seriesCount
            acc.instanceCount += study.instanceCount
            acc.modalities.formUnion(study.modalities)
            grouped[path] = acc
        }

        return grouped.values.map { acc in
            let title = archiveTitle(for: acc.path)
            let subtitle = archiveSubtitle(for: acc.path)
            return PACSArchiveScope(
                id: acc.path,
                path: acc.path,
                title: title,
                subtitle: subtitle,
                studyCount: acc.studyIDs.count,
                seriesCount: acc.seriesCount,
                instanceCount: acc.instanceCount,
                modalities: Array(acc.modalities).sorted()
            )
        }
        .sorted { lhs, rhs in
            if lhs.studyCount != rhs.studyCount { return lhs.studyCount > rhs.studyCount }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func scopeID(for study: PACSWorklistStudy) -> String {
        archivePath(for: study)
    }

    private static func archivePath(for study: PACSWorklistStudy) -> String {
        let firstSeries = study.series.first
        let firstPath = study.series.lazy.compactMap { series in
            series.filePaths.first ?? (series.sourcePath.isEmpty ? nil : series.sourcePath)
        }.first ?? study.sourcePath
        return meaningfulArchivePath(filePath: firstPath,
                                     sourcePath: firstSeries?.sourcePath ?? study.sourcePath)
    }

    private static func meaningfulArchivePath(filePath: String, sourcePath: String) -> String {
        let components = pathComponents(filePath)

        if let manifest = components.firstIndex(where: { $0.hasPrefix("manifest-") }),
           manifest + 1 < components.count {
            return "/" + components[0...manifest + 1].joined(separator: "/")
        }

        if let fdg = components.firstIndex(of: "FDG-PET-CT-Lesions"),
           fdg + 1 < components.count {
            return "/" + components[0...fdg + 1].joined(separator: "/")
        }

        let sourceComponents = pathComponents(sourcePath)
        if !sourceComponents.isEmpty,
           components.starts(with: sourceComponents),
           components.count > sourceComponents.count {
            let relStart = sourceComponents.count
            let relEnd = min(components.count - 1, relStart + 1)
            return "/" + components[0...relEnd].joined(separator: "/")
        }

        let parent = (filePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? sourcePath : parent
    }

    private static func archiveTitle(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "Indexed Archive" : last
    }

    private static func archiveSubtitle(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? path : parent
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

private struct LocalArchiveShortcut: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let path: String

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static let known: [LocalArchiveShortcut] = [
        LocalArchiveShortcut(
            id: "fdg-pet-ct-lesions",
            title: "FDG PET/CT Lesions",
            subtitle: "NIfTI lesion archive",
            path: "/Users/ahmedabdelrahman/Desktop/Datasets/FDG-PET-CT-Lesions"
        ),
        LocalArchiveShortcut(
            id: "pet-all-10-16-ncia",
            title: "PET all 10/16 NCIA",
            subtitle: "Large TCIA PET archive",
            path: "/Users/ahmedabdelrahman/Desktop/Datasets/PET all 10 16 ncia"
        ),
        LocalArchiveShortcut(
            id: "prostate-ncia",
            title: "Prostate NCIA",
            subtitle: "CMB-PCA prostate archive",
            path: "/Users/ahmedabdelrahman/Desktop/Datasets/Prostate ncia/manifest-1759972609262"
        ),
        LocalArchiveShortcut(
            id: "openneuro-ds004054",
            title: "OpenNeuro ds004054",
            subtitle: "Aerobic Glycolysis PET/MRI BIDS",
            path: "/Users/ahmedabdelrahman/Desktop/Datasets/ds004054-1.0.0"
        )
    ]
}

private struct LocalArchiveShortcutRow: View {
    let shortcut: LocalArchiveShortcut

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TracerTheme.accentBright)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(shortcut.subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(shortcut.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct ArchiveScopeRow: View {
    let scope: PACSArchiveScope

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TracerTheme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(scope.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if !scope.modalitySummary.isEmpty {
                        Text(scope.modalitySummary)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Text(scope.subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(scope.studyCount) studies")
                    Text("\(scope.seriesCount) series")
                    Text("\(scope.instanceCount) images")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
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
        case .CT: return TracerTheme.accent
        case .MR: return Color(red: 0.56, green: 0.58, blue: 0.82)
        case .PT: return TracerTheme.pet
        case .SEG: return TracerTheme.label
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
        case .CT: return TracerTheme.accent
        case .MR: return Color(red: 0.56, green: 0.58, blue: 0.82)
        case .PT: return TracerTheme.pet
        case .SEG: return TracerTheme.label
        default: return .gray
        }
    }
}
