import Foundation

/// Report serialisers for a batch of per-lesion classification results.
/// Produces both JSON (full fidelity — every prediction, every feature,
/// rationale text) and CSV (flat, one lesion per row, for Excel / R).
public enum ClassificationReport {

    // MARK: - JSON

    public static func jsonData(for results: [ClassificationViewModel.LesionResult]) throws -> Data {
        let payload = ReportPayload(
            generatedAt: Date(),
            lesions: results.map { LesionPayload(from: $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    // MARK: - CSV

    /// Flat CSV with one lesion per row. Top-N probabilities are condensed
    /// into a single `label:prob;label:prob` cell so the shape stays
    /// constant regardless of class count.
    public static func csvData(for results: [ClassificationViewModel.LesionResult]) -> Data {
        var lines: [String] = []
        lines.append([
            "lesion_id",
            "class_name",
            "voxel_count",
            "volume_ml",
            "suv_max",
            "suv_mean",
            "tlg",
            "classifier_id",
            "top_label",
            "top_probability",
            "all_predictions",
            "rationale"
        ].joined(separator: ","))

        for row in results {
            let preds = row.result.predictions
                .map { "\(escape($0.label)):\(String(format: "%.4f", $0.probability))" }
                .joined(separator: ";")

            let cells: [String] = [
                "\(row.id)",
                escape(row.lesion.className),
                "\(row.lesion.voxelCount)",
                String(format: "%.3f", row.lesion.volumeML),
                String(format: "%.3f", row.lesion.suvMax),
                String(format: "%.3f", row.lesion.suvMean),
                String(format: "%.3f", row.lesion.tlg),
                escape(row.result.classifierID),
                escape(row.result.topLabel ?? ""),
                String(format: "%.4f", row.result.topProbability),
                escape(preds),
                escape(row.result.rationale ?? "")
            ]
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: - Payload structs

    private struct ReportPayload: Codable {
        let generatedAt: Date
        let lesions: [LesionPayload]
    }

    private struct LesionPayload: Codable {
        let id: Int
        let className: String
        let voxelCount: Int
        let volumeMM3: Double
        let volumeML: Double
        let suvMax: Double
        let suvMean: Double
        let suvPeak: Double?
        let tlg: Double
        let boundsMinZ: Int
        let boundsMaxZ: Int
        let boundsMinY: Int
        let boundsMaxY: Int
        let boundsMinX: Int
        let boundsMaxX: Int
        let classifierID: String
        let topLabel: String
        let topProbability: Double
        let predictions: [Prediction]
        let features: [String: Double]
        let rationale: String?
        let durationSeconds: Double

        init(from row: ClassificationViewModel.LesionResult) {
            let lesion = row.lesion
            let result = row.result
            self.id = row.id
            self.className = lesion.className
            self.voxelCount = lesion.voxelCount
            self.volumeMM3 = lesion.volumeMM3
            self.volumeML = lesion.volumeML
            self.suvMax = lesion.suvMax
            self.suvMean = lesion.suvMean
            self.suvPeak = lesion.suvPeak
            self.tlg = lesion.tlg
            self.boundsMinZ = lesion.bounds.minZ
            self.boundsMaxZ = lesion.bounds.maxZ
            self.boundsMinY = lesion.bounds.minY
            self.boundsMaxY = lesion.bounds.maxY
            self.boundsMinX = lesion.bounds.minX
            self.boundsMaxX = lesion.bounds.maxX
            self.classifierID = result.classifierID
            self.topLabel = result.topLabel ?? ""
            self.topProbability = result.topProbability
            self.predictions = result.predictions.map {
                Prediction(label: $0.label, probability: $0.probability)
            }
            self.features = result.features
            self.rationale = result.rationale
            self.durationSeconds = result.durationSeconds
        }
    }

    private struct Prediction: Codable {
        let label: String
        let probability: Double
    }

    // MARK: - CSV escaping

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
