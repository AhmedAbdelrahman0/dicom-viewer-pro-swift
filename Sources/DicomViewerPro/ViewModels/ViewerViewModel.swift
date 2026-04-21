import Foundation
import SwiftUI
import Combine
import SwiftData

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
    @Published public var overlayColormap: Colormap = .hot
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3

    // Annotations per view
    @Published public var annotations: [Annotation] = []

    // Status
    @Published public var statusMessage: String = "Ready. Open a DICOM or NIfTI file to begin."
    @Published public var isLoading: Bool = false
    @Published public var progress: Double = 0

    // DICOM study browser
    @Published public var loadedSeries: [DICOMSeries] = []

    public init() {}

    // MARK: - Loading

    public func loadNIfTI(url: URL) async {
        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try NIfTILoader.load(url)
            }.value

            displayVolume(volume)
            loadedVolumes.append(volume)
            statusMessage = "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
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

        loadedSeries.append(contentsOf: series)
        statusMessage = "Found \(series.count) series"

        // Open first series automatically
        if let first = series.first {
            await openSeries(first)
        }
    }

    public func openSeries(_ series: DICOMSeries) async {
        isLoading = true
        statusMessage = "Loading \(series.displayName)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try DICOMLoader.loadSeries(series.files)
            }.value

            displayVolume(volume)
            loadedVolumes.append(volume)
            statusMessage = "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func indexDirectory(url: URL, modelContext: ModelContext) async {
        isLoading = true
        statusMessage = "Indexing \(url.lastPathComponent)..."
        defer { isLoading = false }

        let scanResult = await Task.detached(priority: .userInitiated) {
            let dicomSeries = DICOMLoader.scanDirectory(url)
            let niftiURLs = findNIfTIFiles(in: url)
            return (dicomSeries, niftiURLs)
        }.value

        let records = scanResult.0.map {
            PACSIndexBuilder.record(for: $0, sourcePath: url.path)
        } + scanResult.1.map {
            PACSIndexBuilder.recordForNIfTI(url: $0)
        }

        do {
            for record in records {
                try upsertIndexedSeries(record, in: modelContext)
            }
            try modelContext.save()
            statusMessage = "Indexed \(records.count) series in Mini-PACS"
        } catch {
            statusMessage = "Index error: \(error.localizedDescription)"
        }
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

    public func loadOverlay(url: URL) async {
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

            let pair = FusionPair(base: base, overlay: overlay)
            pair.opacity = overlayOpacity
            pair.colormap = overlayColormap

            // Auto SUV range for PET overlays
            if Modality.normalize(overlay.modality) == .PT {
                let mn = overlay.intensityRange.min
                let mx = overlay.intensityRange.max
                overlayWindow = Double(mx - mn) * 0.8
                overlayLevel = Double(mn + mx) * 0.5
                pair.overlayWindow = overlayWindow
                pair.overlayLevel = overlayLevel
            }

            fusion = pair
            statusMessage = "Fusion loaded: \(pair.fusionTypeLabel)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
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

    private func upsertIndexedSeries(_ record: PACSIndexedSeries,
                                     in modelContext: ModelContext) throws {
        let id = record.id
        var descriptor = FetchDescriptor<PACSIndexedSeries>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: record)
        } else {
            modelContext.insert(record)
        }
    }

    public func removeOverlay() {
        fusion = nil
        statusMessage = "Overlay removed"
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

    // MARK: - W/L manipulation

    public func adjustWindowLevel(dw: Double, dl: Double) {
        window = max(1, window + dw)
        level += dl
    }

    public func applyPreset(_ preset: WindowLevel) {
        window = preset.window
        level = preset.level
    }

    public func autoWL() {
        guard let v = currentVolume else { return }
        let (w, l) = autoWindowLevel(pixels: v.pixels)
        window = w
        level = l
    }

    // MARK: - Slice images

    public func makeImage(for axis: Int) -> CGImage? {
        guard let v = currentVolume else { return nil }
        let slice = v.slice(axis: axis, index: sliceIndices[axis])
        var pixels = slice.pixels
        let w = slice.width, h = slice.height

        // Default orientation: flip vertical for sag/cor so head is at top
        if axis == 0 || axis == 1 {
            pixels = SliceTransform.flipVertical(pixels, width: w, height: h)
        }

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
        // Flip for sagittal/coronal (match base slice orientation)
        if axis == 0 || axis == 1 {
            var flipped = [UInt16](repeating: 0, count: values.count)
            for row in 0..<h {
                for col in 0..<w {
                    flipped[(h - 1 - row) * w + col] = values[row * w + col]
                }
            }
            values = flipped
        }
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
        let ov = pair.displayedOverlay
        let slice = ov.slice(axis: axis, index: sliceIndices[axis])
        var pixels = slice.pixels
        let w = slice.width, h = slice.height
        if axis == 0 || axis == 1 {
            pixels = SliceTransform.flipVertical(pixels, width: w, height: h)
        }
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
