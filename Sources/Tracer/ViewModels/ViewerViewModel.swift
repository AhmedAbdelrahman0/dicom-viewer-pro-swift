import Foundation
import SwiftUI
import Combine
import SwiftData
import simd

public enum ViewerTool: String, CaseIterable, Identifiable {
    case wl, pan, zoom, distance, angle, area

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .wl: return "W/L"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .distance: return "Distance"
        case .angle: return "Angle"
        case .area: return "Area"
        }
    }
    public var systemImage: String {
        switch self {
        case .wl: return "slider.horizontal.3"
        case .pan: return "hand.draw"
        case .zoom: return "plus.magnifyingglass"
        case .distance: return "ruler"
        case .angle: return "angle"
        case .area: return "skew"
        }
    }

    /// Rich description shown as hover tooltip.
    public var helpText: String {
        switch self {
        case .wl:
            return "Window / Level\n"
                 + "Drag horizontally to adjust window width,\n"
                 + "vertically to adjust window level.\n"
                 + "Shortcut: W"
        case .pan:
            return "Pan\n"
                 + "Click and drag to move the image within the view.\n"
                 + "Works even when the image is zoomed in.\n"
                 + "Shortcut: P  (or middle-mouse drag at any time)"
        case .zoom:
            return "Zoom\n"
                 + "Drag up/down to zoom in/out.\n"
                 + "Scroll wheel + ⇧/⌘ also zooms.\n"
                 + "Double-click to fit to window.\n"
                 + "Shortcut: Z"
        case .distance:
            return "Distance Measurement\n"
                 + "Click two points to measure Euclidean distance in mm.\n"
                 + "Uses the volume's pixel spacing for calibration.\n"
                 + "Shortcut: D"
        case .angle:
            return "Angle Measurement\n"
                 + "Click three points (arm 1 → vertex → arm 2)\n"
                 + "to measure the angle between two arms in degrees.\n"
                 + "Shortcut: A"
        case .area:
            return "Area / ROI\n"
                 + "Click multiple points to outline a polygon.\n"
                 + "Shows the enclosed area in mm² / cm².\n"
                 + "Shortcut: R"
        }
    }

    /// Keyboard shortcut character for toolbar binding.
    public var keyboardShortcut: Character? {
        switch self {
        case .wl: return "w"
        case .pan: return "p"
        case .zoom: return "z"
        case .distance: return "d"
        case .angle: return "a"
        case .area: return "r"
        }
    }
}

@MainActor
public final class ViewerViewModel: ObservableObject {

    // Loaded volumes (cache)
    @Published public var loadedVolumes: [ImageVolume] = []

    // Current primary volume being displayed
    @Published public var currentVolume: ImageVolume?

    // Fusion (optional)
    @Published public var fusion: FusionPair?

    // Labeling (delegate to dedicated VM)
    @Published public var labeling = LabelingViewModel()

    // Window/Level
    @Published public var window: Double = 400
    @Published public var level: Double = 40

    // Slice indices [sagittal(0), coronal(1), axial(2)]
    @Published public var sliceIndices: [Int] = [0, 0, 0]

    // Active tool
    @Published public var activeTool: ViewerTool = .wl

    // Display transforms
    @Published public var invertColors: Bool = false

    // Overlay display settings
    @Published public var overlayOpacity: Double = 0.5
    @Published public var overlayColormap: Colormap = .tracerPET
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3
    @Published public var suvSettings = SUVCalculationSettings()

    // Annotations per view
    @Published public var annotations: [Annotation] = []

    // Status
    @Published public var statusMessage: String = "Ready. Open a DICOM or NIfTI file to begin."
    @Published public var isLoading: Bool = false
    @Published public var progress: Double = 0
    @Published public var indexProgress: PACSIndexScanProgress?
    @Published public var indexRevision: Int = 0
    @Published public private(set) var isIndexing: Bool = false

    /// Shared flag that lets the UI cancel a long-running PACS index scan.
    /// Read-only outside the VM; callers cancel via `cancelIndexing()`.
    public let indexCancellation = PACSScanCancellation()

    // DICOM study browser
    @Published public var loadedSeries: [DICOMSeries] = []

    /// Capped LRU list of the last `RecentVolumesStore.maximumEntries`
    /// volumes the user has opened. Persisted across launches. Displayed as
    /// a horizontal chip row at the top of the Study Browser.
    @Published public private(set) var recentVolumes: [RecentVolume] = []
    private let recentVolumesStore = RecentVolumesStore()

