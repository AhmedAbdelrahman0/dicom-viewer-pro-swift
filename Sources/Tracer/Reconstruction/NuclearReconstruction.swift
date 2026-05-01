import Foundation
import simd

public enum NuclearReconstructionModality: String, CaseIterable, Sendable {
    case pet = "PET"
    case spect = "SPECT"

    public var dicomModality: String {
        switch self {
        case .pet: return "PT"
        case .spect: return "NM"
        }
    }
}

public enum ReconstructionAlgorithm: String, CaseIterable, Sendable {
    case filteredBackProjection
    case mlem

    public var displayName: String {
        switch self {
        case .filteredBackProjection: return "Filtered back projection"
        case .mlem: return "MLEM"
        }
    }
}

public enum ReconstructionError: Error, LocalizedError, Equatable {
    case invalidGeometry(String)
    case invalidSinogram(String)
    case invalidGrid(String)
    case invalidImage(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGeometry(let message),
             .invalidSinogram(let message),
             .invalidGrid(let message),
             .invalidImage(let message),
             .io(let message):
            return message
        }
    }
}

public struct ParallelBeamGeometry: Equatable, Sendable {
    public let detectorCount: Int
    public let anglesRadians: [Double]
    public let detectorSpacingMM: Double
    public let radialOffsetMM: Double

    public init(detectorCount: Int,
                anglesRadians: [Double],
                detectorSpacingMM: Double,
                radialOffsetMM: Double = 0) throws {
        guard detectorCount > 1 else {
            throw ReconstructionError.invalidGeometry("Parallel-beam geometry requires at least two detector bins.")
        }
        guard !anglesRadians.isEmpty else {
            throw ReconstructionError.invalidGeometry("Parallel-beam geometry requires at least one projection angle.")
        }
        guard detectorSpacingMM > 0, detectorSpacingMM.isFinite else {
            throw ReconstructionError.invalidGeometry("Detector spacing must be a positive finite number.")
        }
        guard radialOffsetMM.isFinite else {
            throw ReconstructionError.invalidGeometry("Detector radial offset must be finite.")
        }
        guard anglesRadians.allSatisfy(\.isFinite) else {
            throw ReconstructionError.invalidGeometry("Projection angles must be finite.")
        }

        self.detectorCount = detectorCount
        self.anglesRadians = anglesRadians
        self.detectorSpacingMM = detectorSpacingMM
        self.radialOffsetMM = radialOffsetMM
    }

    public var angleCount: Int { anglesRadians.count }

    public func detectorCoordinate(index: Int) -> Double {
        (Double(index) - detectorCenterIndex) * detectorSpacingMM + radialOffsetMM
    }

    public func detectorIndex(forCoordinate coordinate: Double) -> Double {
        ((coordinate - radialOffsetMM) / detectorSpacingMM) + detectorCenterIndex
    }

    private var detectorCenterIndex: Double {
        Double(detectorCount - 1) / 2.0
    }
}

public struct Sinogram2D: Sendable {
    public let modality: NuclearReconstructionModality
    public let geometry: ParallelBeamGeometry
    public let bins: [Float]

    public init(modality: NuclearReconstructionModality,
                geometry: ParallelBeamGeometry,
                bins: [Float]) throws {
        let expectedCount = geometry.detectorCount * geometry.angleCount
        guard bins.count == expectedCount else {
            throw ReconstructionError.invalidSinogram("Sinogram has \(bins.count) bins, expected \(expectedCount).")
        }
        guard bins.allSatisfy({ $0.isFinite }) else {
            throw ReconstructionError.invalidSinogram("Sinogram contains NaN or infinite values.")
        }

        self.modality = modality
        self.geometry = geometry
        self.bins = bins
    }

    public func value(angleIndex: Int, detectorIndex: Int) -> Float {
        guard angleIndex >= 0,
              angleIndex < geometry.angleCount,
              detectorIndex >= 0,
              detectorIndex < geometry.detectorCount else {
            return 0
        }
        return bins[angleIndex * geometry.detectorCount + detectorIndex]
    }

    public func projection(angleIndex: Int) -> ArraySlice<Float> {
        let clamped = max(0, min(geometry.angleCount - 1, angleIndex))
        let start = clamped * geometry.detectorCount
        return bins[start..<(start + geometry.detectorCount)]
    }
}

