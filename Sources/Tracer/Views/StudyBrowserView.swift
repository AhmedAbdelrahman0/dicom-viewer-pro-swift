import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private enum StudyBrowserMode: String, CaseIterable, Identifiable {
    case worklist
    case vna
    case archives
    case viewer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .worklist: return "Worklist"
        case .vna: return "VNA"
        case .archives: return "Archives"
        case .viewer: return "Viewer"
        }
    }

    var systemImage: String {
        switch self {
        case .worklist: return "list.clipboard"
        case .vna: return "network"
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
    @State private var worklistDisplayLimit: Int = 300
    @State private var statusFilter: WorklistStatusFilter = .all
    @State private var modalityFilter: String = "All"
    @State private var dateFilter: WorklistDateFilter = .all
    @State private var archiveFilterID: String = PACSArchiveScope.allID
    @State private var studyStatuses: [String: WorklistStudyStatus] = [:]
    @State private var expandedStudyIDs: Set<String> = []
    @State private var expandedVNAStudyIDs: Set<String> = []
    @State private var expandedWorklistTreeNodeIDs: Set<String> = []
    @State private var collapsedWorklistTreeNodeIDs: Set<String> = []
    @State private var expandedArchiveTreeNodeIDs: Set<String> = []
    @State private var collapsedArchiveTreeNodeIDs: Set<String> = []
    @State private var removedWorklistStudyIDs: Set<String> = []
    @State private var vnaConnectionName: String = ""
    @State private var vnaBaseURL: String = ""
    @State private var vnaBearerToken: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var fileBrowserCurrentURL: URL?
    @State private var fileBrowserEntries: [LocalFileBrowserEntry] = []
    @State private var fileBrowserError: String?
    @State private var fileBrowserLoadTask: Task<Void, Never>?
    @State private var indexReloadTask: Task<Void, Never>?

    private let worklistDisplayPageSize = 300
    private let statusDefaultsKey = "Tracer.WorklistStudyStatuses"
    private let removedWorklistDefaultsKey = "Tracer.WorklistRemovedStudyIDs"

    private struct OpenedWorklistBucket {
        var id: String
        var patientID: String
        var patientName: String
        var accessionNumber: String
        var studyUID: String
        var studyDescription: String
        var sourcePath: String
        var series: [String: PACSIndexedSeriesSnapshot]
        var openedAt: Date
    }

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
                case .vna:
                    vnaContent
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
            loadRemovedWorklistStudies()
            vm.reloadSavedArchiveRoots()
            vm.reloadVNAConnections()
            syncVNAConnectionForm()
            reloadIndexResults()
        }
        .onChange(of: searchText) { _, _ in
            if browserMode == .archives {
                worklistDisplayLimit = worklistDisplayPageSize
                scheduleIndexResultsReload()
            } else {
                worklistDisplayLimit = worklistDisplayPageSize
            }
        }
        .onChange(of: browserMode) { _, mode in
            if mode == .archives {
                scheduleIndexResultsReload(delayNanoseconds: 0)
            }
        }
        .onChange(of: vm.activeVNAConnectionID) { _, _ in syncVNAConnectionForm() }
        .onChange(of: statusFilter) { _, _ in worklistDisplayLimit = worklistDisplayPageSize }
        .onChange(of: modalityFilter) { _, _ in worklistDisplayLimit = worklistDisplayPageSize }
        .onChange(of: dateFilter) { _, _ in worklistDisplayLimit = worklistDisplayPageSize }
        .onChange(of: archiveFilterID) { _, _ in worklistDisplayLimit = worklistDisplayPageSize }
        .onChange(of: vm.indexRevision) { _, _ in
            vm.reloadSavedArchiveRoots()
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
        guard !providers.isEmpty else {
            vm.statusMessage = "Drop did not include any files."
            return false
        }

        var acceptedProvider = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            acceptedProvider = true
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    if let error {
                        vm.statusMessage = "Drop failed: \(error.localizedDescription)"
                        return
                    }
                    guard let url else {
                        vm.statusMessage = "Drop failed: no file URL was provided."
                        return
                    }
                    await dispatchDroppedURL(url)
                }
            }
        }
        if !acceptedProvider {
            vm.statusMessage = "Drop did not include a readable file URL."
        }
        return acceptedProvider
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

        if MedicalVolumeFileIO.isVolumeFile(url)
            || lowercased.hasSuffix(".nii")
            || lowercased.hasSuffix(".nii.gz")
            || lowercased.hasSuffix(".mha")
            || lowercased.hasSuffix(".mhd") {
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
                                Label("Remove \(recent.displaySeriesDescription)",
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
                Text(recent.displaySeriesDescription)
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
        let patient = recent.displayPatientOrStudyTitle.isEmpty ? "-" : recent.displayPatientOrStudyTitle
        return "\(modality) · \(patient)"
    }

    private func recentTooltip(_ recent: RecentVolume) -> String {
        let lines: [String] = [
            "Reopen: \(recent.displaySeriesDescription)",
            "Study: \(recent.displayStudyDescription.isEmpty ? "-" : recent.displayStudyDescription)",
            "Patient: \(recent.displayPatientName.isEmpty ? "-" : recent.displayPatientName)",
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
            case .vna:
                vnaControls
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
            let seriesCount = filteredWorklistStudies.reduce(0) { $0 + $1.seriesCount }
            return "\(filteredWorklistStudies.count) opened · \(seriesCount) series"
        case .vna:
            return "\(vm.vnaConnections.count) VNAs · \(vm.vnaStudies.count) studies"
        case .archives:
            return "\(vm.savedArchiveRoots.count) roots · \(indexedArchiveStudies.count) studies · \(indexedTotalCount) series"
        case .viewer:
            return "\(vm.viewerSessions.count) sessions · \(vm.openStudies.count) studies · \(vm.activeSessionVolumes.count) series"
        }
    }

    private var searchPrompt: String {
        switch browserMode {
        case .worklist:
            return "Search previously opened studies..."
        case .vna:
            return "Search patient, accession, or study date..."
        case .archives:
            return "Search archives..."
        case .viewer:
            return "Search viewer session or files..."
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
               let root = selectedSavedArchiveRoot {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .foregroundColor(TracerTheme.accentBright)
                    Text(root.displayName)
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
            } else if archiveFilterID != PACSArchiveScope.allID,
                      let node = selectedWorklistTreeNode ?? selectedArchiveTreeNode {
                HStack(spacing: 6) {
                    Image(systemName: node.systemImage)
                        .foregroundColor(TracerTheme.accent)
                    Text(node.title)
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
            } else if archiveFilterID != PACSArchiveScope.allID,
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

    private var vnaControls: some View {
        VStack(spacing: 8) {
            if !vm.vnaConnections.isEmpty {
                Picker("Connection", selection: activeVNAConnectionBinding) {
                    ForEach(vm.vnaConnections) { connection in
                        Text(connection.displayName).tag(connection.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            TextField("Name", text: $vnaConnectionName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            TextField("DICOMweb URL", text: $vnaBaseURL)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .autocorrectionDisabled()

            SecureField("Bearer token", text: $vnaBearerToken)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    saveVNAConnectionFromForm()
                } label: {
                    Label("Save", systemImage: "server.rack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    searchVNA()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.activeVNAConnection == nil || vm.isVNASearching)
            }

            if vm.isVNASearching || vm.isVNARetrieving {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(vm.isVNARetrieving ? "Retrieving" : "Searching")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var activeVNAConnectionBinding: Binding<UUID> {
        Binding(
            get: { vm.activeVNAConnectionID ?? vm.vnaConnections.first?.id ?? UUID() },
            set: { id in
                vm.selectVNAConnection(id: id)
                syncVNAConnectionForm()
            }
        )
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
                openFileBrowserRootPanel()
            } label: {
                Label("Browse Directory", systemImage: "folder.badge.gearshape")
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

    private var worklistContent: some View {
        List {
            if !worklistTreeRoots.isEmpty {
                Section("Previously Opened Studies") {
                    ForEach(worklistTreeRoots) { node in
                        ArchiveTreeNodeView(
                            node: node,
                            depth: 0,
                            expansion: worklistTreeExpansionBinding,
                            onShowBranch: showWorklistTreeBranch,
                            onOpenStudy: openStudy,
                            onSetStatus: { status, study in setStatus(status, for: study) },
                            onRemoveStudy: removeStudyFromWorklist
                        )
                    }

                    if filteredWorklistStudies.count > displayedWorklistStudies.count {
                        Button {
                            worklistDisplayLimit += worklistDisplayPageSize
                        } label: {
                            Label("Show more studies (\(displayedWorklistStudies.count)/\(filteredWorklistStudies.count))",
                                  systemImage: "chevron.down.circle")
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
                    subtitle: "Open a study from Archives, VNA, or local files to populate this worklist"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
    }

    private var vnaContent: some View {
        List {
            if let error = vm.vnaLastError, !error.isEmpty {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            if !vm.vnaConnections.isEmpty {
                Section("Connections") {
                    ForEach(vm.vnaConnections) { connection in
                        HStack(spacing: 8) {
                            Button {
                                vm.selectVNAConnection(id: connection.id)
                                syncVNAConnectionForm()
                            } label: {
                                VNAConnectionRow(connection: connection,
                                                 isActive: vm.activeVNAConnectionID == connection.id)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button {
                                    vm.selectVNAConnection(id: connection.id)
                                    syncVNAConnectionForm()
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    vm.deleteVNAConnection(id: connection.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                    }
                }
            }

            if !vm.vnaStudies.isEmpty {
                Section("Remote Studies") {
                    ForEach(vm.vnaStudies) { study in
                        DisclosureGroup(isExpanded: vnaExpansionBinding(for: study.id)) {
                            VNAStudyActions(
                                study: study,
                                isBusy: vm.isVNASearching || vm.isVNARetrieving,
                                onOpen: { openVNAStudy(study) },
                                onSeries: { loadVNASeries(study) }
                            )

                            let series = vm.vnaSeries(for: study)
                            if series.isEmpty {
                                Button {
                                    loadVNASeries(study)
                                } label: {
                                    Label("Load Series", systemImage: "square.stack.3d.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(vm.isVNASearching)
                            } else {
                                ForEach(series) { entry in
                                    Button {
                                        openVNASeries(entry, study: study)
                                    } label: {
                                        VNASeriesRow(series: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(vm.isVNARetrieving)
                                }
                            }
                        } label: {
                            VNAStudyRow(study: study)
                        }
                        .contextMenu {
                            Button {
                                openVNAStudy(study)
                            } label: {
                                Label("Open Preferred Series", systemImage: "rectangle.3.group")
                            }
                            Button {
                                loadVNASeries(study)
                            } label: {
                                Label("Load Series", systemImage: "square.stack.3d.up")
                            }
                        }
                    }
                }
            } else {
                EmptyBrowserRow(
                    systemImage: vm.vnaConnections.isEmpty ? "network.slash" : "network",
                    title: vm.vnaConnections.isEmpty ? "No VNA connection" : "No remote studies",
                    subtitle: vm.vnaConnections.isEmpty ? "Add a DICOMweb endpoint" : "Search a patient, accession, or date"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
    }

    private var archivesContent: some View {
        List {
            if !filteredSavedArchiveRoots.isEmpty {
                Section("Saved Archives") {
                    ForEach(filteredSavedArchiveRoots) { root in
                        Button {
                            showSavedArchiveRoot(root)
                        } label: {
                            SavedArchiveRootRow(root: root,
                                                stats: archiveStats(for: root))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                showSavedArchiveRoot(root)
                            } label: {
                                Label("Show Indexed Studies", systemImage: "list.clipboard")
                            }
                            Button {
                                browseSavedArchiveRoot(root)
                            } label: {
                                Label("Browse Directory", systemImage: "folder")
                            }
                            .disabled(!root.exists)
                            Button {
                                indexSavedArchiveRoot(root)
                            } label: {
                                Label("Refresh Index", systemImage: "arrow.clockwise")
                            }
                            .disabled(!root.exists || vm.isIndexing)
                            Button(role: .destructive) {
                                forgetSavedArchiveRoot(root)
                            } label: {
                                Label("Forget Directory", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }

            if !availableLocalArchiveShortcuts.isEmpty {
                Section("Local Datasets") {
                    ForEach(availableLocalArchiveShortcuts) { shortcut in
                        Button {
                            indexLocalArchive(shortcut)
                        } label: {
                            LocalArchiveShortcutRow(shortcut: shortcut,
                                                    stats: archiveStats(forPath: shortcut.path))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isIndexing)
                    }
                }
            }

            if !filteredArchiveTreeRoots.isEmpty {
                Section("Dataset Tree") {
                    ForEach(filteredArchiveTreeRoots) { node in
                        ArchiveTreeNodeView(
                            node: node,
                            depth: 0,
                            expansion: archiveTreeExpansionBinding,
                            onShowBranch: showArchiveTreeBranch,
                            onOpenStudy: openStudy,
                            onSetStatus: { status, study in setStatus(status, for: study) },
                            onRemoveStudy: nil
                        )
                    }
                }
            } else if filteredSavedArchiveRoots.isEmpty && availableLocalArchiveShortcuts.isEmpty {
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
            if fileBrowserCurrentURL != nil {
                Section("Directory Browser") {
                    fileBrowserHeaderRow

                    if let fileBrowserError {
                        Text(fileBrowserError)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }

                    if filteredFileBrowserEntries.isEmpty {
                        EmptyBrowserRow(
                            systemImage: "folder",
                            title: "No matching files",
                            subtitle: "Adjust search or choose another directory"
                        )
                    } else {
                        ForEach(filteredFileBrowserEntries) { entry in
                            FileBrowserEntryRow(
                                entry: entry,
                                onOpen: { openFileBrowserEntry(entry) },
                                onLoad: { loadFileBrowserEntry(entry) },
                                onIndex: { indexFileBrowserEntry(entry) }
                            )
                        }
                    }
                }
            }

            if !vm.viewerSessions.isEmpty || vm.activeViewerSession != nil {
                Section("Live Sessions") {
                    HStack(spacing: 8) {
                        Button {
                            vm.saveCurrentViewerSession()
                        } label: {
                            Label("Save", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            vm.newViewerSession()
                        } label: {
                            Label("New", systemImage: "plus.rectangle.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    ForEach(vm.viewerSessions) { session in
                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.openViewerSession(id: session.id) }
                            } label: {
                                ViewerSessionRow(session: session,
                                                 isActive: vm.activeViewerSessionID == session.id)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button {
                                    Task { await vm.openViewerSession(id: session.id) }
                                } label: {
                                    Label("Open Session", systemImage: "rectangle.3.group")
                                }
                                Button(role: .destructive) {
                                    vm.deleteViewerSession(id: session.id)
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                    }
                }
            }

            if !vm.openStudies.isEmpty {
                Section("Open Studies") {
                    ForEach(vm.openStudies) { study in
                        HStack(spacing: 8) {
                            Button {
                                vm.displayOpenStudy(id: study.studyKey)
                            } label: {
                                OpenStudyRow(study: study,
                                             isActive: vm.activeOpenStudy?.studyKey == study.studyKey)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                vm.closeOpenStudy(id: study.studyKey)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Close this study in the active session")
                        }
                    }
                }
            }

            if !filteredLoadedVolumes.isEmpty {
                Section("Session Series") {
                    Button(role: .destructive) {
                        vm.closeAllVolumes()
                    } label: {
                        Label("Close Active Session Series", systemImage: "xmark.square")
                    }
                    .buttonStyle(.plain)

                    ForEach(filteredLoadedVolumes) { volume in
                        HStack(spacing: 8) {
                            Button {
                                vm.displayVolume(volume)
                            } label: {
                                VolumeRow(volume: volume)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                vm.closeVolume(volume)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Close this loaded series")
                        }
                        .contextMenu {
                            Button {
                                vm.displayVolume(volume)
                            } label: {
                                Label("Show Series", systemImage: "eye")
                            }
                            Button(role: .destructive) {
                                vm.closeVolume(volume)
                            } label: {
                                Label("Close Series", systemImage: "xmark.circle")
                            }
                        }
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

            if fileBrowserCurrentURL == nil && filteredLoadedVolumes.isEmpty && filteredSeries.isEmpty {
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

    private var indexedArchiveStudies: [PACSWorklistStudy] {
        PACSWorklistStudy.grouped(from: indexedSeries, statuses: studyStatuses)
    }

    private var worklistStudies: [PACSWorklistStudy] {
        openedHistoryWorklistStudies.filter { !removedWorklistStudyIDs.contains($0.id) }
    }

    private var filteredWorklistStudies: [PACSWorklistStudy] {
        worklistStudies.filter {
            if archiveFilterID != PACSArchiveScope.allID {
                if let root = selectedSavedArchiveRoot {
                    guard study($0, belongsTo: root) else { return false }
                } else if let treePath = PACSArchiveTreeNode.filterPath(from: archiveFilterID) {
                    guard study($0, belongsToPathPrefix: treePath) else { return false }
                } else if PACSArchiveScope.scopeID(for: $0) != archiveFilterID {
                    return false
                }
            }
            return $0.matches(
                searchText: searchText,
                statusFilter: statusFilter,
                modalityFilter: modalityFilter,
                dateFilter: dateFilter
            )
        }
    }

    private var displayedWorklistStudies: [PACSWorklistStudy] {
        Array(filteredWorklistStudies.prefix(worklistDisplayLimit))
    }

    private var allWorklistTreeRoots: [PACSArchiveTreeNode] {
        PACSArchiveTreeBuilder.roots(
            from: worklistStudies,
            savedRoots: vm.savedArchiveRoots,
            shortcuts: LocalArchiveShortcut.known
        )
    }

    private var worklistTreeRoots: [PACSArchiveTreeNode] {
        PACSArchiveTreeBuilder.roots(
            from: displayedWorklistStudies,
            savedRoots: vm.savedArchiveRoots,
            shortcuts: LocalArchiveShortcut.known
        )
    }

    private var openedHistoryWorklistStudies: [PACSWorklistStudy] {
        var buckets: [String: OpenedWorklistBucket] = [:]
        var knownSnapshotIDs = Set<String>()

        for session in vm.viewerSessions {
            let studyByKey = session.studies.reduce(into: [String: ViewerSessionStudyReference]()) { result, study in
                result[study.studyKey] = study
            }
            let volumesByStudy = Dictionary(grouping: session.volumes, by: \.studyKey)

            for (studyKey, references) in volumesByStudy {
                let usableReferences = references.filter { !$0.sourceFiles.isEmpty }
                guard !usableReferences.isEmpty else { continue }

                let studyReference = studyByKey[studyKey]
                let id = historyWorklistID(forStudyKey: studyKey)
                var bucket = buckets[id] ?? makeOpenedBucket(
                    id: id,
                    studyKey: studyKey,
                    study: studyReference,
                    fallback: usableReferences.first,
                    openedAt: session.modifiedAt
                )
                mergeHistoryMetadata(
                    into: &bucket,
                    study: studyReference,
                    fallback: usableReferences.first,
                    openedAt: session.modifiedAt
                )

                for reference in usableReferences {
                    let snapshot = historySnapshot(from: reference,
                                                   study: studyReference,
                                                   openedAt: session.modifiedAt)
                    bucket.series[snapshot.id] = snapshot
                    knownSnapshotIDs.insert(snapshot.id)
                }
                buckets[id] = bucket
            }
        }

        for recent in vm.recentVolumes where !recent.sourceFiles.isEmpty {
            let snapshotID = historySnapshotID(for: recent.id)
            guard !knownSnapshotIDs.contains(snapshotID) else { continue }

            let id = historyWorklistID(for: recent)
            var bucket = buckets[id] ?? makeOpenedBucket(id: id, recent: recent)
            mergeHistoryMetadata(into: &bucket, recent: recent)
            let snapshot = historySnapshot(from: recent)
            bucket.series[snapshot.id] = snapshot
            buckets[id] = bucket
            knownSnapshotIDs.insert(snapshot.id)
        }

        return buckets.values
            .compactMap(makeWorklistStudy(from:))
            .sorted(by: historyStudySort)
    }

    private func makeOpenedBucket(id: String,
                                  studyKey: String,
                                  study: ViewerSessionStudyReference?,
                                  fallback: ViewerSessionVolumeReference?,
                                  openedAt: Date) -> OpenedWorklistBucket {
        OpenedWorklistBucket(
            id: id,
            patientID: firstMeaningful(study?.patientID ?? "", fallback?.patientID ?? ""),
            patientName: firstMeaningful(study?.patientName ?? "", fallback?.patientName ?? ""),
            accessionNumber: study?.accessionNumber ?? "",
            studyUID: firstMeaningful(study?.studyUID ?? "", historyStudyUID(from: studyKey)),
            studyDescription: firstMeaningful(study?.studyDescription ?? "", fallback?.studyDescription ?? ""),
            sourcePath: fallback.map { historySourcePath(for: $0.sourceFiles) } ?? "",
            series: [:],
            openedAt: openedAt
        )
    }

    private func makeOpenedBucket(id: String, recent: RecentVolume) -> OpenedWorklistBucket {
        OpenedWorklistBucket(
            id: id,
            patientID: "",
            patientName: recent.patientName,
            accessionNumber: "",
            studyUID: "",
            studyDescription: firstMeaningful(recent.studyDescription, recent.displayStudyDescription),
            sourcePath: historySourcePath(for: recent.sourceFiles),
            series: [:],
            openedAt: recent.openedAt
        )
    }

    private func mergeHistoryMetadata(into bucket: inout OpenedWorklistBucket,
                                      study: ViewerSessionStudyReference?,
                                      fallback: ViewerSessionVolumeReference?,
                                      openedAt: Date) {
        bucket.patientID = firstMeaningful(bucket.patientID, study?.patientID ?? "", fallback?.patientID ?? "")
        bucket.patientName = firstMeaningful(bucket.patientName, study?.patientName ?? "", fallback?.patientName ?? "")
        bucket.accessionNumber = firstMeaningful(bucket.accessionNumber, study?.accessionNumber ?? "")
        bucket.studyUID = firstMeaningful(bucket.studyUID, study?.studyUID ?? "")
        bucket.studyDescription = firstMeaningful(bucket.studyDescription,
                                                 study?.studyDescription ?? "",
                                                 fallback?.studyDescription ?? "")
        if bucket.sourcePath.isEmpty, let fallback {
            bucket.sourcePath = historySourcePath(for: fallback.sourceFiles)
        }
        bucket.openedAt = max(bucket.openedAt, openedAt)
    }

    private func mergeHistoryMetadata(into bucket: inout OpenedWorklistBucket,
                                      recent: RecentVolume) {
        bucket.patientName = firstMeaningful(bucket.patientName, recent.patientName)
        bucket.studyDescription = firstMeaningful(bucket.studyDescription,
                                                 recent.studyDescription,
                                                 recent.displayStudyDescription)
        if bucket.sourcePath.isEmpty {
            bucket.sourcePath = historySourcePath(for: recent.sourceFiles)
        }
        bucket.openedAt = max(bucket.openedAt, recent.openedAt)
    }

    private func makeWorklistStudy(from bucket: OpenedWorklistBucket) -> PACSWorklistStudy? {
        let series = bucket.series.values.sorted(by: historySeriesSort)
        guard let first = series.first else { return nil }
        return PACSWorklistStudy(
            id: bucket.id,
            patientID: firstMeaningful(bucket.patientID, first.patientID),
            patientName: firstMeaningful(bucket.patientName, first.patientName),
            accessionNumber: bucket.accessionNumber,
            studyUID: firstMeaningful(bucket.studyUID, first.studyUID),
            studyDescription: firstMeaningful(bucket.studyDescription, first.studyDescription),
            studyDate: "",
            studyTime: "",
            referringPhysicianName: "",
            sourcePath: firstMeaningful(bucket.sourcePath, first.sourcePath),
            series: series,
            status: studyStatuses[bucket.id] ?? .unread,
            indexedAt: bucket.openedAt
        )
    }

    private func historySnapshot(from reference: ViewerSessionVolumeReference,
                                 study: ViewerSessionStudyReference?,
                                 openedAt: Date) -> PACSIndexedSeriesSnapshot {
        PACSIndexedSeriesSnapshot(
            id: historySnapshotID(for: reference.volumeIdentity),
            kind: historyKind(reference.kind),
            seriesUID: historySeriesUID(from: reference.volumeIdentity),
            studyUID: firstMeaningful(study?.studyUID ?? "", historyStudyUID(from: reference.studyKey)),
            modality: reference.modality,
            patientID: firstMeaningful(study?.patientID ?? "", reference.patientID),
            patientName: firstMeaningful(study?.patientName ?? "", reference.patientName),
            accessionNumber: study?.accessionNumber ?? "",
            studyDescription: firstMeaningful(study?.studyDescription ?? "", reference.studyDescription),
            studyDate: "",
            seriesDescription: firstMeaningful(reference.seriesDescription, "Series"),
            sourcePath: historySourcePath(for: reference.sourceFiles),
            filePaths: reference.sourceFiles,
            instanceCount: max(reference.sourceFiles.count, 1),
            indexedAt: openedAt
        )
    }

    private func historySnapshot(from recent: RecentVolume) -> PACSIndexedSeriesSnapshot {
        PACSIndexedSeriesSnapshot(
            id: historySnapshotID(for: recent.id),
            kind: historyKind(recent.kind),
            seriesUID: historySeriesUID(from: recent.id),
            studyUID: "",
            modality: recent.modality,
            patientID: "",
            patientName: recent.patientName,
            studyDescription: firstMeaningful(recent.studyDescription, recent.displayStudyDescription),
            studyDate: "",
            seriesDescription: firstMeaningful(recent.seriesDescription, recent.displaySeriesDescription, "Series"),
            sourcePath: historySourcePath(for: recent.sourceFiles),
            filePaths: recent.sourceFiles,
            instanceCount: max(recent.sourceFiles.count, 1),
            indexedAt: recent.openedAt
        )
    }

    private func historyWorklistID(forStudyKey studyKey: String) -> String {
        studyKey
    }

    private func historyWorklistID(for recent: RecentVolume) -> String {
        guard let first = recent.sourceFiles.first, !first.isEmpty else {
            return "volume:\(recent.id)"
        }
        let parent = URL(fileURLWithPath: first).deletingLastPathComponent().path
        return parent.isEmpty ? "volume:\(recent.id)" : "folder:\(parent)"
    }

    private func historySnapshotID(for volumeIdentity: String) -> String {
        "history:\(volumeIdentity)"
    }

    private func historyStudyUID(from studyKey: String) -> String {
        let prefix = "study:"
        guard studyKey.hasPrefix(prefix) else { return "" }
        return String(studyKey.dropFirst(prefix.count))
    }

    private func historySeriesUID(from volumeIdentity: String) -> String {
        let prefix = "series:"
        guard volumeIdentity.hasPrefix(prefix) else { return "" }
        return String(volumeIdentity.dropFirst(prefix.count))
    }

    private func historyKind(_ kind: RecentVolume.Kind) -> PACSIndexedSeriesKind {
        switch kind {
        case .dicom: return .dicom
        case .nifti: return .nifti
        }
    }

    private func historySourcePath(for sourceFiles: [String]) -> String {
        guard let first = sourceFiles.first, !first.isEmpty else { return "" }
        return URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    private func historyStudySort(_ lhs: PACSWorklistStudy,
                                  _ rhs: PACSWorklistStudy) -> Bool {
        let lhsRank = worklistStatusSortRank(lhs.status)
        let rhsRank = worklistStatusSortRank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.indexedAt != rhs.indexedAt { return lhs.indexedAt > rhs.indexedAt }
        if lhs.patientName != rhs.patientName {
            return lhs.patientName.localizedStandardCompare(rhs.patientName) == .orderedAscending
        }
        if lhs.studyDescription != rhs.studyDescription {
            return lhs.studyDescription.localizedStandardCompare(rhs.studyDescription) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func historySeriesSort(_ lhs: PACSIndexedSeriesSnapshot,
                                   _ rhs: PACSIndexedSeriesSnapshot) -> Bool {
        let lhsRank = modalitySortRank(lhs.modality)
        let rhsRank = modalitySortRank(rhs.modality)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.seriesDescription != rhs.seriesDescription {
            return lhs.seriesDescription.localizedStandardCompare(rhs.seriesDescription) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func worklistStatusSortRank(_ status: WorklistStudyStatus) -> Int {
        switch status {
        case .flagged: return 0
        case .unread: return 1
        case .inProgress: return 2
        case .complete: return 3
        }
    }

    private func modalitySortRank(_ modality: String) -> Int {
        switch Modality.normalize(modality) {
        case .CT: return 0
        case .PT: return 1
        case .MR: return 2
        case .SEG: return 3
        default: return 10
        }
    }

    private func firstMeaningful(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private var archiveScopes: [PACSArchiveScope] {
        PACSArchiveScope.grouped(from: indexedArchiveStudies)
    }

    private var archiveTreeRoots: [PACSArchiveTreeNode] {
        PACSArchiveTreeBuilder.roots(
            from: indexedArchiveStudies,
            savedRoots: vm.savedArchiveRoots,
            shortcuts: LocalArchiveShortcut.known
        )
    }

    private var filteredArchiveTreeRoots: [PACSArchiveTreeNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return archiveTreeRoots }
        return archiveTreeRoots.compactMap { $0.filtered(matching: query) }
    }

    private var selectedArchiveTreeNode: PACSArchiveTreeNode? {
        guard archiveFilterID.hasPrefix(PACSArchiveTreeNode.filterIDPrefix) else { return nil }
        return archiveTreeRoots.lazy.compactMap { $0.descendant(id: archiveFilterID) }.first
    }

    private var selectedWorklistTreeNode: PACSArchiveTreeNode? {
        guard archiveFilterID.hasPrefix(PACSArchiveTreeNode.filterIDPrefix) else { return nil }
        return allWorklistTreeRoots.lazy.compactMap { $0.descendant(id: archiveFilterID) }.first
    }

    private var availableLocalArchiveShortcuts: [LocalArchiveShortcut] {
        LocalArchiveShortcut.known.filter(\.exists)
    }

    private var selectedSavedArchiveRoot: PACSArchiveRoot? {
        vm.savedArchiveRoots.first { $0.scopeID == archiveFilterID }
    }

    private var filteredSavedArchiveRoots: [PACSArchiveRoot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return vm.savedArchiveRoots }
        return vm.savedArchiveRoots.filter { root in
            root.displayName.lowercased().contains(query)
            || root.path.lowercased().contains(query)
        }
    }

    private func archiveStats(for root: PACSArchiveRoot) -> ArchiveStudyStats {
        let live = ArchiveStudyStats(
            studies: indexedArchiveStudies.filter { study($0, belongsTo: root) }
        )
        if live.hasIndexedContent { return live }
        return ArchiveStudyStats(studyCount: root.studyCount,
                                 seriesCount: root.seriesCount,
                                 instanceCount: 0)
    }

    private func archiveStats(forPath path: String) -> ArchiveStudyStats {
        ArchiveStudyStats(
            studies: indexedArchiveStudies.filter { study($0, belongsToPathPrefix: path) }
        )
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
        if searchText.isEmpty { return vm.activeSessionVolumes }
        return vm.activeSessionVolumes.filter {
            $0.seriesDescription.localizedCaseInsensitiveContains(searchText) ||
            $0.patientName.localizedCaseInsensitiveContains(searchText) ||
            $0.studyDescription.localizedCaseInsensitiveContains(searchText) ||
            $0.patientID.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredFileBrowserEntries: [LocalFileBrowserEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileBrowserEntries }
        return fileBrowserEntries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.kindLabel.localizedCaseInsensitiveContains(query)
            || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func study(_ study: PACSWorklistStudy, belongsTo root: PACSArchiveRoot) -> Bool {
        study.series.contains { series in
            if root.contains(path: series.sourcePath) {
                return true
            }
            return series.filePaths.contains { root.contains(path: $0) }
        }
    }

    private func study(_ study: PACSWorklistStudy, belongsToPathPrefix path: String) -> Bool {
        let prefix = ImageVolume.canonicalPath(path)
        guard !prefix.isEmpty else { return false }
        return study.series.contains { series in
            if pathIsInside(series.sourcePath, prefix: prefix) {
                return true
            }
            return series.filePaths.contains { pathIsInside($0, prefix: prefix) }
        }
    }

    private func pathIsInside(_ candidate: String, prefix: String) -> Bool {
        let normalized = ImageVolume.canonicalPath(candidate)
        return normalized == prefix || normalized.hasPrefix(prefix + "/")
    }

    private func archiveTreeExpansionBinding(for node: PACSArchiveTreeNode,
                                             depth: Int) -> Binding<Bool> {
        Binding(
            get: {
                if expandedArchiveTreeNodeIDs.contains(node.id) { return true }
                if collapsedArchiveTreeNodeIDs.contains(node.id) { return false }
                return depth == 0
            },
            set: { expanded in
                if expanded {
                    expandedArchiveTreeNodeIDs.insert(node.id)
                    collapsedArchiveTreeNodeIDs.remove(node.id)
                } else {
                    collapsedArchiveTreeNodeIDs.insert(node.id)
                    expandedArchiveTreeNodeIDs.remove(node.id)
                }
            }
        )
    }

    private func worklistTreeExpansionBinding(for node: PACSArchiveTreeNode,
                                              depth: Int) -> Binding<Bool> {
        Binding(
            get: {
                if expandedWorklistTreeNodeIDs.contains(node.id) { return true }
                if collapsedWorklistTreeNodeIDs.contains(node.id) { return false }
                return depth == 0
            },
            set: { expanded in
                if expanded {
                    expandedWorklistTreeNodeIDs.insert(node.id)
                    collapsedWorklistTreeNodeIDs.remove(node.id)
                } else {
                    collapsedWorklistTreeNodeIDs.insert(node.id)
                    expandedWorklistTreeNodeIDs.remove(node.id)
                }
            }
        )
    }

    private func showWorklistTreeBranch(_ node: PACSArchiveTreeNode) {
        guard node.study == nil else {
            if let study = node.study {
                openStudy(study)
            }
            return
        }
        archiveFilterID = node.id
        searchText = ""
        worklistDisplayLimit = worklistDisplayPageSize
        browserMode = .worklist
    }

    private func showArchiveTreeBranch(_ node: PACSArchiveTreeNode) {
        guard node.study == nil else {
            if let study = node.study {
                openStudy(study)
            }
            return
        }
        archiveFilterID = node.id
        searchText = ""
        worklistDisplayLimit = worklistDisplayPageSize
        browserMode = .worklist
    }

    private var fileBrowserHeaderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(TracerTheme.accent)
                Text(fileBrowserCurrentURL?.lastPathComponent ?? "Directory")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    navigateFileBrowserUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Go to parent directory")
                Button {
                    reloadFileBrowserEntries()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Refresh directory")
            }

            Text(fileBrowserCurrentURL?.path ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Button {
                    loadFileBrowserCurrentDirectory()
                } label: {
                    Label("Load", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    indexFileBrowserCurrentDirectory()
                } label: {
                    Label("Index", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isIndexing)

                Spacer()
                Text("\(filteredFileBrowserEntries.count)/\(fileBrowserEntries.count) items")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
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

    private func vnaExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedVNAStudyIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedVNAStudyIDs.insert(id)
                } else {
                    expandedVNAStudyIDs.remove(id)
                }
            }
        )
    }

    private func openStudy(_ study: PACSWorklistStudy) {
        if removedWorklistStudyIDs.remove(study.id) != nil {
            persistRemovedWorklistStudies()
        }
        setStatus(.inProgress, for: study)
        Task { await vm.openWorklistStudy(study) }
    }

    private func saveVNAConnectionFromForm() {
        _ = vm.upsertVNAConnection(
            id: vm.activeVNAConnectionID,
            name: vnaConnectionName,
            baseURLString: vnaBaseURL,
            bearerToken: vnaBearerToken
        )
        syncVNAConnectionForm()
    }

    private func syncVNAConnectionForm() {
        guard let connection = vm.activeVNAConnection else {
            vnaConnectionName = ""
            vnaBaseURL = ""
            vnaBearerToken = ""
            return
        }
        vnaConnectionName = connection.name
        vnaBaseURL = connection.baseURLString
        vnaBearerToken = connection.bearerToken
    }

    private func searchVNA() {
        Task { await vm.searchVNAStudies(searchText: searchText) }
    }

    private func loadVNASeries(_ study: VNAStudy) {
        expandedVNAStudyIDs.insert(study.id)
        Task { await vm.loadVNASeries(for: study) }
    }

    private func openVNAStudy(_ study: VNAStudy) {
        expandedVNAStudyIDs.insert(study.id)
        Task { await vm.openVNAStudy(study) }
    }

    private func openVNASeries(_ series: VNASeries, study: VNAStudy) {
        Task { await vm.openVNASeries(series, study: study) }
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

    private func showSavedArchiveRoot(_ root: PACSArchiveRoot) {
        archiveFilterID = root.scopeID
        searchText = ""
        worklistDisplayLimit = worklistDisplayPageSize
        browserMode = .worklist
    }

    private func browseSavedArchiveRoot(_ root: PACSArchiveRoot) {
        guard root.exists else {
            vm.statusMessage = "Saved directory is no longer available: \(root.path)"
            return
        }
        vm.rememberArchiveDirectory(url: root.url)
        setFileBrowserDirectory(root.url)
        browserMode = .viewer
    }

    private func indexSavedArchiveRoot(_ root: PACSArchiveRoot) {
        guard root.exists, !vm.isIndexing else { return }
        browserMode = .archives
        vm.statusMessage = "Refreshing index for \(root.displayName)..."
        Task { @MainActor in
            await vm.indexDirectory(url: root.url, modelContext: modelContext)
            reloadIndexResults()
        }
    }

    private func forgetSavedArchiveRoot(_ root: PACSArchiveRoot) {
        vm.forgetArchiveDirectory(id: root.id)
        if archiveFilterID == root.scopeID {
            archiveFilterID = PACSArchiveScope.allID
        }
    }

    private func openFileBrowserRootPanel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Browse"
        panel.message = "Choose a study archive, patient folder, or DICOM directory to browse inside Tracer."
        if panel.runModal() == .OK, let url = panel.url {
            vm.rememberArchiveDirectory(url: url)
            setFileBrowserDirectory(url)
            browserMode = .viewer
        }
        #else
        vm.statusMessage = "Directory browsing is available on macOS."
        #endif
    }

    private func setFileBrowserDirectory(_ url: URL) {
        fileBrowserCurrentURL = url
        reloadFileBrowserEntries()
    }

    private func reloadFileBrowserEntries() {
        guard let url = fileBrowserCurrentURL else { return }
        fileBrowserLoadTask?.cancel()
        fileBrowserError = nil
        fileBrowserLoadTask = Task { @MainActor [url] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                    let entries = contents
                        .compactMap { try? LocalFileBrowserEntry(url: $0) }
                        .sorted { lhs, rhs in
                            if lhs.isDirectory != rhs.isDirectory {
                                return lhs.isDirectory && !rhs.isDirectory
                            }
                            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                        }
                    return (entries: entries, errorMessage: String?.none)
                } catch {
                    return (entries: [LocalFileBrowserEntry](), errorMessage: Optional(error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled,
                  fileBrowserCurrentURL == url else { return }
            if let errorMessage = result.errorMessage {
                fileBrowserEntries = []
                fileBrowserError = errorMessage
            } else {
                fileBrowserEntries = result.entries
                fileBrowserError = nil
            }
        }
    }

    private func navigateFileBrowserUp() {
        guard let current = fileBrowserCurrentURL else { return }
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else { return }
        setFileBrowserDirectory(parent)
    }

    private func openFileBrowserEntry(_ entry: LocalFileBrowserEntry) {
        if entry.isDirectory {
            setFileBrowserDirectory(entry.url)
        } else {
            loadFileBrowserEntry(entry)
        }
    }

    private func loadFileBrowserEntry(_ entry: LocalFileBrowserEntry) {
        Task { @MainActor in
            if entry.isDirectory {
                await vm.loadDICOMDirectory(url: entry.url)
            } else {
                await dispatchDroppedURL(entry.url)
            }
        }
    }

    private func loadFileBrowserCurrentDirectory() {
        guard let url = fileBrowserCurrentURL else { return }
        Task { @MainActor in
            await vm.loadDICOMDirectory(url: url)
        }
    }

    private func indexFileBrowserEntry(_ entry: LocalFileBrowserEntry) {
        guard entry.isDirectory, !vm.isIndexing else { return }
        Task { @MainActor in
            await vm.indexDirectory(url: entry.url, modelContext: modelContext)
            reloadIndexResults()
        }
    }

    private func indexFileBrowserCurrentDirectory() {
        guard let url = fileBrowserCurrentURL, !vm.isIndexing else { return }
        Task { @MainActor in
            await vm.indexDirectory(url: url, modelContext: modelContext)
            reloadIndexResults()
        }
    }

    private func reloadIndexResults() {
        do {
            let snapshots = try modelContext.fetch(indexFetchDescriptor()).map(\.snapshot)
            indexedSeries = snapshots
            indexedTotalCount = snapshots.count
        } catch {
            indexedSeries = []
            indexedTotalCount = 0
            vm.statusMessage = "Index fetch error: \(error.localizedDescription)"
        }
    }

    private func scheduleIndexResultsReload(delayNanoseconds: UInt64 = 250_000_000) {
        indexReloadTask?.cancel()
        indexReloadTask = Task { @MainActor [delayNanoseconds] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            reloadIndexResults()
            indexReloadTask = nil
        }
    }

    private func indexFetchDescriptor() -> FetchDescriptor<PACSIndexedSeries> {
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

    private func removeStudyFromWorklist(_ study: PACSWorklistStudy) {
        removedWorklistStudyIDs.insert(study.id)
        expandedWorklistTreeNodeIDs.remove(PACSArchiveTreeNode.studyID(study, path: study.sourcePath))
        studyStatuses.removeValue(forKey: study.id)
        persistStatusOverrides()
        persistRemovedWorklistStudies()
        let title = firstMeaningful(study.patientName, study.studyDescription, study.id)
        vm.statusMessage = "Removed from worklist: \(title)"
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

    private func loadRemovedWorklistStudies() {
        guard let data = UserDefaults.standard.data(forKey: removedWorklistDefaultsKey),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            removedWorklistStudyIDs = []
            return
        }
        removedWorklistStudyIDs = Set(raw)
    }

    private func persistRemovedWorklistStudies() {
        let raw = Array(removedWorklistStudyIDs).sorted()
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: removedWorklistDefaultsKey)
        }
    }
}

private func displayDICOMDate(_ dicomDate: String) -> String {
    guard dicomDate.count == 8 else { return dicomDate }
    let year = dicomDate.prefix(4)
    let monthStart = dicomDate.index(dicomDate.startIndex, offsetBy: 4)
    let dayStart = dicomDate.index(dicomDate.startIndex, offsetBy: 6)
    let month = dicomDate[monthStart..<dayStart]
    let day = dicomDate[dayStart...]
    return "\(month)/\(day)/\(year)"
}

private struct VNAConnectionRow: View {
    let connection: VNAConnection
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                .foregroundColor(isActive ? TracerTheme.accentBright : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(connection.endpointSummary)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if connection.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "lock.open")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundColor(TracerTheme.accent)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct VNAStudyActions: View {
    let study: VNAStudy
    let isBusy: Bool
    let onOpen: () -> Void
    let onSeries: () -> Void

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
            .disabled(isBusy)

            Button {
                onSeries()
            } label: {
                Label("Series", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }
}

private struct VNAStudyRow: View {
    let study: VNAStudy

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundColor(TracerTheme.accentBright)
                Text(study.patientName.isEmpty ? "Unknown patient" : study.patientName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(study.modalitySummary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Text(study.patientID.isEmpty ? "No MRN" : study.patientID)
                if !study.accessionNumber.isEmpty {
                    Text(study.accessionNumber)
                }
                if !study.studyDate.isEmpty {
                    Text(displayDICOMDate(study.studyDate))
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
                Text(study.connectionName)
                Text("\(study.seriesCount) series")
                Text("\(study.instanceCount) images")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct VNASeriesRow: View {
    let series: VNASeries

    var body: some View {
        HStack(spacing: 10) {
            modalityBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(series.seriesDescription.isEmpty ? "Series" : series.seriesDescription)
                    .font(.system(size: 11))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !series.bodyPartExamined.isEmpty {
                        Text(series.bodyPartExamined)
                    }
                    if series.seriesNumber > 0 {
                        Text("#\(series.seriesNumber)")
                    }
                    Text("\(series.instanceCount) images")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 11))
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
                Text(primaryTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(study.modalitySummary.isEmpty ? "-" : study.modalitySummary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                if !displayPatientID.isEmpty {
                    Text(displayPatientID)
                }
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

            Text(displayStudyDescription)
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

    private var primaryTitle: String {
        if !displayPatientName.isEmpty { return displayPatientName }
        return displayStudyDescription
    }

    private var displayPatientName: String {
        meaningfulHeaderTitle(study.patientName)
    }

    private var displayPatientID: String {
        meaningfulHeaderTitle(study.patientID)
    }

    private var displayStudyDescription: String {
        let studyTitle = meaningfulHeaderTitle(study.studyDescription)
        if !studyTitle.isEmpty { return studyTitle }
        let folder = sourceFolderTitle(study.sourcePath)
        return folder.isEmpty ? "Untitled study" : folder
    }

    private func sourceFolderTitle(_ sourcePath: String) -> String {
        guard !sourcePath.isEmpty else { return "" }
        let url = URL(fileURLWithPath: sourcePath)
        let parent = url.deletingLastPathComponent()
        let candidates = [
            parent.lastPathComponent,
            parent.deletingLastPathComponent().lastPathComponent
        ]
        for candidate in candidates {
            let title = meaningfulHeaderTitle(candidate)
            if !title.isEmpty { return title }
        }
        return meaningfulHeaderTitle(url.lastPathComponent)
    }

    private func meaningfulHeaderTitle(_ value: String) -> String {
        let trimmed = stripKnownVolumeExtension(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !isGenericHeaderTitle(trimmed) else { return "" }
        return trimmed
    }

    private func stripKnownVolumeExtension(from value: String) -> String {
        let lower = value.lowercased()
        if lower.hasSuffix(".nii.gz") {
            return String(value.dropLast(7))
        }
        if lower.hasSuffix(".nii") || lower.hasSuffix(".mha") || lower.hasSuffix(".mhd") || lower.hasSuffix(".nrrd") {
            return String(value.dropLast(4))
        }
        return value
    }

    private func isGenericHeaderTitle(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return true }
        return [
            "nifti",
            "nifti study",
            "nifti import",
            "untitled",
            "untitled study",
            "study",
            "image",
            "images",
            "data",
            "files",
            "ct",
            "pt",
            "pet",
            "mr",
            "mri"
        ].contains(normalized)
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

private struct ArchiveTreeNodeView: View {
    let node: PACSArchiveTreeNode
    let depth: Int
    let expansion: (PACSArchiveTreeNode, Int) -> Binding<Bool>
    let onShowBranch: (PACSArchiveTreeNode) -> Void
    let onOpenStudy: (PACSWorklistStudy) -> Void
    let onSetStatus: (WorklistStudyStatus, PACSWorklistStudy) -> Void
    let onRemoveStudy: ((PACSWorklistStudy) -> Void)?

    var body: some View {
        if let study = node.study {
            Button {
                onOpenStudy(study)
            } label: {
                ArchiveTreeStudyRow(node: node, study: study, depth: depth)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    onOpenStudy(study)
                } label: {
                    Label("Open Study", systemImage: "rectangle.3.group")
                }
                Menu("Status") {
                    ForEach(WorklistStudyStatus.allCases) { status in
                        Button(status.displayName) {
                            onSetStatus(status, study)
                        }
                    }
                }
                if let onRemoveStudy {
                    Button(role: .destructive) {
                        onRemoveStudy(study)
                    } label: {
                        Label("Remove from Worklist", systemImage: "minus.circle")
                    }
                }
            }
        } else {
            DisclosureGroup(isExpanded: expansion(node, depth)) {
                ForEach(node.children) { child in
                    ArchiveTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        expansion: expansion,
                        onShowBranch: onShowBranch,
                        onOpenStudy: onOpenStudy,
                        onSetStatus: onSetStatus,
                        onRemoveStudy: onRemoveStudy
                    )
                }
            } label: {
                ArchiveTreeBranchRow(node: node, depth: depth, onShowBranch: onShowBranch)
            }
            .contextMenu {
                Button {
                    onShowBranch(node)
                } label: {
                    Label("Show Studies in Branch", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}

private struct ArchiveTreeBranchRow: View {
    let node: PACSArchiveTreeNode
    let depth: Int
    let onShowBranch: (PACSArchiveTreeNode) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: node.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(depth == 0 ? TracerTheme.accentBright : TracerTheme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.title)
                        .font(.system(size: depth == 0 ? 12 : 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !node.modalitySummary.isEmpty {
                        Text(node.modalitySummary)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text("\(node.studyCount) studies")
                    Text("\(node.seriesCount) series")
                    if node.instanceCount > 0 {
                        Text("\(node.instanceCount) images")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Button {
                onShowBranch(node)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show studies in this branch")
        }
        .padding(.leading, CGFloat(max(0, depth)) * 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ArchiveTreeStudyRow: View {
    let node: PACSArchiveTreeNode
    let study: PACSWorklistStudy
    let depth: Int

    var body: some View {
        HStack(spacing: 9) {
            WorklistStatusBadge(status: study.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(study.modalitySummary.isEmpty ? "-" : study.modalitySummary)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if !study.patientID.isEmpty {
                        Text(study.patientID)
                    }
                    if !study.studyDate.isEmpty {
                        Text(study.studyDate)
                    }
                    Text("\(study.seriesCount) series")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.leading, CGFloat(max(0, depth)) * 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct PACSArchiveTreeNode: Identifiable {
    static let filterIDPrefix = "__archive_tree__:"

    let id: String
    let path: String
    let title: String
    let subtitle: String
    let systemImage: String
    let study: PACSWorklistStudy?
    let children: [PACSArchiveTreeNode]
    let studyCount: Int
    let seriesCount: Int
    let instanceCount: Int
    let modalities: [String]

    var modalitySummary: String {
        modalities.joined(separator: "/")
    }

    static func branchID(path: String) -> String {
        filterIDPrefix + ImageVolume.canonicalPath(path)
    }

    static func studyID(_ study: PACSWorklistStudy, path: String) -> String {
        "archive-study:\(study.id):\(ImageVolume.canonicalPath(path))"
    }

    static func filterPath(from id: String) -> String? {
        guard id.hasPrefix(filterIDPrefix) else { return nil }
        return String(id.dropFirst(filterIDPrefix.count))
    }

    func descendant(id targetID: String) -> PACSArchiveTreeNode? {
        if id == targetID { return self }
        for child in children {
            if let match = child.descendant(id: targetID) {
                return match
            }
        }
        return nil
    }

    func filtered(matching query: String) -> PACSArchiveTreeNode? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return self }
        if searchableText.contains(normalized) {
            return self
        }
        let filteredChildren = children.compactMap { $0.filtered(matching: query) }
        guard !filteredChildren.isEmpty else { return nil }
        return PACSArchiveTreeNode(
            id: id,
            path: path,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            study: study,
            children: filteredChildren,
            studyCount: filteredChildren.reduce(0) { $0 + $1.studyCount },
            seriesCount: filteredChildren.reduce(0) { $0 + $1.seriesCount },
            instanceCount: filteredChildren.reduce(0) { $0 + $1.instanceCount },
            modalities: Array(Set(filteredChildren.flatMap(\.modalities))).sorted()
        )
    }

    private var searchableText: String {
        ([
            title,
            subtitle,
            path,
            modalitySummary,
            study?.searchableText ?? "",
        ] + children.map(\.title))
            .joined(separator: " ")
            .lowercased()
    }
}

private enum PACSArchiveTreeBuilder {
    private struct DatasetDescriptor {
        let path: String
        let title: String
        let subtitle: String
    }

    private final class MutableNode {
        let title: String
        let path: String
        let subtitle: String
        let systemImage: String
        var childOrder: [String] = []
        var children: [String: MutableNode] = [:]
        var studies: [(study: PACSWorklistStudy, path: String)] = []

        init(title: String, path: String, subtitle: String, systemImage: String) {
            self.title = title
            self.path = path
            self.subtitle = subtitle
            self.systemImage = systemImage
        }

        func child(title: String, path: String, subtitle: String) -> MutableNode {
            let key = ImageVolume.canonicalPath(path)
            if let existing = children[key] {
                return existing
            }
            let node = MutableNode(title: title, path: key, subtitle: subtitle, systemImage: "folder")
            children[key] = node
            childOrder.append(key)
            return node
        }

        func addStudy(_ study: PACSWorklistStudy, branch: [(title: String, path: String)], studyPath: String) {
            if let first = branch.first {
                child(title: first.title, path: first.path, subtitle: first.path)
                    .addStudy(study, branch: Array(branch.dropFirst()), studyPath: studyPath)
            } else {
                studies.append((study, studyPath))
            }
        }

        func finalized() -> PACSArchiveTreeNode {
            let branchChildren = childOrder.compactMap { children[$0]?.finalized() }
                .sorted { lhs, rhs in
                    if lhs.studyCount != rhs.studyCount { return lhs.studyCount > rhs.studyCount }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            let studyChildren = studies
                .sorted { lhs, rhs in
                    if lhs.study.studyDate != rhs.study.studyDate {
                        return lhs.study.studyDate > rhs.study.studyDate
                    }
                    return studyTitle(lhs.study).localizedCaseInsensitiveCompare(studyTitle(rhs.study)) == .orderedAscending
                }
                .map { entry in
                    PACSArchiveTreeNode(
                        id: PACSArchiveTreeNode.studyID(entry.study, path: entry.path),
                        path: entry.path,
                        title: studyTitle(entry.study),
                        subtitle: entry.path,
                        systemImage: "rectangle.3.group",
                        study: entry.study,
                        children: [],
                        studyCount: 1,
                        seriesCount: entry.study.seriesCount,
                        instanceCount: entry.study.instanceCount,
                        modalities: entry.study.modalities
                    )
                }
            let allChildren = branchChildren + studyChildren
            return PACSArchiveTreeNode(
                id: PACSArchiveTreeNode.branchID(path: path),
                path: path,
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                study: nil,
                children: allChildren,
                studyCount: allChildren.reduce(0) { $0 + $1.studyCount },
                seriesCount: allChildren.reduce(0) { $0 + $1.seriesCount },
                instanceCount: allChildren.reduce(0) { $0 + $1.instanceCount },
                modalities: Array(Set(allChildren.flatMap(\.modalities))).sorted()
            )
        }
    }

    static func roots(from studies: [PACSWorklistStudy],
                      savedRoots: [PACSArchiveRoot],
                      shortcuts: [LocalArchiveShortcut]) -> [PACSArchiveTreeNode] {
        var rootOrder: [String] = []
        var roots: [String: MutableNode] = [:]

        for study in studies {
            let studyPath = studyDirectoryPath(for: study)
            let dataset = datasetDescriptor(for: studyPath,
                                            savedRoots: savedRoots,
                                            shortcuts: shortcuts)
            let root = roots[dataset.path] ?? {
                let node = MutableNode(title: dataset.title,
                                       path: dataset.path,
                                       subtitle: dataset.subtitle,
                                       systemImage: "externaldrive.connected.to.line.below")
                roots[dataset.path] = node
                rootOrder.append(dataset.path)
                return node
            }()
            root.addStudy(study,
                          branch: branchPath(from: dataset.path, to: studyPath, study: study),
                          studyPath: studyPath)
        }

        return rootOrder.compactMap { roots[$0]?.finalized() }
            .sorted { lhs, rhs in
                if lhs.studyCount != rhs.studyCount { return lhs.studyCount > rhs.studyCount }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func datasetDescriptor(for studyPath: String,
                                          savedRoots: [PACSArchiveRoot],
                                          shortcuts: [LocalArchiveShortcut]) -> DatasetDescriptor {
        let canonicalStudyPath = ImageVolume.canonicalPath(studyPath)
        let savedMatches = savedRoots
            .map { root in (path: ImageVolume.canonicalPath(root.path), title: root.displayName) }
            .filter { pathIsInside(canonicalStudyPath, prefix: $0.path) }
        if let match = savedMatches.max(by: { $0.path.count < $1.path.count }) {
            return DatasetDescriptor(path: match.path,
                                     title: match.title,
                                     subtitle: parentPath(match.path))
        }

        let shortcutMatches = shortcuts
            .map { shortcut in (path: ImageVolume.canonicalPath(shortcut.path), title: shortcut.title) }
            .filter { pathIsInside(canonicalStudyPath, prefix: $0.path) }
        if let match = shortcutMatches.max(by: { $0.path.count < $1.path.count }) {
            return DatasetDescriptor(path: match.path,
                                     title: match.title,
                                     subtitle: parentPath(match.path))
        }

        let components = pathComponents(canonicalStudyPath)
        if let fdg = components.firstIndex(of: "FDG-PET-CT-Lesions") {
            let path = path(from: Array(components[0...fdg]))
            return DatasetDescriptor(path: path,
                                     title: "FDG PET/CT Lesions",
                                     subtitle: parentPath(path))
        }
        if let manifest = components.firstIndex(where: { $0.hasPrefix("manifest-") }) {
            let path = path(from: Array(components[0...manifest]))
            return DatasetDescriptor(path: path,
                                     title: components[manifest],
                                     subtitle: parentPath(path))
        }
        if let subject = components.firstIndex(where: { $0.hasPrefix("sub-") }), subject > 0 {
            let path = path(from: Array(components[0..<subject]))
            return DatasetDescriptor(path: path,
                                     title: lastPathComponent(path, fallback: "BIDS Dataset"),
                                     subtitle: parentPath(path))
        }

        let fallback = parentPath(parentPath(canonicalStudyPath))
        let path = fallback.isEmpty ? parentPath(canonicalStudyPath) : fallback
        return DatasetDescriptor(path: path,
                                 title: lastPathComponent(path, fallback: "Indexed Dataset"),
                                 subtitle: parentPath(path))
    }

    private static func branchPath(from datasetPath: String,
                                   to studyPath: String,
                                   study: PACSWorklistStudy) -> [(title: String, path: String)] {
        let datasetComponents = pathComponents(datasetPath)
        let studyComponents = pathComponents(studyPath)
        let relative = studyComponents.starts(with: datasetComponents)
            ? Array(studyComponents.dropFirst(datasetComponents.count))
            : []
        var branchComponents = relative.count > 1 ? Array(relative.dropLast()) : []
        if branchComponents.isEmpty {
            let patient = meaningful(study.patientName) ?? meaningful(study.patientID)
            if let patient {
                branchComponents = [patient]
            }
        }

        var running = ImageVolume.canonicalPath(datasetPath)
        return branchComponents.map { component in
            running = append(component: component, to: running)
            return (title: component, path: running)
        }
    }

    private static func studyDirectoryPath(for study: PACSWorklistStudy) -> String {
        guard let series = study.series.first else {
            return ImageVolume.canonicalPath(study.sourcePath)
        }
        let firstPath = series.filePaths.first ?? series.sourcePath
        let fileParent = parentPath(firstPath)
        if series.kind == .dicom {
            let studyParent = parentPath(fileParent)
            return studyParent.isEmpty ? fileParent : studyParent
        }
        return fileParent
    }

    private static func studyTitle(_ study: PACSWorklistStudy) -> String {
        meaningful(study.studyDescription)
            ?? meaningful(study.patientName)
            ?? meaningful(study.patientID)
            ?? "Untitled study"
    }

    private static func meaningful(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let generic = [
            "nifti",
            "nifti study",
            "nifti import",
            "untitled",
            "untitled study",
            "study",
            "image",
            "images",
            "data",
            "files",
        ]
        return generic.contains(normalized) ? nil : trimmed
    }

    private static func pathIsInside(_ candidate: String, prefix: String) -> Bool {
        let path = ImageVolume.canonicalPath(candidate)
        let root = ImageVolume.canonicalPath(prefix)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func append(component: String, to path: String) -> String {
        let root = ImageVolume.canonicalPath(path)
        return root == "/" ? "/" + component : root + "/" + component
    }

    private static func parentPath(_ path: String) -> String {
        let parent = (ImageVolume.canonicalPath(path) as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func lastPathComponent(_ path: String, fallback: String) -> String {
        let last = (ImageVolume.canonicalPath(path) as NSString).lastPathComponent
        return last.isEmpty ? fallback : last
    }

    private static func pathComponents(_ path: String) -> [String] {
        ImageVolume.canonicalPath(path).split(separator: "/").map(String.init)
    }

    private static func path(from components: [String]) -> String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
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

private struct LocalFileBrowserEntry: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isRegularFile: Bool
    let fileSize: Int64?
    let modifiedAt: Date?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        self.url = url
        self.id = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isRegularFile = values.isRegularFile ?? false
        self.fileSize = values.fileSize.map(Int64.init)
        self.modifiedAt = values.contentModificationDate
    }

    var kindLabel: String {
        if isDirectory { return "Folder" }
        let lower = name.lowercased()
        if lower.hasSuffix(".nii") || lower.hasSuffix(".nii.gz") { return "NIfTI" }
        if lower.hasSuffix(".dcm") || lower.hasSuffix(".ima") || lower.hasSuffix(".dicom") {
            return "DICOM"
        }
        return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
    }

    var detailText: String {
        if isDirectory { return "Folder" }
        guard let fileSize else { return kindLabel }
        return "\(kindLabel) · \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))"
    }

    var systemImage: String {
        if isDirectory { return "folder" }
        switch kindLabel {
        case "NIfTI": return "cube.box"
        case "DICOM": return "square.stack.3d.up"
        default: return "doc"
        }
    }
}

private struct FileBrowserEntryRow: View {
    let entry: LocalFileBrowserEntry
    let onOpen: () -> Void
    let onLoad: () -> Void
    let onIndex: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(entry.isDirectory ? TracerTheme.accent : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 11, weight: entry.isDirectory ? .semibold : .regular))
                    .lineLimit(1)
                Text(entry.detailText)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                onOpen()
            } label: {
                Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(entry.isDirectory ? "Open folder" : "Open file")

            Button {
                onLoad()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(entry.isDirectory ? "Load this directory as a study" : "Load this file")

            if entry.isDirectory {
                Button {
                    onIndex()
                } label: {
                    Image(systemName: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Index this directory")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label(entry.isDirectory ? "Open Folder" : "Open File",
                      systemImage: entry.isDirectory ? "folder" : "arrow.up.right.square")
            }
            Button {
                onLoad()
            } label: {
                Label(entry.isDirectory ? "Load Directory as Study" : "Load File",
                      systemImage: "rectangle.3.group")
            }
            if entry.isDirectory {
                Button {
                    onIndex()
                } label: {
                    Label("Index Directory", systemImage: "externaldrive.badge.plus")
                }
            }
        }
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

private struct ArchiveStudyStats: Equatable {
    let studyCount: Int
    let seriesCount: Int
    let instanceCount: Int

    init(studyCount: Int = 0, seriesCount: Int = 0, instanceCount: Int = 0) {
        self.studyCount = studyCount
        self.seriesCount = seriesCount
        self.instanceCount = instanceCount
    }

    init(studies: [PACSWorklistStudy]) {
        self.studyCount = Set(studies.map(\.id)).count
        self.seriesCount = studies.reduce(0) { $0 + $1.seriesCount }
        self.instanceCount = studies.reduce(0) { $0 + $1.instanceCount }
    }

    var hasIndexedContent: Bool {
        studyCount > 0 || seriesCount > 0 || instanceCount > 0
    }

    var studyLabel: String {
        studyCount == 1 ? "1 study" : "\(studyCount) studies"
    }

    var seriesLabel: String {
        seriesCount == 1 ? "1 series" : "\(seriesCount) series"
    }

    var imageLabel: String {
        instanceCount == 1 ? "1 image" : "\(instanceCount) images"
    }
}

private struct LocalArchiveShortcutRow: View {
    let shortcut: LocalArchiveShortcut
    let stats: ArchiveStudyStats

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

                HStack(spacing: 8) {
                    Text(stats.studyLabel)
                    if stats.seriesCount > 0 {
                        Text(stats.seriesLabel)
                    }
                    if stats.instanceCount > 0 {
                        Text(stats.imageLabel)
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct SavedArchiveRootRow: View {
    let root: PACSArchiveRoot
    let stats: ArchiveStudyStats

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: root.exists ? "externaldrive.connected.to.line.below" : "externaldrive.badge.xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(root.exists ? TracerTheme.accentBright : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(root.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(stats.studyLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(root.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(root.exists ? "Available" : "Missing")
                    if stats.seriesCount > 0 {
                        Text(stats.seriesLabel)
                    }
                    if stats.instanceCount > 0 {
                        Text(stats.imageLabel)
                    }
                    if let lastIndexedAt = root.lastIndexedAt {
                        Text("Indexed \(lastIndexedAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Opened \(root.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
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
                    if series.seriesNumber > 0 {
                        Text("#\(series.seriesNumber)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
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

private struct ViewerSessionRow: View {
    let session: ViewerSessionRecord
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isActive ? TracerTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.summary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct OpenStudyRow: View {
    let study: ViewerSessionStudyReference
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(study.modalitySummary)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isActive ? TracerTheme.accent : Color.secondary.opacity(0.55))
                .cornerRadius(3)
            VStack(alignment: .leading, spacing: 2) {
                Text(study.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(study.displaySubtitle) · \(study.volumeIdentities.count) series")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