    public init() {
        self.recentVolumes = recentVolumesStore.load()
    }

    public var loadedCTVolumes: [ImageVolume] {
        loadedVolumes.filter { Modality.normalize($0.modality) == .CT }
    }

    public var loadedPETVolumes: [ImageVolume] {
        loadedVolumes.filter { Modality.normalize($0.modality) == .PT }
    }

    public var activePETQuantificationVolume: ImageVolume? {
        if let fusion {
            return fusion.displayedOverlay
        }
        if let currentVolume, Modality.normalize(currentVolume.modality) == .PT {
            return currentVolume
        }
        return loadedPETVolumes.first
    }

    public var activePETSourceVolume: ImageVolume? {
        fusion?.overlayVolume ?? activePETQuantificationVolume
    }

    // MARK: - Loading

    public func loadNIfTI(url: URL) async {
        let sourcePath = NIfTILoader.canonicalSourcePath(for: url)
        if let existing = loadedVolume(sourcePath: sourcePath) {
            displayVolume(existing)
            statusMessage = "Already loaded: \(existing.seriesDescription)"
            return
        }

        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try NIfTILoader.load(url)
            }.value

            let result = addLoadedVolumeIfNeeded(volume)
            displayVolume(result.volume)
            statusMessage = result.inserted
                ? "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
                : "Already loaded: \(result.volume.seriesDescription)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func loadDICOMDirectory(url: URL) async {
        isLoading = true
        statusMessage = "Scanning \(url.lastPathComponent)..."
        defer { isLoading = false }

        let series = await Task.detached(priority: .userInitiated) {
            DICOMLoader.scanDirectory(url) { done, total in
                Task { @MainActor in
                    // Progress updates via main actor (omitted for brevity)
                }
            }
        }.value

        let merge = mergeScannedSeries(series)
        statusMessage = "Found \(series.count) series | added \(merge.added.count), updated \(merge.updated), skipped \(merge.skipped) duplicates"

