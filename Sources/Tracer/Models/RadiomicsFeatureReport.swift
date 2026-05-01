import Foundation

public struct RadiomicsFeatureReport: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let generatedAt: Date
    public let source: VolumeMeasurementSource
    public let sourceVolumeIdentity: String
    public let sourceDescription: String
    public let classID: UInt16
    public let className: String
    public let bounds: MONAITransforms.VoxelBounds
    public let featureCount: Int
    public let features: [String: Double]

    public init(id: UUID = UUID(),
                generatedAt: Date = Date(),
                source: VolumeMeasurementSource,
                sourceVolumeIdentity: String,
                sourceDescription: String,
                classID: UInt16,
                className: String,
                bounds: MONAITransforms.VoxelBounds,
                features: [String: Double]) {
        self.id = id
        self.generatedAt = generatedAt
        self.source = source
        self.sourceVolumeIdentity = sourceVolumeIdentity
        self.sourceDescription = sourceDescription
        self.classID = classID
        self.className = className
        self.bounds = bounds
        self.featureCount = features.count
        self.features = features
    }

    public var compactSummary: String {
        "\(source.rawValue) \(className): \(featureCount) features"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public var csvData: Data {
        let header = "source,series,class_id,class_name,feature,value"
        let lines = features
            .sorted { $0.key < $1.key }
            .map { key, value in
                [
                    csvEscape(source.rawValue),
                    csvEscape(sourceDescription),
                    "\(classID)",
                    csvEscape(className),
                    csvEscape(key),
                    String(format: "%.12g", value)
                ].joined(separator: ",")
            }
        return ([header] + lines).joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    public var topPreviewFeatures: [(String, Double)] {
        let preferred = [
            "original_firstorder_Mean",
            "original_firstorder_Maximum",
            "original_firstorder_StandardDeviation",
            "original_shape_VoxelVolume",
            "original_shape_SurfaceArea",
            "original_shape_Sphericity",
            "original_shape_Maximum3DDiameter",
            "original_glcm_Contrast",
            "original_glcm_JointEnergy",
            "original_glcm_Homogeneity"
        ]
        let selected = preferred.compactMap { name -> (String, Double)? in
            guard let value = features[name] else { return nil }
            return (name, value)
        }
        if !selected.isEmpty { return selected }
        return Array(features.sorted { $0.key < $1.key }.prefix(8))
    }
}

private func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}
