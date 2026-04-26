import Foundation

public enum SyntheticCTMethod: String, CaseIterable, Sendable {
    case researchHeuristicPETToCT
    case coreMLModel
    case subprocessModel

    public var displayName: String {
        switch self {
        case .researchHeuristicPETToCT: return "Research PET-to-CT heuristic"
        case .coreMLModel: return "Core ML synthetic CT model"
        case .subprocessModel: return "External synthetic CT model"
        }
    }

    public var requiresConfiguredModel: Bool {
        switch self {
        case .researchHeuristicPETToCT: return false
        case .coreMLModel, .subprocessModel: return true
        }
    }
}

public enum SyntheticCTError: Error, LocalizedError, Equatable {
    case unsupportedModality(String)
    case invalidOptions(String)
    case emptyVolume
    case invalidModelOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModality(let message),
             .invalidOptions(let message),
             .invalidModelOutput(let message):
            return message
        case .emptyVolume:
            return "Synthetic CT generation requires a non-empty PET volume."
        }
    }
}

public struct SyntheticCTOptions: Equatable, Sendable {
    public var method: SyntheticCTMethod
    public var bodySUVThreshold: Double
    public var intenseUptakeSUV: Double
    public var airHU: Float
    public var softTissueHU: Float
    public var highUptakeHU: Float
    public var minimumHU: Float
    public var maximumHU: Float
    public var smoothingRadiusVoxels: Int
    public var seriesDescription: String

    public init(method: SyntheticCTMethod = .researchHeuristicPETToCT,
                bodySUVThreshold: Double = 0.05,
                intenseUptakeSUV: Double = 12,
                airHU: Float = -1_000,
                softTissueHU: Float = 35,
                highUptakeHU: Float = 110,
                minimumHU: Float = -1_024,
                maximumHU: Float = 3_071,
                smoothingRadiusVoxels: Int = 1,
                seriesDescription: String = "Synthetic CT from PET") throws {
        guard bodySUVThreshold >= 0, bodySUVThreshold.isFinite else {
            throw SyntheticCTError.invalidOptions("Body SUV threshold must be a non-negative finite value.")
        }
        guard intenseUptakeSUV > bodySUVThreshold, intenseUptakeSUV.isFinite else {
            throw SyntheticCTError.invalidOptions("Intense uptake SUV must be finite and greater than the body threshold.")
        }
        guard [airHU, softTissueHU, highUptakeHU, minimumHU, maximumHU].allSatisfy(\.isFinite) else {
            throw SyntheticCTError.invalidOptions("Synthetic CT HU values must be finite.")
        }
        guard minimumHU < maximumHU else {
            throw SyntheticCTError.invalidOptions("Minimum HU must be less than maximum HU.")
        }
        guard smoothingRadiusVoxels >= 0 else {
            throw SyntheticCTError.invalidOptions("Smoothing radius cannot be negative.")
        }

        self.method = method
        self.bodySUVThreshold = bodySUVThreshold
        self.intenseUptakeSUV = intenseUptakeSUV
        self.airHU = airHU
        self.softTissueHU = softTissueHU
        self.highUptakeHU = highUptakeHU
        self.minimumHU = minimumHU
        self.maximumHU = maximumHU
        self.smoothingRadiusVoxels = smoothingRadiusVoxels
        self.seriesDescription = seriesDescription
    }

    public static var researchDefault: SyntheticCTOptions {
        try! SyntheticCTOptions()
    }
}

public struct SyntheticCTDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct SyntheticCTReport: Equatable, Sendable {
    public let sourceVolumeIdentity: String
    public let method: SyntheticCTMethod
    public let dimensions: SyntheticCTDimensions
    public let bodyVoxelCount: Int
    public let minHU: Float
    public let maxHU: Float
    public let meanHU: Float
    public let warning: String?

    public init(sourceVolumeIdentity: String,
                method: SyntheticCTMethod,
                dimensions: SyntheticCTDimensions,
                bodyVoxelCount: Int,
                minHU: Float,
                maxHU: Float,
                meanHU: Float,
                warning: String?) {
        self.sourceVolumeIdentity = sourceVolumeIdentity
        self.method = method
        self.dimensions = dimensions
        self.bodyVoxelCount = bodyVoxelCount
        self.minHU = minHU
        self.maxHU = maxHU
        self.meanHU = meanHU
        self.warning = warning
    }
}

public struct SyntheticCTResult: Sendable {
    public let volume: ImageVolume
    public let report: SyntheticCTReport

    public init(volume: ImageVolume, report: SyntheticCTReport) {
        self.volume = volume
        self.report = report
    }
}

public protocol SyntheticCTModelRunner: Sendable {
    func generateSyntheticCT(from petVolume: ImageVolume,
                             suvSettings: SUVCalculationSettings,
                             options: SyntheticCTOptions) async throws -> SyntheticCTResult
}

public struct HeuristicSyntheticCTRunner: SyntheticCTModelRunner {
    public init() {}

    public func generateSyntheticCT(from petVolume: ImageVolume,
                                    suvSettings: SUVCalculationSettings = SUVCalculationSettings(),
                                    options: SyntheticCTOptions = .researchDefault) async throws -> SyntheticCTResult {
        try SyntheticCTGenerator.generate(
            from: petVolume,
            suvSettings: suvSettings,
            options: options
        )
    }
}