public struct ReconstructionGrid2D: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelSpacingMM: Double
    public let originXMM: Double
    public let originYMM: Double

    public init(width: Int,
                height: Int,
                pixelSpacingMM: Double,
                originXMM: Double? = nil,
                originYMM: Double? = nil) throws {
        guard width > 0, height > 0 else {
            throw ReconstructionError.invalidGrid("Reconstruction grid dimensions must be positive.")
        }
        guard pixelSpacingMM > 0, pixelSpacingMM.isFinite else {
            throw ReconstructionError.invalidGrid("Reconstruction pixel spacing must be a positive finite number.")
        }

        let defaultOriginX = -Double(width - 1) * pixelSpacingMM / 2.0
        let defaultOriginY = -Double(height - 1) * pixelSpacingMM / 2.0
        let x = originXMM ?? defaultOriginX
        let y = originYMM ?? defaultOriginY
        guard x.isFinite, y.isFinite else {
            throw ReconstructionError.invalidGrid("Reconstruction grid origin must be finite.")
        }

        self.width = width
        self.height = height
        self.pixelSpacingMM = pixelSpacingMM
        self.originXMM = x
        self.originYMM = y
    }

    public var voxelCount: Int { width * height }

    public func worldX(index: Int) -> Double {
        originXMM + Double(index) * pixelSpacingMM
    }

    public func worldY(index: Int) -> Double {
        originYMM + Double(index) * pixelSpacingMM
    }
}

public struct ReconstructionOptions: Equatable, Sendable {
    public let algorithm: ReconstructionAlgorithm
    public let iterations: Int
    public let positivityFloor: Float

    public init(algorithm: ReconstructionAlgorithm = .filteredBackProjection,
                iterations: Int = 8,
                positivityFloor: Float = 0) throws {
        guard iterations > 0 else {
            throw ReconstructionError.invalidImage("Iterative reconstruction requires at least one iteration.")
        }
        guard positivityFloor >= 0, positivityFloor.isFinite else {
            throw ReconstructionError.invalidImage("Positivity floor must be a non-negative finite value.")
        }

        self.algorithm = algorithm
        self.iterations = iterations
        self.positivityFloor = positivityFloor
    }

    private init(uncheckedAlgorithm algorithm: ReconstructionAlgorithm,
                 iterations: Int,
                 positivityFloor: Float) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.positivityFloor = positivityFloor
    }

    public static let standard = ReconstructionOptions(
        uncheckedAlgorithm: .filteredBackProjection,
        iterations: 8,
        positivityFloor: 0
    )
}

public struct ReconstructionImage2D: Sendable {
    public let grid: ReconstructionGrid2D
    public let modality: NuclearReconstructionModality
    public let pixels: [Float]

    public init(grid: ReconstructionGrid2D,
                modality: NuclearReconstructionModality,
                pixels: [Float]) throws {
        guard pixels.count == grid.voxelCount else {
            throw ReconstructionError.invalidImage("Reconstruction image has \(pixels.count) pixels, expected \(grid.voxelCount).")
        }
        guard pixels.allSatisfy(\.isFinite) else {
            throw ReconstructionError.invalidImage("Reconstruction image contains NaN or infinite values.")
        }

        self.grid = grid
        self.modality = modality
        self.pixels = pixels
    }

    public func value(y: Int, x: Int) -> Float {
        guard x >= 0, x < grid.width, y >= 0, y < grid.height else { return 0 }
        return pixels[y * grid.width + x]
    }

    public func asImageVolume(sliceThicknessMM: Double = 1,
                              seriesDescription: String? = nil) throws -> ImageVolume {
        guard sliceThicknessMM > 0, sliceThicknessMM.isFinite else {
            throw ReconstructionError.invalidImage("Slice thickness must be a positive finite number.")
        }

        return ImageVolume(
            pixels: pixels,
            depth: 1,
            height: grid.height,
            width: grid.width,
            spacing: (grid.pixelSpacingMM, grid.pixelSpacingMM, sliceThicknessMM),
            origin: (grid.originXMM, grid.originYMM, 0),
            direction: matrix_identity_double3x3,
            modality: modality.dicomModality,
            seriesDescription: seriesDescription ?? "\(modality.rawValue) reconstruction"
        )
    }
}

public enum RawFloatEndian: Sendable {
    case little
    case big
}

public enum SinogramIO {
    public static func loadRawFloat32(url: URL,
                                      geometry: ParallelBeamGeometry,
                                      modality: NuclearReconstructionModality,
                                      endian: RawFloatEndian = .little) throws -> Sinogram2D {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReconstructionError.io("Could not read raw sinogram: \(error.localizedDescription)")
        }

