import Foundation

public struct LabelDataExportReport: Codable, Equatable, Sendable {
    public struct ClassSummary: Codable, Equatable, Sendable {
        public let labelID: UInt16
        public let name: String
        public let category: String
        public let color: StudySessionRGB
        public let opacity: Double
        public let visible: Bool
        public let voxelCount: Int
        public let volumeML: Double

        public init(labelClass: LabelClass, voxelCount: Int, volumeML: Double) {
            let (r, g, b) = labelClass.color.rgbBytes()
            self.labelID = labelClass.labelID
            self.name = labelClass.name
            self.category = labelClass.category.rawValue
            self.color = StudySessionRGB(r: r, g: g, b: b)
            self.opacity = labelClass.opacity
            self.visible = labelClass.visible
            self.voxelCount = voxelCount
            self.volumeML = volumeML
        }
    }

    public let generatedAt: Date
    public let mapName: String
    public let parentSeriesUID: String
    public let sourceVolumeIdentity: String
    public let sourceDescription: String
    public let width: Int
    public let height: Int
    public let depth: Int
    public let spacingXMM: Double
    public let spacingYMM: Double
    public let spacingZMM: Double
    public let classes: [ClassSummary]
    public let voxelsRLE: [StudySessionRLEEntry]
    public let annotations: [Annotation]
    public let activeVolumeReport: VolumeMeasurementReport?
    public let activeRadiomicsReport: RadiomicsFeatureReport?