public enum SyntheticCTGenerator {
    public static func generate(from petVolume: ImageVolume,
                                suvSettings: SUVCalculationSettings = SUVCalculationSettings(),
                                options: SyntheticCTOptions = .researchDefault) throws -> SyntheticCTResult {
        guard Modality.normalize(petVolume.modality) == .PT else {
            throw SyntheticCTError.unsupportedModality("Synthetic CT generation expects PET/PT input, got \(petVolume.modality).")
        }
        guard !petVolume.pixels.isEmpty else {
            throw SyntheticCTError.emptyVolume
        }
        guard options.method == .researchHeuristicPETToCT else {
            throw SyntheticCTError.invalidOptions("\(options.method.displayName) requires a configured model runner.")
        }

        let suvPixels = petVolume.pixels.map {
            suvSettings.suv(forStoredValue: Double($0), volume: petVolume)
        }
        let bodyMask = suvPixels.map { $0 >= options.bodySUVThreshold }
        let bodyVoxelCount = bodyMask.filter { $0 }.count
        let normalized = normalizeUptake(
            suvPixels,
            lower: options.bodySUVThreshold,
            upper: options.intenseUptakeSUV
        )

        var huPixels = [Float](repeating: options.airHU, count: petVolume.pixels.count)
        for index in huPixels.indices where bodyMask[index] {
            let uptakeWeight = sqrt(Float(normalized[index]))
            let hu = options.softTissueHU
                + (options.highUptakeHU - options.softTissueHU) * uptakeWeight
            huPixels[index] = clamp(hu, options.minimumHU, options.maximumHU)
        }

        if options.smoothingRadiusVoxels > 0, bodyVoxelCount > 0 {
            huPixels = smoothWithinMask(
                huPixels,
                mask: bodyMask,
                width: petVolume.width,
                height: petVolume.height,
                depth: petVolume.depth,
                radius: options.smoothingRadiusVoxels,
                outsideValue: options.airHU
            )
        }

        let stats = pixelStats(huPixels)
        let warning = "Research heuristic only: PET alone does not reliably infer bone, lung, metal, or diagnostic attenuation coefficients. Use a trained synthetic CT model before clinical or attenuation-correction use."
        let syntheticVolume = ImageVolume(
            pixels: huPixels,
            depth: petVolume.depth,
            height: petVolume.height,
            width: petVolume.width,
            spacing: petVolume.spacing,
            origin: petVolume.origin,
            direction: petVolume.direction,
            modality: "CT",
            studyUID: petVolume.studyUID,
            patientID: petVolume.patientID,
            patientName: petVolume.patientName,
            seriesDescription: options.seriesDescription,
            studyDescription: petVolume.studyDescription,
            sourceFiles: []
        )
        let report = SyntheticCTReport(
            sourceVolumeIdentity: petVolume.sessionIdentity,
            method: options.method,
            dimensions: SyntheticCTDimensions(
                width: petVolume.width,
                height: petVolume.height,
                depth: petVolume.depth
            ),
            bodyVoxelCount: bodyVoxelCount,
            minHU: stats.min,
            maxHU: stats.max,
            meanHU: stats.mean,
            warning: warning
        )

        return SyntheticCTResult(volume: syntheticVolume, report: report)
    }

    private static func normalizeUptake(_ values: [Double],
                                        lower: Double,
                                        upper: Double) -> [Double] {
        let denominator = max(upper - lower, Double.leastNonzeroMagnitude)
        return values.map { value in
            min(1, max(0, (value - lower) / denominator))
        }
    }

    private static func smoothWithinMask(_ pixels: [Float],
                                         mask: [Bool],
                                         width: Int,
                                         height: Int,
                                         depth: Int,
                                         radius: Int,
                                         outsideValue: Float) -> [Float] {
        var output = pixels
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let index = voxelIndex(z: z, y: y, x: x, width: width, height: height)
                    guard mask[index] else {
                        output[index] = outsideValue
                        continue
                    }

                    var sum: Float = 0
                    var count: Float = 0
                    for dz in -radius...radius {
                        let nz = z + dz
                        guard nz >= 0, nz < depth else { continue }
                        for dy in -radius...radius {
                            let ny = y + dy
                            guard ny >= 0, ny < height else { continue }
                            for dx in -radius...radius {
                                let nx = x + dx
                                guard nx >= 0, nx < width else { continue }
                                let neighbor = voxelIndex(z: nz, y: ny, x: nx, width: width, height: height)
                                guard mask[neighbor] else { continue }
                                sum += pixels[neighbor]
                                count += 1
                            }
                        }
                    }
                    output[index] = count > 0 ? sum / count : pixels[index]
                }
            }
        }
        return output
    }

    private static func voxelIndex(z: Int, y: Int, x: Int, width: Int, height: Int) -> Int {
        z * height * width + y * width + x
    }

    private static func pixelStats(_ pixels: [Float]) -> (min: Float, max: Float, mean: Float) {
        guard var minValue = pixels.first else { return (0, 0, 0) }
        var maxValue = minValue
        var sum: Float = 0
        for value in pixels {
            if value < minValue { minValue = value }
            if value > maxValue { maxValue = value }
            sum += value
        }
        return (minValue, maxValue, sum / Float(pixels.count))
    }

    private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(upper, max(lower, value))
    }
}