        let expectedBytes = geometry.detectorCount * geometry.angleCount * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw ReconstructionError.invalidSinogram("Raw sinogram has \(data.count) bytes, expected \(expectedBytes).")
        }

        var values = [Float]()
        values.reserveCapacity(geometry.detectorCount * geometry.angleCount)
        for offset in stride(from: 0, to: data.count, by: MemoryLayout<Float>.size) {
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            let bits: UInt32
            switch endian {
            case .little:
                bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            case .big:
                bits = b3 | (b2 << 8) | (b1 << 16) | (b0 << 24)
            }
            values.append(Float(bitPattern: bits))
        }

        return try Sinogram2D(modality: modality, geometry: geometry, bins: values)
    }
}

public enum NuclearReconstructor {
    public static func reconstruct2D(sinogram: Sinogram2D,
                                     grid: ReconstructionGrid2D,
                                     options: ReconstructionOptions = .standard) throws -> ReconstructionImage2D {
        let pixels: [Float]
        switch options.algorithm {
        case .filteredBackProjection:
            pixels = filteredBackProjection(sinogram: sinogram, grid: grid)
        case .mlem:
            pixels = try mlem(sinogram: sinogram, grid: grid, options: options)
        }
        return try ReconstructionImage2D(grid: grid, modality: sinogram.modality, pixels: pixels)
    }

    public static func forwardProject(image: ReconstructionImage2D,
                                      geometry: ParallelBeamGeometry) throws -> Sinogram2D {
        let bins = forwardProject(pixels: image.pixels, grid: image.grid, geometry: geometry)
        return try Sinogram2D(modality: image.modality, geometry: geometry, bins: bins)
    }

    private static func filteredBackProjection(sinogram: Sinogram2D,
                                               grid: ReconstructionGrid2D) -> [Float] {
        var filteredBins = [Float](repeating: 0, count: sinogram.bins.count)
        for angleIndex in 0..<sinogram.geometry.angleCount {
            let projection = Array(sinogram.projection(angleIndex: angleIndex))
            let filtered = rampFilter(projection, detectorSpacingMM: sinogram.geometry.detectorSpacingMM)
            let start = angleIndex * sinogram.geometry.detectorCount
            for detectorIndex in 0..<sinogram.geometry.detectorCount {
                filteredBins[start + detectorIndex] = filtered[detectorIndex]
            }
        }

        let filteredSinogram = try? Sinogram2D(
            modality: sinogram.modality,
            geometry: sinogram.geometry,
            bins: filteredBins
        )
        guard let filteredSinogram else { return [Float](repeating: 0, count: grid.voxelCount) }

        var image = backProject(sinogram: filteredSinogram, grid: grid)
        let scale = Float(Double.pi / Double(sinogram.geometry.angleCount))
        for index in image.indices {
            image[index] *= scale
        }
        return image
    }

    private static func mlem(sinogram: Sinogram2D,
                             grid: ReconstructionGrid2D,
                             options: ReconstructionOptions) throws -> [Float] {
        let floorValue = max(options.positivityFloor, Float.leastNonzeroMagnitude)
        var estimate = [Float](repeating: max(1, floorValue), count: grid.voxelCount)
        let ones = try Sinogram2D(
            modality: sinogram.modality,
            geometry: sinogram.geometry,
            bins: [Float](repeating: 1, count: sinogram.bins.count)
        )
        let sensitivity = backProject(sinogram: ones, grid: grid)

        for _ in 0..<options.iterations {
            let projected = forwardProject(pixels: estimate, grid: grid, geometry: sinogram.geometry)
            var ratioBins = [Float](repeating: 0, count: sinogram.bins.count)
            for index in ratioBins.indices {
                let expected = max(projected[index], 1e-6)
                ratioBins[index] = max(sinogram.bins[index], 0) / expected
            }

            let ratio = try Sinogram2D(
                modality: sinogram.modality,
                geometry: sinogram.geometry,
                bins: ratioBins
            )
            let correction = backProject(sinogram: ratio, grid: grid)
            for index in estimate.indices {
                let normalizer = max(sensitivity[index], 1e-6)
                let next = estimate[index] * correction[index] / normalizer
                estimate[index] = max(next.isFinite ? next : floorValue, floorValue)
            }
        }

        return estimate
    }

