import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class NuclearReconstructionViewModel: ObservableObject {
    @Published public var rawSinogramPath: String = ""
    @Published public var modality: NuclearReconstructionModality = .pet
    @Published public var algorithm: ReconstructionAlgorithm = .filteredBackProjection
    @Published public var endian: RawFloatEndian = .little
    @Published public var detectorCount: Int = 256
    @Published public var projectionCount: Int = 180
    @Published public var detectorSpacingMM: Double = 2.0
    @Published public var radialOffsetMM: Double = 0
    @Published public var imageWidth: Int = 256
    @Published public var imageHeight: Int = 256
    @Published public var pixelSpacingMM: Double = 2.0
    @Published public var sliceThicknessMM: Double = 2.0
    @Published public var iterations: Int = 8
    @Published public var positivityFloor: Double = 0

    @Published public private(set) var isRunning = false
    @Published public private(set) var statusMessage = "Ready"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastVolume: ImageVolume?

    private var task: Task<Void, Never>?

    public init() {}

    public var expectedByteCount: Int {
        max(0, detectorCount) * max(0, projectionCount) * MemoryLayout<Float>.size
    }

    public var canRun: Bool {
        !expandedRawSinogramPath.isEmpty && FileManager.default.fileExists(atPath: expandedRawSinogramPath)
    }

    public func run(viewer: ViewerViewModel) {
        guard !isRunning else { return }
        guard canRun else {
            statusMessage = "Choose a raw Float32 sinogram file first."
            return
        }

        let inputPath = expandedRawSinogramPath
        let modality = self.modality
        let algorithm = self.algorithm
        let endian = self.endian
        let detectorCount = self.detectorCount
        let projectionCount = self.projectionCount
        let detectorSpacingMM = self.detectorSpacingMM
        let radialOffsetMM = self.radialOffsetMM
        let imageWidth = self.imageWidth
        let imageHeight = self.imageHeight
        let pixelSpacingMM = self.pixelSpacingMM
        let sliceThicknessMM = self.sliceThicknessMM
        let iterations = self.iterations
        let positivityFloor = Float(self.positivityFloor)

        isRunning = true
        errorMessage = nil
        statusMessage = "Reconstructing \(modality.rawValue) sinogram..."

        task = Task { [weak self, viewer] in
            do {
                let volume = try await Task.detached(priority: .userInitiated) {
                    let angles = (0..<projectionCount).map { index in
                        Double(index) * Double.pi / Double(projectionCount)
                    }
                    let geometry = try ParallelBeamGeometry(
                        detectorCount: detectorCount,
                        anglesRadians: angles,
                        detectorSpacingMM: detectorSpacingMM,
                        radialOffsetMM: radialOffsetMM
                    )
                    let sinogram = try SinogramIO.loadRawFloat32(
                        url: URL(fileURLWithPath: inputPath),
                        geometry: geometry,
                        modality: modality,
                        endian: endian
                    )
                    let grid = try ReconstructionGrid2D(
                        width: imageWidth,
                        height: imageHeight,
                        pixelSpacingMM: pixelSpacingMM
                    )
                    let options = try ReconstructionOptions(
                        algorithm: algorithm,
                        iterations: iterations,
                        positivityFloor: positivityFloor
                    )
                    let image = try NuclearReconstructor.reconstruct2D(
                        sinogram: sinogram,
                        grid: grid,
                        options: options
                    )
                    return try image.asImageVolume(
                        sliceThicknessMM: sliceThicknessMM,
                        seriesDescription: "\(modality.rawValue) \(algorithm.displayName) reconstruction"
                    )
                }.value

                guard !Task.isCancelled else { return }
                let installed = viewer.addLoadedVolumeIfNeeded(volume).volume
                viewer.displayVolume(installed)
                self?.lastVolume = installed
                self?.statusMessage = "Reconstruction ready: \(installed.width)x\(installed.height)x\(installed.depth)"
            } catch is CancellationError {
                self?.statusMessage = "Reconstruction cancelled"
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.statusMessage = "Reconstruction failed"
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        statusMessage = "Reconstruction cancelled"
    }

    #if canImport(AppKit)
    public func pickRawSinogram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a raw Float32 sinogram"
        if panel.runModal() == .OK, let url = panel.url {
            rawSinogramPath = url.path
        }
    }
    #endif

    private var expandedRawSinogramPath: String {
        (rawSinogramPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
    }
}

extension RawFloatEndian: CaseIterable, Hashable {
    public static var allCases: [RawFloatEndian] { [.little, .big] }

    public var displayName: String {
        switch self {
        case .little: return "Little endian"
        case .big: return "Big endian"
        }
    }
}