        // Open the first new series automatically; if everything was already
        // known, select the existing match instead of loading a duplicate.
        if let first = merge.added.first ?? series.first.flatMap({ loadedSeriesMatch(for: $0) }) {
            await openSeries(first)
        }
    }

    public func openSeries(_ series: DICOMSeries) async {
        if let existing = loadedVolume(seriesUID: series.uid) {
            displayVolume(existing)
            statusMessage = "Already loaded: \(series.displayName)"
            return
        }

        isLoading = true
        statusMessage = "Loading \(series.displayName)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try DICOMLoader.loadSeries(series.files)
            }.value

            let result = addLoadedVolumeIfNeeded(volume)
            displayVolume(result.volume)
            statusMessage = result.inserted
                ? "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
                : "Already loaded: \(series.displayName)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func indexDirectory(url: URL, modelContext: ModelContext) async {
        indexCancellation.reset()
        isLoading = true
        isIndexing = true
        progress = 0
        indexProgress = nil
        statusMessage = "Indexing \(url.lastPathComponent)..."
        defer {
            isLoading = false
            isIndexing = false
            progress = 0
            indexProgress = nil
        }

        let progressHandler: @Sendable (PACSIndexScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.indexProgress = update
                self?.statusMessage = update.statusText
            }
        }

        let cancellation = indexCancellation
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        let scanResult = await Task.detached(priority: .userInitiated) {
            PACSDirectoryIndexer.scan(url: url,
                                      isCancelled: isCancelled,
                                      progress: progressHandler)
        }.value

        if scanResult.cancelled {
            statusMessage = "Indexing cancelled after \(scanResult.scannedFiles) files (\(scanResult.records.count) partial series discarded)"
            return
        }

        let records = uniqueIndexSnapshots(scanResult.records)

        do {
            var inserted = 0
            var updated = 0
            var offset = 0
            let batchSize = 250

            while offset < records.count {
                if indexCancellation.isCancelled {
                    try? modelContext.save()
                    statusMessage = "Indexing cancelled at \(offset)/\(records.count) series (inserted \(inserted), updated \(updated))"
                    return
                }
                let end = min(records.count, offset + batchSize)
                for snapshot in records[offset..<end] {
                    switch try upsertIndexedSeries(snapshot, in: modelContext) {
                    case .inserted: inserted += 1
                    case .updated: updated += 1
                    }
                }
                try modelContext.save()
                offset = end
                statusMessage = "Indexed \(offset)/\(records.count) series | inserted \(inserted), updated \(updated)"
                await Task.yield()
            }
            indexRevision += 1
            statusMessage = "Indexed \(records.count) series from \(scanResult.scannedFiles) files | inserted \(inserted), updated \(updated), skipped \(scanResult.skippedFiles)"
        } catch {
            statusMessage = "Index error: \(error.localizedDescription)"
        }
    }

    /// Request cancellation of the in-flight `indexDirectory(...)` scan.
    /// Safe to call from any thread. No-op when no scan is running.
    public func cancelIndexing() {
        indexCancellation.cancel()
    }

    public func openIndexedSeries(_ entry: PACSIndexedSeriesSnapshot) async {
        switch entry.kind {
        case .dicom:
            await openIndexedDICOMSeries(entry)
        case .nifti:
            let path = entry.filePaths.first ?? entry.sourcePath
            await loadNIfTI(url: URL(fileURLWithPath: path))
        }
    }

    public func openWorklistStudy(_ study: PACSWorklistStudy) async {
        let ct = study.series.first { Modality.normalize($0.modality) == .CT }
        let pet = study.series.first { Modality.normalize($0.modality) == .PT }

        if let ct, let pet {
            await openIndexedSeries(ct)
            await openIndexedSeries(pet)
            await autoFusePETCT()
            statusMessage = "Opened PET/CT study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
            return
        }

        guard let first = study.series.first else {
            statusMessage = "Worklist study has no series"
            return
        }
        await openIndexedSeries(first)
        statusMessage = "Opened study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
    }

    public func loadOverlay(url: URL) async {
        let sourcePath = NIfTILoader.canonicalSourcePath(for: url)
        if let fusion,
           fusion.overlayVolume.sourceFiles.contains(sourcePath) {
            statusMessage = "Overlay already loaded: \(fusion.overlayVolume.seriesDescription)"
            return
        }

        isLoading = true
        statusMessage = "Loading overlay..."
        defer { isLoading = false }

        do {
            let overlay = try await Task.detached(priority: .userInitiated) {
                try NIfTILoader.load(url)
            }.value

            guard let base = currentVolume else {
                statusMessage = "Load a base volume first"
                return
            }

            let resampled = try await resampledOverlayIfNeeded(base: base, overlay: overlay)
            let pair = configureFusion(base: base, overlay: overlay, resampledOverlay: resampled)
            statusMessage = "Fusion loaded: \(pair.fusionTypeLabel)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func autoFusePETCT() async {
        guard let pair = bestPETCTPair() else {
            statusMessage = "Load at least one CT and one PET volume first"
            return
        }
        await fusePETCT(base: pair.ct, overlay: pair.pet)
    }

    public func fusePETCT(base: ImageVolume, overlay: ImageVolume) async {
        isLoading = true
        statusMessage = "Fusing PET/CT..."
        defer { isLoading = false }

        let ct = Modality.normalize(base.modality) == .CT ? base : overlay
        let pet = Modality.normalize(base.modality) == .PT ? base : overlay

        guard Modality.normalize(ct.modality) == .CT,
              Modality.normalize(pet.modality) == .PT else {
            statusMessage = "PET/CT fusion needs one CT volume and one PET volume"
            return
        }

        do {
            let resampled = try await resampledOverlayIfNeeded(base: ct, overlay: pet)
            configureFusion(base: ct, overlay: pet, resampledOverlay: resampled)
            statusMessage = "PET/CT fused: PET resampled into CT grid"
        } catch {
            statusMessage = "PET/CT fusion error: \(error.localizedDescription)"
        }
    }

    private func openIndexedDICOMSeries(_ entry: PACSIndexedSeriesSnapshot) async {
        isLoading = true
        statusMessage = "Loading \(entry.displayName)..."
        defer { isLoading = false }

        do {
            let series = try await Task.detached(priority: .userInitiated) {
                let files = try entry.filePaths.map {
                    try DICOMLoader.parseHeader(at: URL(fileURLWithPath: $0))
                }
                guard !files.isEmpty else {
                    throw DICOMError.invalidFile("Indexed series has no files")
                }
                return DICOMSeries(
                    uid: entry.seriesUID,
                    modality: entry.modality,
                    description: entry.seriesDescription,
                    patientID: entry.patientID,
                    patientName: entry.patientName,
                    studyUID: entry.studyUID,
                    studyDescription: entry.studyDescription,
                    studyDate: entry.studyDate,
                    files: files
                )
            }.value

            await openSeries(series)
        } catch {
            statusMessage = "Mini-PACS load error: \(error.localizedDescription)"
        }
    }

    private enum IndexUpsertResult {
        case inserted
        case updated
    }

    private func upsertIndexedSeries(_ snapshot: PACSIndexedSeriesSnapshot,
                                     in modelContext: ModelContext) throws -> IndexUpsertResult {
        let id = snapshot.id
        var descriptor = FetchDescriptor<PACSIndexedSeries>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: snapshot)
            return .updated
        } else {
            modelContext.insert(PACSIndexedSeries(snapshot: snapshot))
            return .inserted
        }
    }

    public func removeOverlay() {
        fusion = nil
        statusMessage = "Overlay removed"
    }

    @discardableResult
    public func mergeScannedSeries(_ series: [DICOMSeries]) -> (added: [DICOMSeries], updated: Int, skipped: Int) {
        var added: [DICOMSeries] = []
        var updated = 0
        var skipped = 0

        for incoming in series {
            guard !incoming.uid.isEmpty else {
                skipped += 1
                continue
            }

            if let existingIndex = loadedSeries.firstIndex(where: { $0.uid == incoming.uid }) {
                let existingKeys = Set(loadedSeries[existingIndex].files.map(dicomFileIdentity))
                let newFiles = incoming.files.filter {
                    !existingKeys.contains(dicomFileIdentity($0))
                }
                if newFiles.isEmpty {
                    skipped += 1
                } else {
                    loadedSeries[existingIndex].files.append(contentsOf: newFiles)
                    updated += 1
                }
            } else {
                loadedSeries.append(incoming)
                added.append(incoming)
            }
        }

        return (added, updated, skipped)
    }

    @discardableResult
    public func addLoadedVolumeIfNeeded(_ volume: ImageVolume) -> (volume: ImageVolume, inserted: Bool) {
        if let existing = loadedVolume(matching: volume) {
            // Even re-openings bump the recent-list timestamp so the chip
            // stays at the head of the strip.
            recordRecent(volume: existing)
            return (existing, false)
        }
        loadedVolumes.append(volume)
        recordRecent(volume: volume)
        return (volume, true)
    }

    // MARK: - Recent volumes

    private func recordRecent(volume: ImageVolume) {
        guard !volume.sourceFiles.isEmpty else { return }
        recentVolumes = recentVolumesStore.recordOpen(RecentVolume(from: volume))
    }

    /// Refresh the published strip from persistence. Settings and other
    /// windows can mutate the shared store outside this view model.
    public func reloadRecentVolumes() {
        recentVolumes = recentVolumesStore.load()
    }

    /// Drop a recent entry (e.g. after the user clicks the × chip).
    public func removeRecent(id: String) {
        recentVolumes = recentVolumesStore.remove(id: id)
    }

    /// Re-open a volume from its `RecentVolume` bookmark. Picks the right
    /// loader based on `kind` and the file extensions, and if the session
    /// already holds that volume just re-displays it without re-loading.
    public func reopenRecent(_ recent: RecentVolume) async {
        // Already loaded in this session?
        if let already = loadedVolumes.first(where: { $0.sessionIdentity == recent.id }) {
            displayVolume(already)
            statusMessage = "Already loaded: \(recent.seriesDescription)"
            recordRecent(volume: already)
            return
        }
        guard let firstPath = recent.sourceFiles.first else {
            statusMessage = "Recent entry has no source files."
            return
        }
        switch recent.kind {
        case .nifti:
            await loadNIfTI(url: URL(fileURLWithPath: firstPath))
        case .dicom:
            // Use the parent directory to trigger a fresh DICOM scan —
            // cheapest way to rebuild the volume without caching pixel data
            // between sessions.
            let parent = (firstPath as NSString).deletingLastPathComponent
            await loadDICOMDirectory(url: URL(fileURLWithPath: parent))
        }
    }

    private func loadedVolume(matching volume: ImageVolume) -> ImageVolume? {
        loadedVolumes.first { candidate in
            if !volume.seriesUID.isEmpty, candidate.seriesUID == volume.seriesUID {
                return true
            }
            if !volume.sourceFiles.isEmpty,
               !Set(candidate.sourceFiles).isDisjoint(with: volume.sourceFiles) {
                return true
            }
            return candidate.sessionIdentity == volume.sessionIdentity
        }
    }

    private func loadedVolume(seriesUID: String) -> ImageVolume? {
        guard !seriesUID.isEmpty else { return nil }
        return loadedVolumes.first { $0.seriesUID == seriesUID }
    }

    private func loadedVolume(sourcePath: String) -> ImageVolume? {
        let canonical = ImageVolume.canonicalPath(sourcePath)
        return loadedVolumes.first { volume in
            volume.sourceFiles.contains(canonical) ||
            volume.seriesUID == "nifti:\(canonical)"
        }
    }

    private func loadedSeriesMatch(for series: DICOMSeries) -> DICOMSeries? {
        loadedSeries.first { $0.uid == series.uid }
    }

    private func uniqueIndexSnapshots(_ records: [PACSIndexedSeriesSnapshot]) -> [PACSIndexedSeriesSnapshot] {
        var seen = Set<String>()
        var unique: [PACSIndexedSeriesSnapshot] = []
        for record in records where seen.insert(record.id).inserted {
            unique.append(record)
        }
        return unique
    }

    private func dicomFileIdentity(_ file: DICOMFile) -> String {
        if !file.sopInstanceUID.isEmpty {
            return "sop:\(file.sopInstanceUID)"
        }
        return "path:\(ImageVolume.canonicalPath(file.filePath))"
    }

    @discardableResult
    private func configureFusion(base: ImageVolume,
                                 overlay: ImageVolume,
                                 resampledOverlay: ImageVolume?) -> FusionPair {
        displayVolume(base)
        if Modality.normalize(base.modality) == .CT,
           let softTissue = WLPresets.CT.first(where: { $0.name == "Soft Tissue" }) {
            applyPreset(softTissue)
        }

        let pair = FusionPair(base: base, overlay: overlay)
        pair.resampledOverlay = resampledOverlay
        pair.isGeometryResampled = resampledOverlay != nil
        pair.registrationNote = resampledOverlay == nil
            ? "PET/overlay already matches base grid"
            : "PET/overlay resampled into CT/base world geometry"
        applyFusionDisplayDefaults(for: overlay, pair: pair)
        fusion = pair
        return pair
    }

    private func applyFusionDisplayDefaults(for overlay: ImageVolume, pair: FusionPair) {
        if Modality.normalize(overlay.modality) == .PT {
            overlayOpacity = 0.55
            overlayColormap = .tracerPET
            if overlay.suvScaleFactor != nil {
                suvSettings.mode = .manualScale
                suvSettings.manualScaleFactor = overlay.suvScaleFactor ?? 1
            }

            let maxValue = Double(overlay.intensityRange.max)
            if maxValue.isFinite, maxValue > 0, maxValue <= 25 {
                overlayWindow = 10
                overlayLevel = 5
            } else if maxValue.isFinite, maxValue > 0 {
                overlayWindow = max(1, maxValue * 0.85)
                overlayLevel = maxValue * 0.425
            } else {
                overlayWindow = 10
                overlayLevel = 5
            }
        }

        pair.opacity = overlayOpacity
        pair.colormap = overlayColormap
        pair.overlayWindow = overlayWindow
        pair.overlayLevel = overlayLevel
    }

    private func resampledOverlayIfNeeded(base: ImageVolume,
                                          overlay: ImageVolume) async throws -> ImageVolume? {
        guard !hasMatchingGrid(base, overlay) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            VolumeResampler.resample(overlay: overlay, toMatch: base, mode: .linear)
        }.value
    }

    private func hasMatchingGrid(_ base: ImageVolume, _ overlay: ImageVolume) -> Bool {
        guard base.width == overlay.width,
              base.height == overlay.height,
              base.depth == overlay.depth else {
            return false
        }

        let tolerance = 1e-4
        guard abs(base.spacing.x - overlay.spacing.x) < tolerance,
              abs(base.spacing.y - overlay.spacing.y) < tolerance,
              abs(base.spacing.z - overlay.spacing.z) < tolerance,
              abs(base.origin.x - overlay.origin.x) < tolerance,
              abs(base.origin.y - overlay.origin.y) < tolerance,
              abs(base.origin.z - overlay.origin.z) < tolerance else {
            return false
        }

        for column in 0..<3 {
            for row in 0..<3 where abs(base.direction[column][row] - overlay.direction[column][row]) >= tolerance {
                return false
            }
        }
        return true
    }

    private func bestPETCTPair() -> (ct: ImageVolume, pet: ImageVolume)? {
        let cts = loadedCTVolumes
        let pets = loadedPETVolumes
        guard !cts.isEmpty, !pets.isEmpty else { return nil }

        if let current = currentVolume {
            let currentModality = Modality.normalize(current.modality)
            if currentModality == .CT,
               let pet = pets.max(by: { fusionScore(ct: current, pet: $0) < fusionScore(ct: current, pet: $1) }) {
                return (current, pet)
            }
            if currentModality == .PT,
               let ct = cts.max(by: { fusionScore(ct: $0, pet: current) < fusionScore(ct: $1, pet: current) }) {
                return (ct, current)
            }
        }

        var best: (ct: ImageVolume, pet: ImageVolume, score: Int)?
        for ct in cts {
            for pet in pets {
                let score = fusionScore(ct: ct, pet: pet)
                if best == nil || score > best!.score {
                    best = (ct, pet, score)
                }
            }
        }
        guard let best else { return nil }
        return (best.ct, best.pet)
    }

    private func fusionScore(ct: ImageVolume, pet: ImageVolume) -> Int {
        var score = 0
        if !ct.studyUID.isEmpty, ct.studyUID == pet.studyUID { score += 8 }
        if !ct.patientID.isEmpty, ct.patientID == pet.patientID { score += 4 }
        if !ct.patientName.isEmpty, ct.patientName == pet.patientName { score += 2 }
        if abs(ct.origin.x - pet.origin.x) < 50,
           abs(ct.origin.y - pet.origin.y) < 50,
           abs(ct.origin.z - pet.origin.z) < 50 {
            score += 1
        }
        return score
    }

    // MARK: - Volume display

    public func displayVolume(_ volume: ImageVolume) {
        currentVolume = volume
        sliceIndices = [volume.width / 2, volume.height / 2, volume.depth / 2]

        // Auto window/level
        let (w, l) = autoWindowLevel(pixels: volume.pixels)
        window = w
        level = l
    }

    // MARK: - Slice navigation

    public func scroll(axis: Int, delta: Int) {
        guard let v = currentVolume else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        sliceIndices[axis] = Swift.max(0, Swift.min(max, sliceIndices[axis] + delta))
    }

    public func scrollAllSlices(delta: Int) {
        guard let v = currentVolume, delta != 0 else { return }
        let maxima = [v.width - 1, v.height - 1, v.depth - 1]
        for axis in 0..<3 {
            sliceIndices[axis] = Swift.max(0, Swift.min(maxima[axis], sliceIndices[axis] + delta))
        }
    }

    public func setSlice(axis: Int, index: Int) {
        guard let v = currentVolume else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        sliceIndices[axis] = Swift.max(0, Swift.min(max, index))
    }

    public func displayTransform(for axis: Int, volume: ImageVolume? = nil) -> SliceDisplayTransform {
        guard let volume = volume ?? currentVolume else { return .identity }
        return SliceDisplayTransform.canonical(axis: axis, volume: volume)
    }

    public func displayAxes(for axis: Int, volume: ImageVolume? = nil) -> (right: SIMD3<Double>, down: SIMD3<Double>)? {
        guard let volume = volume ?? currentVolume else { return nil }
        return SliceDisplayTransform.displayAxes(axis: axis, volume: volume)
    }

    // MARK: - W/L manipulation

    public func adjustWindowLevel(dw: Double, dl: Double) {
        window = max(1, window + dw)
        level += dl
    }

    public func applyPreset(_ preset: WindowLevel) {
        window = preset.window
        level = preset.level
    }

    /// Look up a preset by name across the current modality's list first,
    /// falling back to the union of CT + MR + PT presets. Useful for global
    /// keyboard shortcuts that should "just work" regardless of the loaded
    /// modality. Returns a status message describing what happened.
    ///
    /// Normalizes the input so callers don't have to: whitespace is trimmed
    /// and matches are case-insensitive (`"  lung  "` == `"Lung"`). An empty
    /// or whitespace-only name is rejected with a clear status message
    /// rather than silently matching the first preset.
    @discardableResult
    public func applyPresetNamed(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "W/L preset name was empty."
            return statusMessage
        }

        let modality = currentVolume.map { Modality.normalize($0.modality) } ?? .CT
        let modalityPresets = WLPresets.presets(for: modality)
        if let match = modalityPresets.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            applyPreset(match)
            statusMessage = "Applied \(match.name) W/L (\(modality.displayName))"
            return statusMessage
        }
        let union = WLPresets.CT + WLPresets.MR + WLPresets.PT
        if let match = union.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            applyPreset(match)
            statusMessage = "Applied \(match.name) W/L"
            return statusMessage
        }
        statusMessage = "No \(trimmed) preset available for this modality."
        return statusMessage
    }

    public func autoWL() {
        guard let v = currentVolume else { return }
        let (w, l) = autoWindowLevel(pixels: v.pixels)
        window = w
        level = l
    }

    /// Histogram-driven W/L picker, inspired by ITK-SNAP's auto-contrast.
    /// `preset` maps to a percentile clip range (see `HistogramAutoWindow.Preset`).
    public func autoWLHistogram(preset: HistogramAutoWindow.Preset = .balanced) {
        guard let v = currentVolume else { return }
        let ignoreZeros = Modality.normalize(v.modality) == .PT
        let result = HistogramAutoWindow.compute(v,
                                                  preset: preset,
                                                  ignoreZeros: ignoreZeros)
        window = result.window
        level = result.level
        statusMessage = String(format: "Auto W/L: W=%.0f L=%.0f (%.0f–%.0f)",
                               result.window, result.level,
                               result.lowerValue, result.upperValue)
    }

    public func suvValue(rawStoredValue: Double) -> Double {
        if let vol = activePETQuantificationVolume {
            return suvSettings.suv(forStoredValue: rawStoredValue, volume: vol)
        }
        return suvSettings.suv(forStoredValue: rawStoredValue)
    }

    /// Volume-aware SUV lookup. Callers that already have a specific PET
    /// volume in hand (e.g. the PET Engine staging an auxiliary channel for
    /// nnU-Net inference) should use this — it honours the per-volume DICOM
    /// SUV scale factor when the user has `.storedSUV` selected, which the
    /// plain `suvValue(rawStoredValue:)` can't do for any volume other than
    /// the currently-active one.
    public func suvValue(rawStoredValue: Double, volume: ImageVolume) -> Double {
        suvSettings.suv(forStoredValue: rawStoredValue, volume: volume)
    }

    public func activePETProbe() -> SUVProbe? {
        guard let pet = activePETQuantificationVolume else { return nil }
        let z = min(max(sliceIndices[2], 0), pet.depth - 1)
        let y = min(max(sliceIndices[1], 0), pet.height - 1)
        let x = min(max(sliceIndices[0], 0), pet.width - 1)
        return suvProbe(z: z, y: y, x: x, in: pet)
    }

    public func suvProbe(z: Int, y: Int, x: Int, in volume: ImageVolume? = nil) -> SUVProbe? {
        let pet = volume ?? activePETQuantificationVolume
        guard let pet else { return nil }
        guard z >= 0, z < pet.depth, y >= 0, y < pet.height, x >= 0, x < pet.width else {
            return nil
        }
        let raw = Double(pet.intensity(z: z, y: y, x: x))
        return SUVProbe(
            voxel: (z: z, y: y, x: x),
            rawValue: raw,
            suv: suvValue(rawStoredValue: raw, volume: pet)
        )
    }

    public func activePETRegionStats(for labelMap: LabelMap,
                                     classID: UInt16) -> RegionStats? {
        guard let pet = activePETVolumeMatching(labelMap) else {
            return nil
        }
        return RegionStats.compute(
            pet,
            labelMap,
            classID: classID,
            suvTransform: suvTransform(for: pet)
        )
    }

    public func thresholdActiveLabel(atOrAbove threshold: Double) {
        guard let map = labeling.activeLabelMap else {
            statusMessage = "Create or select a label map before thresholding"
            return
        }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.thresholdValue = threshold
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        var count = 0
        labeling.recordVoxelEdit(named: "SUV threshold") {
            count = PETSegmentation.thresholdAbove(
                volume: source.volume,
                label: map,
                threshold: threshold,
                classID: labeling.activeClassID,
                valueTransform: transform
            )
        }
        map.objectWillChange.send()

        let unit = source.usesSUV ? "SUV" : "intensity"
        statusMessage = "Segmented \(count) voxels at \(unit) >= \(String(format: "%.2f", threshold))"
    }

    public func percentOfMaxActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                                  boxRadius: Int = 30,
                                                  percent: Double) {
        guard let map = labeling.activeLabelMap else {
            statusMessage = "Create or select a label map before seed thresholding"
            return
        }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.percentOfMax = percent
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let box = VoxelBox.around(seed, radius: boxRadius, in: source.volume)
        var count = 0
        labeling.recordVoxelEdit(named: "SUV percent of max") {
            count = PETSegmentation.percentOfMax(
                volume: source.volume,
                label: map,
                percent: percent,
                classID: labeling.activeClassID,
                boundingBox: box,
                valueTransform: transform
            )
        }
        map.objectWillChange.send()

        let unit = source.usesSUV ? "SUVmax" : "intensity max"
        statusMessage = "Segmented \(count) voxels at \(Int(percent * 100))% of \(unit)"
    }

    public func gradientActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                              minimumValue: Double,
                                              gradientCutoffFraction: Double,
                                              searchRadius: Int) {
        guard let map = labeling.activeLabelMap else {
            statusMessage = "Create or select a label map before SUV gradient segmentation"
            return
        }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.thresholdValue = minimumValue
        labeling.gradientCutoffFraction = gradientCutoffFraction
        labeling.gradientSearchRadius = searchRadius
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let result = labeling.gradientEdge(
            volume: source.volume,
            seed: seed,
            minimumValue: minimumValue,
            gradientCutoffFraction: gradientCutoffFraction,
            searchRadius: searchRadius,
            valueTransform: transform
        )

        let unit = source.usesSUV ? "SUV" : "intensity"
        statusMessage = "SUV gradient segmented \(result.voxelCount) voxels | floor \(unit) \(String(format: "%.2f", minimumValue)), peak \(String(format: "%.2f", result.maxValue)), edge \(String(format: "%.3f", result.gradientCutoff))/mm"
    }

    private func suvTransform(for volume: ImageVolume) -> (Double) -> Double {
        { [suvSettings, volume] rawValue in
            suvSettings.suv(forStoredValue: rawValue, volume: volume)
        }
    }

    private func activePETVolumeMatching(_ labelMap: LabelMap) -> ImageVolume? {
        if let fusion, sameGrid(fusion.displayedOverlay, labelMap) {
            return fusion.displayedOverlay
        }
        if let currentVolume,
           Modality.normalize(currentVolume.modality) == .PT,
           sameGrid(currentVolume, labelMap) {
            return currentVolume
        }
        return nil
    }

    private func activeSegmentationSource(matching labelMap: LabelMap) -> (volume: ImageVolume, usesSUV: Bool)? {
        if let pet = activePETVolumeMatching(labelMap) {
            return (pet, true)
        }
        if let currentVolume, sameGrid(currentVolume, labelMap) {
            return (currentVolume, Modality.normalize(currentVolume.modality) == .PT)
        }
        return nil
    }

    private func sameGrid(_ volume: ImageVolume, _ labelMap: LabelMap) -> Bool {
        volume.width == labelMap.width &&
        volume.height == labelMap.height &&
        volume.depth == labelMap.depth
    }

    // MARK: - Slice images

    public func makeImage(for axis: Int) -> CGImage? {
        guard let v = currentVolume else { return nil }
        let slice = v.slice(axis: axis, index: sliceIndices[axis])
        var pixels = slice.pixels
        let w = slice.width, h = slice.height

        pixels = SliceTransform.apply(pixels, width: w, height: h,
                                      transform: displayTransform(for: axis, volume: v))

        return PixelRenderer.makeGrayImage(
            pixels: pixels, width: w, height: h,
            window: window, level: level, invert: invertColors
        )
    }

    public func makeLabelImage(for axis: Int, outlineOnly: Bool = false) -> CGImage? {
        guard let map = labeling.activeLabelMap else { return nil }
        guard map.visible else { return nil }
        let slice = map.slice(axis: axis, index: sliceIndices[axis])
        var values = slice.values
        let w = slice.width, h = slice.height
        values = SliceTransform.apply(values, width: w, height: h,
                                      transform: displayTransform(for: axis))
        if outlineOnly {
            return LabelRenderer.makeOutlineImage(values: values, width: w, height: h,
                                                    classes: map.classes,
                                                    baseAlpha: map.opacity)
        }
        return LabelRenderer.makeImage(values: values, width: w, height: h,
                                         classes: map.classes,
                                         baseAlpha: map.opacity)
    }

    public func makeOverlayImage(for axis: Int) -> CGImage? {
        guard let pair = fusion else { return nil }
        guard pair.overlayVisible else { return nil }
        let ov = pair.displayedOverlay
        let slice = ov.slice(axis: axis, index: sliceIndices[axis])
        var pixels = slice.pixels
        let w = slice.width, h = slice.height
        pixels = SliceTransform.apply(pixels, width: w, height: h,
                                      transform: displayTransform(for: axis, volume: pair.baseVolume))
        return PixelRenderer.makeColorImage(
            pixels: pixels, width: w, height: h,
            window: pair.overlayWindow, level: pair.overlayLevel,
            colormap: pair.colormap,
            baseAlpha: pair.opacity
        )
    }
}

private func findNIfTIFiles(in url: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let fileURL as URL in enumerator {
        let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isFile, NIfTILoader.isVolumeFile(fileURL) else { continue }
        files.append(fileURL)
    }
    return files.sorted { $0.path < $1.path }
}