    private static func forwardProject(pixels: [Float],
                                       grid: ReconstructionGrid2D,
                                       geometry: ParallelBeamGeometry) -> [Float] {
        var bins = [Float](repeating: 0, count: geometry.detectorCount * geometry.angleCount)
        for angleIndex in 0..<geometry.angleCount {
            let angle = geometry.anglesRadians[angleIndex]
            let cosTheta = cos(angle)
            let sinTheta = sin(angle)
            let projectionOffset = angleIndex * geometry.detectorCount

            for y in 0..<grid.height {
                let worldY = grid.worldY(index: y)
                for x in 0..<grid.width {
                    let value = pixels[y * grid.width + x]
                    guard value != 0, value.isFinite else { continue }

                    let worldX = grid.worldX(index: x)
                    let detectorPosition = worldX * cosTheta + worldY * sinTheta
                    accumulate(value,
                               detectorPosition: detectorPosition,
                               geometry: geometry,
                               bins: &bins,
                               projectionOffset: projectionOffset)
                }
            }
        }
        return bins
    }

    private static func backProject(sinogram: Sinogram2D,
                                    grid: ReconstructionGrid2D) -> [Float] {
        var pixels = [Float](repeating: 0, count: grid.voxelCount)
        for angleIndex in 0..<sinogram.geometry.angleCount {
            let angle = sinogram.geometry.anglesRadians[angleIndex]
            let cosTheta = cos(angle)
            let sinTheta = sin(angle)
            let projectionStart = angleIndex * sinogram.geometry.detectorCount

            for y in 0..<grid.height {
                let worldY = grid.worldY(index: y)
                for x in 0..<grid.width {
                    let worldX = grid.worldX(index: x)
                    let detectorPosition = worldX * cosTheta + worldY * sinTheta
                    let value = interpolatedProjectionValue(
                        bins: sinogram.bins,
                        projectionStart: projectionStart,
                        detectorPosition: detectorPosition,
                        geometry: sinogram.geometry
                    )
                    pixels[y * grid.width + x] += value
                }
            }
        }
        return pixels
    }

    private static func rampFilter(_ projection: [Float],
                                   detectorSpacingMM: Double) -> [Float] {
        let count = projection.count
        var output = [Float](repeating: 0, count: count)
        let spacingSquared = detectorSpacingMM * detectorSpacingMM

        for i in 0..<count {
            var sum = 0.0
            for j in 0..<count {
                let offset = i - j
                let kernel: Double
                if offset == 0 {
                    kernel = 1.0 / (4.0 * spacingSquared)
                } else if abs(offset).isMultiple(of: 2) {
                    kernel = 0
                } else {
                    let distance = Double(offset)
                    kernel = -1.0 / (Double.pi * Double.pi * distance * distance * spacingSquared)
                }
                sum += Double(projection[j]) * kernel
            }
            output[i] = Float(sum)
        }

        return output
    }

    private static func accumulate(_ value: Float,
                                   detectorPosition: Double,
                                   geometry: ParallelBeamGeometry,
                                   bins: inout [Float],
                                   projectionOffset: Int) {
        let detectorIndex = geometry.detectorIndex(forCoordinate: detectorPosition)
        let lowerIndex = Int(floor(detectorIndex))
        let upperIndex = lowerIndex + 1
        let upperWeight = Float(detectorIndex - Double(lowerIndex))
        let lowerWeight = 1 - upperWeight

        if lowerIndex >= 0, lowerIndex < geometry.detectorCount {
            bins[projectionOffset + lowerIndex] += value * lowerWeight
        }
        if upperIndex >= 0, upperIndex < geometry.detectorCount {
            bins[projectionOffset + upperIndex] += value * upperWeight
        }
    }

    private static func interpolatedProjectionValue(bins: [Float],
                                                    projectionStart: Int,
                                                    detectorPosition: Double,
                                                    geometry: ParallelBeamGeometry) -> Float {
        let detectorIndex = geometry.detectorIndex(forCoordinate: detectorPosition)
        let lowerIndex = Int(floor(detectorIndex))
        let upperIndex = lowerIndex + 1
        let upperWeight = Float(detectorIndex - Double(lowerIndex))
        let lowerWeight = 1 - upperWeight

        var value: Float = 0
        if lowerIndex >= 0, lowerIndex < geometry.detectorCount {
            value += bins[projectionStart + lowerIndex] * lowerWeight
        }
        if upperIndex >= 0, upperIndex < geometry.detectorCount {
            value += bins[projectionStart + upperIndex] * upperWeight
        }
        return value
    }
}