    public init(labelMap: LabelMap,
                parentVolume: ImageVolume,
                activeVolumeReport: VolumeMeasurementReport?,
                activeRadiomicsReport: RadiomicsFeatureReport?,
                annotations: [Annotation] = [],
                generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        self.mapName = labelMap.name
        self.parentSeriesUID = labelMap.parentSeriesUID
        self.sourceVolumeIdentity = parentVolume.sessionIdentity
        self.sourceDescription = parentVolume.seriesDescription.isEmpty
            ? Modality.normalize(parentVolume.modality).displayName
            : parentVolume.seriesDescription
        self.width = labelMap.width
        self.height = labelMap.height
        self.depth = labelMap.depth
        self.spacingXMM = parentVolume.spacing.x
        self.spacingYMM = parentVolume.spacing.y
        self.spacingZMM = parentVolume.spacing.z
        let counts = labelMap.voxels.reduce(into: [UInt16: Int]()) { partial, value in
            guard value != 0 else { return }
            partial[value, default: 0] += 1
        }
        let voxelVolumeML = parentVolume.spacing.x * parentVolume.spacing.y * parentVolume.spacing.z / 1000.0
        self.classes = labelMap.classes
            .sorted { $0.labelID < $1.labelID }
            .map { cls in
                let count = counts[cls.labelID] ?? 0
                return ClassSummary(
                    labelClass: cls,
                    voxelCount: count,
                    volumeML: Double(count) * voxelVolumeML
                )
            }
        self.voxelsRLE = StudySessionRLEEntry.encode(labelMap.voxels)
        self.annotations = annotations
        self.activeVolumeReport = activeVolumeReport
        self.activeRadiomicsReport = activeRadiomicsReport
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case mapName
        case parentSeriesUID
        case sourceVolumeIdentity
        case sourceDescription
        case width
        case height
        case depth
        case spacingXMM
        case spacingYMM
        case spacingZMM
        case classes
        case voxelsRLE
        case annotations
        case activeVolumeReport
        case activeRadiomicsReport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        mapName = try container.decode(String.self, forKey: .mapName)
        parentSeriesUID = try container.decode(String.self, forKey: .parentSeriesUID)
        sourceVolumeIdentity = try container.decode(String.self, forKey: .sourceVolumeIdentity)
        sourceDescription = try container.decode(String.self, forKey: .sourceDescription)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        depth = try container.decode(Int.self, forKey: .depth)
        spacingXMM = try container.decode(Double.self, forKey: .spacingXMM)
        spacingYMM = try container.decode(Double.self, forKey: .spacingYMM)
        spacingZMM = try container.decode(Double.self, forKey: .spacingZMM)
        classes = try container.decode([ClassSummary].self, forKey: .classes)
        voxelsRLE = try container.decode([StudySessionRLEEntry].self, forKey: .voxelsRLE)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
        activeVolumeReport = try container.decodeIfPresent(VolumeMeasurementReport.self, forKey: .activeVolumeReport)
        activeRadiomicsReport = try container.decodeIfPresent(RadiomicsFeatureReport.self, forKey: .activeRadiomicsReport)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public var csvData: Data {
        tabularData(separator: ",")
    }

    public var tsvData: Data {
        tabularData(separator: "\t")
    }

    public var xmlData: Data {
        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<labelData generatedAt=\"\(xmlEscape(iso8601String(generatedAt)))\" mapName=\"\(xmlEscape(mapName))\" parentSeriesUID=\"\(xmlEscape(parentSeriesUID))\">",
            "  <source identity=\"\(xmlEscape(sourceVolumeIdentity))\" description=\"\(xmlEscape(sourceDescription))\"/>",
            "  <dimensions width=\"\(width)\" height=\"\(height)\" depth=\"\(depth)\"/>",
            "  <spacing xMM=\"\(formatNumber(spacingXMM))\" yMM=\"\(formatNumber(spacingYMM))\" zMM=\"\(formatNumber(spacingZMM))\"/>",
            "  <classes>"
        ]
        for cls in classes {
            lines.append("    <class id=\"\(cls.labelID)\" name=\"\(xmlEscape(cls.name))\" category=\"\(xmlEscape(cls.category))\" visible=\"\(cls.visible)\" opacity=\"\(formatNumber(cls.opacity))\" voxelCount=\"\(cls.voxelCount)\" volumeML=\"\(formatNumber(cls.volumeML))\" colorR=\"\(cls.color.r)\" colorG=\"\(cls.color.g)\" colorB=\"\(cls.color.b)\"/>")
        }
        lines.append("  </classes>")
        lines.append("  <voxelsRLE>")
        for run in voxelsRLE {
            lines.append("    <run value=\"\(run.value)\" count=\"\(run.count)\"/>")
        }
        lines.append("  </voxelsRLE>")
        lines.append("  <annotations>")
        for annotation in annotations {
            lines.append("    <annotation id=\"\(annotation.id.uuidString)\" type=\"\(xmlEscape(annotation.type.rawValue))\" axis=\"\(annotation.axis)\" sliceIndex=\"\(annotation.sliceIndex)\" label=\"\(xmlEscape(annotation.label))\" unit=\"\(xmlEscape(annotation.unit))\" value=\"\(annotation.value.map(formatNumber) ?? "")\">")
            for point in annotation.points {
                lines.append("      <point x=\"\(formatNumber(Double(point.x)))\" y=\"\(formatNumber(Double(point.y)))\"/>")
            }
            lines.append("    </annotation>")
        }
        lines.append("  </annotations>")
        if let report = activeVolumeReport {
            lines.append("  <activeVolumeReport id=\"\(report.id.uuidString)\" source=\"\(xmlEscape(report.source.rawValue))\" method=\"\(xmlEscape(report.method.rawValue))\" className=\"\(xmlEscape(report.className))\" voxelCount=\"\(report.voxelCount)\" volumeML=\"\(formatNumber(report.volumeML))\" mean=\"\(formatNumber(report.mean))\" min=\"\(formatNumber(report.min))\" max=\"\(formatNumber(report.max))\" std=\"\(formatNumber(report.std))\" suvMax=\"\(report.suvMax.map(formatNumber) ?? "")\" suvMean=\"\(report.suvMean.map(formatNumber) ?? "")\" suvPeak=\"\(report.suvPeak.map(formatNumber) ?? "")\" tlg=\"\(report.tlg.map(formatNumber) ?? "")\" threshold=\"\(xmlEscape(report.thresholdSummary))\"/>")
        }
        if let report = activeRadiomicsReport {
            lines.append("  <activeRadiomicsReport id=\"\(report.id.uuidString)\" source=\"\(xmlEscape(report.source.rawValue))\" sourceDescription=\"\(xmlEscape(report.sourceDescription))\" classID=\"\(report.classID)\" className=\"\(xmlEscape(report.className))\" featureCount=\"\(report.featureCount)\">")
            for feature in report.features.sorted(by: { $0.key < $1.key }) {
                lines.append("    <feature name=\"\(xmlEscape(feature.key))\" value=\"\(formatNumber(feature.value))\"/>")
            }
            lines.append("  </activeRadiomicsReport>")
        }
        lines.append("</labelData>")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private func tabularData(separator: String) -> Data {
        var lines: [String] = []
        lines.append([
            "map_name",
            "source_series",
            "label_id",
            "class_name",
            "category",
            "voxel_count",
            "volume_ml",
            "active_report_source",
            "active_report_method",
            "suv_max",
            "suv_mean",
            "suv_peak",
            "tlg",
            "radiomics_feature_count",
            "annotation_count"
        ].joined(separator: separator))

        for cls in classes {
            let matchesActiveReport = activeVolumeReport?.className == cls.name
            let cells: [String] = [
                labelDelimited(mapName, separator: separator),
                labelDelimited(sourceDescription, separator: separator),
                "\(cls.labelID)",
                labelDelimited(cls.name, separator: separator),
                labelDelimited(cls.category, separator: separator),
                "\(cls.voxelCount)",
                String(format: "%.6f", cls.volumeML),
                matchesActiveReport ? labelDelimited(activeVolumeReport?.source.rawValue ?? "", separator: separator) : "",
                matchesActiveReport ? labelDelimited(activeVolumeReport?.method.rawValue ?? "", separator: separator) : "",
                matchesActiveReport ? activeVolumeReport?.suvMax.map { String(format: "%.6f", $0) } ?? "" : "",
                matchesActiveReport ? activeVolumeReport?.suvMean.map { String(format: "%.6f", $0) } ?? "" : "",
                matchesActiveReport ? activeVolumeReport?.suvPeak.map { String(format: "%.6f", $0) } ?? "" : "",
                matchesActiveReport ? activeVolumeReport?.tlg.map { String(format: "%.6f", $0) } ?? "" : "",
                activeRadiomicsReport?.classID == cls.labelID ? "\(activeRadiomicsReport?.featureCount ?? 0)" : "",
                "\(annotations.count)"
            ]
            lines.append(cells.joined(separator: separator))
        }

        if !annotations.isEmpty {
            lines.append("")
            lines.append([
                "annotation_id",
                "annotation_type",
                "axis",
                "slice_index",
                "label",
                "value",
                "unit",
                "points"
            ].joined(separator: separator))

            for annotation in annotations {
                let points = annotation.points
                    .map { point in
                        String(format: "%.3f:%.3f", Double(point.x), Double(point.y))
                    }
                    .joined(separator: ";")
                let cells: [String] = [
                    annotation.id.uuidString,
                    labelDelimited(annotation.type.rawValue, separator: separator),
                    "\(annotation.axis)",
                    "\(annotation.sliceIndex)",
                    labelDelimited(annotation.label, separator: separator),
                    annotation.value.map { String(format: "%.6f", $0) } ?? "",
                    labelDelimited(annotation.unit, separator: separator),
                    labelDelimited(points, separator: separator)
                ]
                lines.append(cells.joined(separator: separator))
            }
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}

private func labelDelimited(_ value: String, separator: String) -> String {
    if value.contains(separator) || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func formatNumber(_ value: Double) -> String {
    String(format: "%.12g", value)
}

private func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
