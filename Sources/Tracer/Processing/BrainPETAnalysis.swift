import Foundation

public enum BrainPETTracer: String, CaseIterable, Identifiable, Codable, Sendable {
    case fdg
    case amyloidPIB
    case amyloidFlorbetapir
    case amyloidFlorbetaben
    case amyloidFlutemetamol
    case tauFlortaucipir
    case tauMK6240
    case tauPI2620
    case tauRO948
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fdg: return "FDG"
        case .amyloidPIB: return "PiB amyloid"
        case .amyloidFlorbetapir: return "Florbetapir amyloid"
        case .amyloidFlorbetaben: return "Florbetaben amyloid"
        case .amyloidFlutemetamol: return "Flutemetamol amyloid"
        case .tauFlortaucipir: return "Flortaucipir tau"
        case .tauMK6240: return "MK-6240 tau"
        case .tauPI2620: return "PI-2620 tau"
        case .tauRO948: return "RO948 tau"
        case .unknown: return "Unknown brain PET"
        }
    }

    public var family: BrainPETAnalysisFamily {
        switch self {
        case .fdg:
            return .fdg
        case .amyloidPIB, .amyloidFlorbetapir, .amyloidFlorbetaben, .amyloidFlutemetamol:
            return .amyloid
        case .tauFlortaucipir, .tauMK6240, .tauPI2620, .tauRO948:
            return .tau
        case .unknown:
            return .generic
        }
    }

    public var defaultCentiloidCalibration: BrainPETCentiloidCalibration? {
        switch self {
        case .amyloidPIB:
            return .standardPiB
        case .amyloidFlorbetapir:
            return .adniFlorbetapirWholeCerebellum
        case .amyloidFlorbetaben:
            return .adniFlorbetabenWholeCerebellum
        case .amyloidFlutemetamol:
            return .exampleFlutemetamolWholeCerebellum
        default:
            return nil
        }
    }
}

public enum BrainPETAnalysisFamily: String, Codable, Sendable {
    case fdg
    case amyloid
    case tau
    case generic
}

public struct BrainPETCentiloidCalibration: Codable, Equatable, Sendable {
    public let name: String
    public let slope: Double
    public let intercept: Double
    public let referenceRegion: String
    public let source: String

    public init(name: String,
                slope: Double,
                intercept: Double,
                referenceRegion: String,
                source: String) {
        self.name = name
        self.slope = slope
        self.intercept = intercept
        self.referenceRegion = referenceRegion
        self.source = source
    }

    public func centiloid(for suvr: Double) -> Double {
        slope * suvr + intercept
    }

    public static let standardPiB = BrainPETCentiloidCalibration(
        name: "Standard PiB 50-70 min",
        slope: 100.0 / 1.067,
        intercept: -100.0 * 1.009 / 1.067,
        referenceRegion: "Whole cerebellum",
        source: "GAAIN/Klunk standard Centiloid method"
    )

    public static let adniFlorbetapirWholeCerebellum = BrainPETCentiloidCalibration(
        name: "ADNI florbetapir WC",
        slope: 188.22,
        intercept: -189.16,
        referenceRegion: "Whole cerebellum",
        source: "ADNI native-space UC Berkeley pipeline"
    )

    public static let adniFlorbetabenWholeCerebellum = BrainPETCentiloidCalibration(
        name: "ADNI florbetaben WC",
        slope: 157.15,
        intercept: -151.87,
        referenceRegion: "Whole cerebellum",
        source: "ADNI native-space UC Berkeley pipeline"
    )

    public static let exampleFlutemetamolWholeCerebellum = BrainPETCentiloidCalibration(
        name: "Flutemetamol WC example",
        slope: 121.42,
        intercept: -121.16,
        referenceRegion: "Whole cerebellum",
        source: "Published/FDA-review example equation; validate locally before clinical use"
    )
}

public struct BrainPETNormalDatabase: Codable, Equatable, Sendable {
    public struct RegionEntry: Codable, Equatable, Sendable {
        public let regionName: String
        public let labelID: UInt16?
        public let meanSUVR: Double
        public let sdSUVR: Double
        public let sampleSize: Int
        public let ageMin: Double?
        public let ageMax: Double?

        public init(regionName: String,
                    labelID: UInt16? = nil,
                    meanSUVR: Double,
                    sdSUVR: Double,
                    sampleSize: Int,
                    ageMin: Double? = nil,
                    ageMax: Double? = nil) {
            self.regionName = regionName
            self.labelID = labelID
            self.meanSUVR = meanSUVR
            self.sdSUVR = sdSUVR
            self.sampleSize = sampleSize
            self.ageMin = ageMin
            self.ageMax = ageMax
        }
    }

    public let id: String
    public let name: String
    public let tracer: BrainPETTracer
    public let referenceRegion: String
    public let sourceDescription: String
    public let entries: [RegionEntry]

    public init(id: String,
                name: String,
                tracer: BrainPETTracer,
                referenceRegion: String,
                sourceDescription: String,
                entries: [RegionEntry]) {
        self.id = id
        self.name = name
        self.tracer = tracer
        self.referenceRegion = referenceRegion
        self.sourceDescription = sourceDescription
        self.entries = entries
    }

    public func entry(labelID: UInt16, regionName: String) -> RegionEntry? {
        if let byID = entries.first(where: { $0.labelID == labelID }) {
            return byID
        }
        let normalized = BrainPETAnalysis.normalizedRegionName(regionName)
        return entries.first {
            BrainPETAnalysis.normalizedRegionName($0.regionName) == normalized
        }
    }
}

public struct BrainPETNormalDatasetDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tracerFamilies: [BrainPETAnalysisFamily]
    public let access: String
    public let suggestedUse: String
    public let url: String

    public init(id: String,
                name: String,
                tracerFamilies: [BrainPETAnalysisFamily],
                access: String,
                suggestedUse: String,
                url: String) {
        self.id = id
        self.name = name
        self.tracerFamilies = tracerFamilies
        self.access = access
        self.suggestedUse = suggestedUse
        self.url = url
    }
}

public enum BrainPETNormalDatabaseCatalog {
    public static let recommendedSources: [BrainPETNormalDatasetDescriptor] = [
        BrainPETNormalDatasetDescriptor(
            id: "gaain-centiloid",
            name: "GAAIN Centiloid Project",
            tracerFamilies: [.amyloid],
            access: "Open project downloads",
            suggestedUse: "Centiloid validation data, standard VOIs, amyloid calibrations",
            url: "https://www.gaain.org/centiloid-project"
        ),
        BrainPETNormalDatasetDescriptor(
            id: "adni-pet-core",
            name: "ADNI PET Core / UC Berkeley PET summaries",
            tracerFamilies: [.fdg, .amyloid, .tau],
            access: "Registered ADNI data access",
            suggestedUse: "Large research normal/MCI/AD cohorts, regional SUVR, CL, tau summaries, QC tables",
            url: "https://adni.loni.usc.edu/data-samples/adni-data/neuroimaging/pet/"
        ),
        BrainPETNormalDatasetDescriptor(
            id: "oasis3-pet",
            name: "OASIS-3 PET/PUP outputs",
            tracerFamilies: [.fdg, .amyloid, .tau],
            access: "OASIS data use agreement",
            suggestedUse: "Aging and Alzheimer cohort with PiB, AV45, FDG, PUP regional outputs and Centiloids",
            url: "https://www.oasis-brains.org/"
        ),
        BrainPETNormalDatasetDescriptor(
            id: "neurostat-3d-ssp",
            name: "NEUROSTAT / 3D-SSP",
            tracerFamilies: [.fdg],
            access: "Free keycode request; license-controlled software/data",
            suggestedUse: "FDG brain z-score surface projection workflow and test normal databases",
            url: "https://neurostat-3d-ssp.github.io/neurostat/"
        )
    ]
}

public enum BrainPETNormalDatabaseIO {
    public enum LoadError: Error, LocalizedError {
        case missingHeader(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .missingHeader(let header):
                return "Normal database CSV is missing required column: \(header)."
            case .empty:
                return "Normal database CSV did not contain any usable regions."
            }
        }
    }

    public static func loadCSV(from url: URL,
                               tracer: BrainPETTracer,
                               name: String? = nil,
                               referenceRegion: String = "Configured reference") throws -> BrainPETNormalDatabase {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseCSV(
            text,
            id: url.deletingPathExtension().lastPathComponent,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            tracer: tracer,
            referenceRegion: referenceRegion,
            sourceDescription: url.path
        )
    }

    public static func parseCSV(_ text: String,
                                id: String,
                                name: String,
                                tracer: BrainPETTracer,
                                referenceRegion: String,
                                sourceDescription: String) throws -> BrainPETNormalDatabase {
        var rows = parseRows(text)
        guard !rows.isEmpty else { throw LoadError.empty }
        let headers = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func index(_ candidates: [String], required: Bool = true) throws -> Int? {
            if let idx = headers.firstIndex(where: { header in
                candidates.contains(header)
            }) {
                return idx
            }
            if required {
                throw LoadError.missingHeader(candidates.first ?? "")
            }
            return nil
        }

        let regionIndex = try index(["region", "regionname", "name"])
        let meanIndex = try index(["meansuvr", "mean_suvr", "mean", "normalmean"])
        let sdIndex = try index(["sdsuvr", "sd_suvr", "sd", "std", "normalstd"])
        let labelIndex = try index(["labelid", "label_id", "id"], required: false)
        let nIndex = try index(["n", "samplesize", "sample_size"], required: false)
        let ageMinIndex = try index(["agemin", "age_min"], required: false)
        let ageMaxIndex = try index(["agemax", "age_max"], required: false)

        let entries = rows.compactMap { row -> BrainPETNormalDatabase.RegionEntry? in
            guard let regionIndex,
                  let meanIndex,
                  let sdIndex,
                  row.indices.contains(regionIndex),
                  row.indices.contains(meanIndex),
                  row.indices.contains(sdIndex) else { return nil }
            let region = row[regionIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !region.isEmpty,
                  let mean = Double(row[meanIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let sd = Double(row[sdIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  sd > 0 else { return nil }
            let labelID = labelIndex.flatMap { idx -> UInt16? in
                guard row.indices.contains(idx) else { return nil }
                return UInt16(row[idx].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let n = nIndex.flatMap { idx -> Int? in
                guard row.indices.contains(idx) else { return nil }
                return Int(row[idx].trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 0
            let ageMin = ageMinIndex.flatMap { idx -> Double? in
                guard row.indices.contains(idx) else { return nil }
                return Double(row[idx].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let ageMax = ageMaxIndex.flatMap { idx -> Double? in
                guard row.indices.contains(idx) else { return nil }
                return Double(row[idx].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return BrainPETNormalDatabase.RegionEntry(
                regionName: region,
                labelID: labelID,
                meanSUVR: mean,
                sdSUVR: sd,
                sampleSize: n,
                ageMin: ageMin,
                ageMax: ageMax
            )
        }

        guard !entries.isEmpty else { throw LoadError.empty }
        return BrainPETNormalDatabase(
            id: id,
            name: name,
            tracer: tracer,
            referenceRegion: referenceRegion,
            sourceDescription: sourceDescription,
            entries: entries
        )
    }

    private static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            switch char {
            case "\"":
                if inQuotes {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                row.append(field)
                                field.removeAll(keepingCapacity: true)
                            } else if next == "\n" {
                                row.append(field)
                                rows.append(row)
                                row.removeAll(keepingCapacity: true)
                                field.removeAll(keepingCapacity: true)
                            } else if next != "\r" {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                row.append(field)
                field.removeAll(keepingCapacity: true)
            case "\n" where !inQuotes:
                row.append(field)
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    rows.append(row)
                }
                row.removeAll(keepingCapacity: true)
                field.removeAll(keepingCapacity: true)
            case "\r" where !inQuotes:
                continue
            default:
                field.append(char)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            rows.append(row)
        }
        return rows
    }
}

public struct BrainPETAnalysisConfiguration: Codable, Equatable, Sendable {
    public var tracer: BrainPETTracer
    public var referenceClassIDs: [UInt16]
    public var targetClassIDs: [UInt16]
    public var tauSUVRThreshold: Double
    public var centiloidCalibration: BrainPETCentiloidCalibration?
    public var normalDatabase: BrainPETNormalDatabase?

    public init(tracer: BrainPETTracer,
                referenceClassIDs: [UInt16] = [],
                targetClassIDs: [UInt16] = [],
                tauSUVRThreshold: Double = 1.34,
                centiloidCalibration: BrainPETCentiloidCalibration? = nil,
                normalDatabase: BrainPETNormalDatabase? = nil) {
        self.tracer = tracer
        self.referenceClassIDs = referenceClassIDs
        self.targetClassIDs = targetClassIDs
        self.tauSUVRThreshold = tauSUVRThreshold
        self.centiloidCalibration = centiloidCalibration ?? tracer.defaultCentiloidCalibration
        self.normalDatabase = normalDatabase
    }
}

public enum BrainPETAnatomyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case petOnly
    case ctAssisted
    case mriAssisted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Auto anatomy"
        case .petOnly: return "PET only"
        case .ctAssisted: return "CT assisted"
        case .mriAssisted: return "MRI assisted"
        }
    }

    public var shortName: String {
        switch self {
        case .automatic: return "Auto"
        case .petOnly: return "PET"
        case .ctAssisted: return "PET+CT"
        case .mriAssisted: return "PET+MRI"
        }
    }

    public var systemImage: String {
        switch self {
        case .automatic: return "wand.and.stars"
        case .petOnly: return "brain.head.profile"
        case .ctAssisted: return "viewfinder"
        case .mriAssisted: return "brain.head.profile"
        }
    }
}

public enum BrainPETAnatomyConfidence: String, Codable, Sendable {
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

public struct BrainPETAnatomyQCMetric: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let passed: Bool

    public init(id: String,
                title: String,
                value: String,
                passed: Bool) {
        self.id = id
        self.title = title
        self.value = value
        self.passed = passed
    }
}

public struct BrainPETAnatomyDelta: Codable, Equatable, Sendable {
    public let targetSUVR: Double?
    public let centiloid: Double?

    public init(standard: BrainPETReport, anatomyAware: BrainPETReport) {
        if let standardSUVR = standard.targetSUVR,
           let awareSUVR = anatomyAware.targetSUVR {
            targetSUVR = awareSUVR - standardSUVR
        } else {
            targetSUVR = nil
        }
        if let standardCL = standard.centiloid,
           let awareCL = anatomyAware.centiloid {
            centiloid = awareCL - standardCL
        } else {
            centiloid = nil
        }
    }
}

public struct BrainPETAnatomyAwareReport: Codable, Equatable, Sendable {
    public let requestedMode: BrainPETAnatomyMode
    public let resolvedMode: BrainPETAnatomyMode
    public let confidence: BrainPETAnatomyConfidence
    public let anatomySeriesDescription: String?
    public let standardReport: BrainPETReport
    public let anatomyAwareReport: BrainPETReport
    public let delta: BrainPETAnatomyDelta
    public let qcMetrics: [BrainPETAnatomyQCMetric]
    public let warnings: [String]

    public var summary: String {
        let mode = resolvedMode.shortName
        switch (anatomyAwareReport.targetSUVR, anatomyAwareReport.centiloid) {
        case let (_, centiloid?):
            return String(format: "%@ anatomy-aware Centiloid %.1f (%@ confidence).",
                          mode,
                          centiloid,
                          confidence.displayName.lowercased())
        case let (suvr?, nil):
            return String(format: "%@ anatomy-aware target SUVR %.3f (%@ confidence).",
                          mode,
                          suvr,
                          confidence.displayName.lowercased())
        default:
            return "\(mode) anatomy-aware brain PET analysis complete (\(confidence.displayName.lowercased()) confidence)."
        }
    }
}

public struct BrainPETRegionStatistic: Identifiable, Codable, Equatable, Sendable {
    public var id: UInt16 { labelID }
    public let labelID: UInt16
    public let name: String
    public let voxelCount: Int
    public let meanActivity: Double
    public let suvr: Double
    public let normalMeanSUVR: Double?
    public let normalSDSUVR: Double?
    public let zScore: Double?

    public var abnormalityLabel: String? {
        guard let zScore else { return nil }
        if zScore <= -2 { return "Low" }
        if zScore >= 2 { return "High" }
        return nil
    }
}

public struct BrainPETTauGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let meanSUVR: Double?
    public let positive: Bool
}

public struct BrainPETTauGrade: Codable, Equatable, Sendable {
    public let threshold: Double
    public let stage: String
    public let groups: [BrainPETTauGroup]
}

public struct BrainPETReport: Codable, Equatable, Sendable {
    public let tracer: BrainPETTracer
    public let family: BrainPETAnalysisFamily
    public let referenceRegionName: String
    public let referenceMean: Double
    public let targetSUVR: Double?
    public let centiloid: Double?
    public let centiloidCalibrationName: String?
    public let tauGrade: BrainPETTauGrade?
    public let regions: [BrainPETRegionStatistic]
    public let warnings: [String]

    public var hypometabolicRegions: [BrainPETRegionStatistic] {
        guard family == .fdg else { return [] }
        return regions.filter { ($0.zScore ?? 0) <= -2 }
    }

    public var highBindingRegions: [BrainPETRegionStatistic] {
        guard family == .amyloid || family == .tau else { return [] }
        return regions.filter { ($0.zScore ?? 0) >= 2 }
    }

    public var summary: String {
        switch family {
        case .fdg:
            if hypometabolicRegions.isEmpty {
                return "FDG regional analysis complete; no z <= -2 regions with the selected normal database."
            }
            return "FDG regional analysis: \(hypometabolicRegions.count) low-uptake region(s)."
        case .amyloid:
            if let centiloid {
                return String(format: "Amyloid target SUVR %.3f, Centiloid %.1f.", targetSUVR ?? 0, centiloid)
            }
            return String(format: "Amyloid target SUVR %.3f.", targetSUVR ?? 0)
        case .tau:
            return tauGrade.map { "Tau \(String(format: "%.3f", targetSUVR ?? 0)); \($0.stage)." }
                ?? String(format: "Tau target SUVR %.3f.", targetSUVR ?? 0)
        case .generic:
            return "Brain PET regional analysis complete."
        }
    }
}

public enum BrainPETAnalysisError: Error, LocalizedError {
    case gridMismatch
    case missingAtlas
    case emptyReferenceRegion

    public var errorDescription: String? {
        switch self {
        case .gridMismatch:
            return "Brain PET analysis requires an atlas label map on the same voxel grid as the PET volume."
        case .missingAtlas:
            return "Brain PET analysis needs a brain atlas label map."
        case .emptyReferenceRegion:
            return "Reference region has no labeled voxels or zero mean activity."
        }
    }
}

public enum BrainPETAnalysis {
    public static func analyze(volume: ImageVolume,
                               atlas: LabelMap?,
                               configuration: BrainPETAnalysisConfiguration) throws -> BrainPETReport {
        guard let atlas else { throw BrainPETAnalysisError.missingAtlas }
        guard volume.width == atlas.width,
              volume.height == atlas.height,
              volume.depth == atlas.depth else {
            throw BrainPETAnalysisError.gridMismatch
        }

        let regionMeans = regionalMeans(volume: volume, atlas: atlas)
        let referenceIDs = resolvedReferenceIDs(configuration.referenceClassIDs,
                                                atlas: atlas,
                                                family: configuration.tracer.family)
        let reference = weightedMean(for: referenceIDs, means: regionMeans, atlas: atlas)
        guard reference.voxelCount > 0, reference.mean > 0 else {
            throw BrainPETAnalysisError.emptyReferenceRegion
        }

        var warnings: [String] = []
        if configuration.referenceClassIDs.isEmpty {
            warnings.append("Reference inferred from atlas names: \(reference.name).")
        }
        if configuration.normalDatabase == nil {
            warnings.append("No normal database selected; z-scores are unavailable.")
        }

        let regionStats = atlas.classes.compactMap { cls -> BrainPETRegionStatistic? in
            guard let mean = regionMeans[cls.labelID],
                  mean.voxelCount > 0 else { return nil }
            let suvr = mean.mean / reference.mean
            let normal = configuration.normalDatabase?.entry(labelID: cls.labelID, regionName: cls.name)
            let z = normal.flatMap { entry -> Double? in
                guard entry.sdSUVR > 0 else { return nil }
                return (suvr - entry.meanSUVR) / entry.sdSUVR
            }
            return BrainPETRegionStatistic(
                labelID: cls.labelID,
                name: cls.name,
                voxelCount: mean.voxelCount,
                meanActivity: mean.mean,
                suvr: suvr,
                normalMeanSUVR: normal?.meanSUVR,
                normalSDSUVR: normal?.sdSUVR,
                zScore: z
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.suvr - rhs.suvr) > 0.000001 {
                return lhs.suvr > rhs.suvr
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let targetIDs = resolvedTargetIDs(configuration.targetClassIDs,
                                          atlas: atlas,
                                          family: configuration.tracer.family)
        let target = weightedMean(for: targetIDs, means: regionMeans, atlas: atlas)
        let targetSUVR = target.voxelCount > 0 ? target.mean / reference.mean : nil
        if target.voxelCount == 0 {
            warnings.append("No target-region voxels were found for \(configuration.tracer.displayName).")
        }

        let centiloid: Double?
        let calibrationName: String?
        if configuration.tracer.family == .amyloid,
           let targetSUVR,
           let calibration = configuration.centiloidCalibration {
            centiloid = calibration.centiloid(for: targetSUVR)
            calibrationName = calibration.name
        } else {
            centiloid = nil
            calibrationName = nil
        }

        let tauGrade = configuration.tracer.family == .tau
            ? tauGrade(atlas: atlas,
                       regionStats: regionStats,
                       threshold: configuration.tauSUVRThreshold)
            : nil

        return BrainPETReport(
            tracer: configuration.tracer,
            family: configuration.tracer.family,
            referenceRegionName: reference.name,
            referenceMean: reference.mean,
            targetSUVR: targetSUVR,
            centiloid: centiloid,
            centiloidCalibrationName: calibrationName,
            tauGrade: tauGrade,
            regions: regionStats,
            warnings: warnings
        )
    }

    public static func analyzeAnatomyAware(volume: ImageVolume,
                                           atlas: LabelMap?,
                                           anatomyVolume: ImageVolume?,
                                           requestedMode: BrainPETAnatomyMode,
                                           configuration: BrainPETAnalysisConfiguration) throws -> BrainPETAnatomyAwareReport {
        guard let atlas else { throw BrainPETAnalysisError.missingAtlas }
        let standard = try analyze(volume: volume, atlas: atlas, configuration: configuration)
        let resolvedMode = resolveAnatomyMode(requestedMode, anatomyVolume: anatomyVolume)
        let profile = AnatomyProfile(atlas: atlas)

        var awareConfiguration = configuration
        if !profile.corticalGrayIDs.isEmpty {
            let targetIDs = configuration.targetClassIDs.isEmpty
                ? profile.corticalGrayIDs
                : configuration.targetClassIDs.filter { profile.corticalGrayIDs.contains($0) }
            if !targetIDs.isEmpty {
                awareConfiguration.targetClassIDs = targetIDs
            }
        }
        if !profile.cerebellarGrayIDs.isEmpty,
           configuration.referenceClassIDs.isEmpty {
            awareConfiguration.referenceClassIDs = profile.cerebellarGrayIDs
        }

        let anatomyAware = try analyze(volume: volume, atlas: atlas, configuration: awareConfiguration)
        let qc = anatomyQualityMetrics(
            atlas: atlas,
            anatomyVolume: anatomyVolume,
            requestedMode: requestedMode,
            resolvedMode: resolvedMode,
            profile: profile
        )
        let warnings = anatomyWarnings(
            requestedMode: requestedMode,
            resolvedMode: resolvedMode,
            anatomyVolume: anatomyVolume,
            profile: profile,
            standard: standard,
            anatomyAware: anatomyAware
        )
        let confidence = anatomyConfidence(resolvedMode: resolvedMode,
                                           profile: profile)

        return BrainPETAnatomyAwareReport(
            requestedMode: requestedMode,
            resolvedMode: resolvedMode,
            confidence: confidence,
            anatomySeriesDescription: anatomyVolume?.seriesDescription,
            standardReport: standard,
            anatomyAwareReport: anatomyAware,
            delta: BrainPETAnatomyDelta(standard: standard, anatomyAware: anatomyAware),
            qcMetrics: qc,
            warnings: warnings
        )
    }

    public static func normalizedRegionName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "left", with: "")
            .replacingOccurrences(of: "right", with: "")
            .replacingOccurrences(of: "ctx-", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct AnatomyProfile {
        let corticalGrayIDs: [UInt16]
        let whiteMatterIDs: [UInt16]
        let csfIDs: [UInt16]
        let cerebellarGrayIDs: [UInt16]

        init(atlas: LabelMap) {
            var corticalGray: [UInt16] = []
            var whiteMatter: [UInt16] = []
            var csf: [UInt16] = []
            var cerebellarGray: [UInt16] = []
            for cls in atlas.classes {
                let name = BrainPETAnalysis.normalizedRegionName(cls.name)
                let isWhite = BrainPETAnalysis.containsAny(name, ["white matter", "whitematter", "wm"])
                let isCSF = BrainPETAnalysis.containsAny(name, ["csf", "ventricle", "ventricular", "cerebrospinal"])
                let isGray = BrainPETAnalysis.containsAny(name, ["gray", "grey", "cortex", "cortical", "gm"])
                let isCerebellar = BrainPETAnalysis.containsAny(name, ["cerebellum", "cerebellar"])
                let isCorticalTarget = BrainPETAnalysis.containsAny(name, [
                    "frontal", "temporal", "parietal", "occipital",
                    "precuneus", "cingulate", "orbitofrontal", "insular",
                    "precentral", "postcentral"
                ])
                if isWhite {
                    whiteMatter.append(cls.labelID)
                }
                if isCSF {
                    csf.append(cls.labelID)
                }
                if isCerebellar && isGray && !isWhite && !isCSF {
                    cerebellarGray.append(cls.labelID)
                }
                if isCorticalTarget && isGray && !isWhite && !isCSF {
                    corticalGray.append(cls.labelID)
                }
            }
            corticalGrayIDs = corticalGray
            whiteMatterIDs = whiteMatter
            csfIDs = csf
            cerebellarGrayIDs = cerebellarGray
        }

        var hasTissueSeparation: Bool {
            !corticalGrayIDs.isEmpty && (!whiteMatterIDs.isEmpty || !csfIDs.isEmpty)
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func resolveAnatomyMode(_ requested: BrainPETAnatomyMode,
                                           anatomyVolume: ImageVolume?) -> BrainPETAnatomyMode {
        let modality = anatomyVolume.map { Modality.normalize($0.modality) }
        switch requested {
        case .automatic:
            if modality == .MR { return .mriAssisted }
            if modality == .CT { return .ctAssisted }
            return .petOnly
        case .mriAssisted:
            return modality == .MR ? .mriAssisted : .petOnly
        case .ctAssisted:
            return modality == .CT ? .ctAssisted : .petOnly
        case .petOnly:
            return .petOnly
        }
    }

    private static func anatomyQualityMetrics(atlas: LabelMap,
                                              anatomyVolume: ImageVolume?,
                                              requestedMode: BrainPETAnatomyMode,
                                              resolvedMode: BrainPETAnatomyMode,
                                              profile: AnatomyProfile) -> [BrainPETAnatomyQCMetric] {
        let geometryMatch = anatomyVolume.map {
            $0.width == atlas.width && $0.height == atlas.height && $0.depth == atlas.depth
        } ?? false
        let anatomyLabel = anatomyVolume.map {
            let modality = Modality.normalize($0.modality).displayName
            let description = $0.seriesDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? modality : "\(modality): \(description)"
        } ?? "None"
        return [
            BrainPETAnatomyQCMetric(
                id: "mode",
                title: "Mode",
                value: resolvedMode.displayName,
                passed: requestedMode == .petOnly || resolvedMode != .petOnly
            ),
            BrainPETAnatomyQCMetric(
                id: "anatomy",
                title: "Anatomy",
                value: anatomyLabel,
                passed: requestedMode == .petOnly || anatomyVolume != nil
            ),
            BrainPETAnatomyQCMetric(
                id: "grid",
                title: "Grid",
                value: geometryMatch ? "Atlas aligned" : "Registration/preprocessing needed",
                passed: geometryMatch || resolvedMode == .petOnly
            ),
            BrainPETAnatomyQCMetric(
                id: "cortex",
                title: "Cortical gray",
                value: "\(profile.corticalGrayIDs.count) class(es)",
                passed: !profile.corticalGrayIDs.isEmpty
            ),
            BrainPETAnatomyQCMetric(
                id: "whiteMatter",
                title: "White/CSF exclusion",
                value: "\(profile.whiteMatterIDs.count + profile.csfIDs.count) class(es)",
                passed: !profile.whiteMatterIDs.isEmpty || !profile.csfIDs.isEmpty
            )
        ]
    }

    private static func anatomyWarnings(requestedMode: BrainPETAnatomyMode,
                                        resolvedMode: BrainPETAnatomyMode,
                                        anatomyVolume: ImageVolume?,
                                        profile: AnatomyProfile,
                                        standard: BrainPETReport,
                                        anatomyAware: BrainPETReport) -> [String] {
        var warnings: [String] = []
        let delta = BrainPETAnatomyDelta(standard: standard, anatomyAware: anatomyAware)
        if requestedMode != .petOnly, resolvedMode == .petOnly {
            warnings.append("Requested anatomy assistance was unavailable; analysis fell back to PET-only quantification.")
        }
        if resolvedMode == .ctAssisted {
            warnings.append("CT can stabilize registration and brain masking, but low-dose CT alone is limited for gray/white matter separation.")
        }
        if resolvedMode == .mriAssisted, anatomyVolume == nil {
            warnings.append("MRI-assisted mode needs a T1-weighted MRI volume for cortical ribbon segmentation.")
        }
        if !profile.hasTissueSeparation {
            warnings.append("Atlas does not expose enough cortical gray/white/CSF classes for full anatomy-aware spillover correction.")
        }
        if let centiloidDelta = delta.centiloid,
           abs(centiloidDelta) >= 5 {
            warnings.append(String(format: "Anatomy-aware Centiloid differs from standard by %.1f CL; treat borderline cases carefully.", centiloidDelta))
        }
        if let suvrDelta = delta.targetSUVR,
           abs(suvrDelta) >= 0.10 {
            warnings.append(String(format: "Anatomy-aware target SUVR differs from standard by %.3f.", suvrDelta))
        }
        return warnings
    }

    private static func anatomyConfidence(resolvedMode: BrainPETAnatomyMode,
                                          profile: AnatomyProfile) -> BrainPETAnatomyConfidence {
        if resolvedMode == .mriAssisted,
           profile.hasTissueSeparation {
            return .high
        }
        if resolvedMode != .petOnly,
           !profile.corticalGrayIDs.isEmpty {
            return .medium
        }
        return .low
    }

    private struct RegionMean {
        var sum: Double = 0
        var voxelCount: Int = 0

        var mean: Double {
            voxelCount > 0 ? sum / Double(voxelCount) : 0
        }
    }

    private static func regionalMeans(volume: ImageVolume,
                                      atlas: LabelMap) -> [UInt16: RegionMean] {
        var means: [UInt16: RegionMean] = [:]
        for i in atlas.voxels.indices {
            let label = atlas.voxels[i]
            guard label != 0 else { continue }
            var mean = means[label] ?? RegionMean()
            mean.sum += Double(volume.pixels[i])
            mean.voxelCount += 1
            means[label] = mean
        }
        return means
    }

    private static func weightedMean(for ids: [UInt16],
                                     means: [UInt16: RegionMean],
                                     atlas: LabelMap) -> (mean: Double, voxelCount: Int, name: String) {
        var sum = 0.0
        var count = 0
        for id in ids {
            guard let mean = means[id] else { continue }
            sum += mean.sum
            count += mean.voxelCount
        }
        let names = ids.compactMap { id in
            atlas.classes.first(where: { $0.labelID == id })?.name
        }
        return (
            count > 0 ? sum / Double(count) : 0,
            count,
            names.isEmpty ? ids.map(String.init).joined(separator: ",") : names.joined(separator: ", ")
        )
    }

    private static func resolvedReferenceIDs(_ explicit: [UInt16],
                                             atlas: LabelMap,
                                             family: BrainPETAnalysisFamily) -> [UInt16] {
        if !explicit.isEmpty { return explicit }
        let keywords: [String]
        switch family {
        case .fdg:
            keywords = ["pons", "cerebellum", "cerebellar"]
        case .amyloid:
            keywords = ["whole cerebellum", "cerebellum", "cerebellar"]
        case .tau:
            keywords = ["inferior cerebell", "cerebellar gray", "cerebellum"]
        case .generic:
            keywords = ["cerebellum", "pons"]
        }
        let matches = atlas.classes.filter { cls in
            let name = normalizedRegionName(cls.name)
            return keywords.contains { name.contains($0) }
        }
        if !matches.isEmpty {
            return matches.map(\.labelID)
        }
        return atlas.classes.map(\.labelID)
    }

    private static func resolvedTargetIDs(_ explicit: [UInt16],
                                          atlas: LabelMap,
                                          family: BrainPETAnalysisFamily) -> [UInt16] {
        if !explicit.isEmpty { return explicit }
        switch family {
        case .fdg:
            return atlas.classes
                .filter { !normalizedRegionName($0.name).contains("cerebell") && !normalizedRegionName($0.name).contains("pons") }
                .map(\.labelID)
        case .amyloid:
            return atlas.classes.filter { cls in
                let name = normalizedRegionName(cls.name)
                return ["frontal", "temporal", "parietal", "precuneus", "cingulate", "orbitofrontal"].contains {
                    name.contains($0)
                }
            }.map(\.labelID)
        case .tau:
            return atlas.classes.filter { cls in
                let name = normalizedRegionName(cls.name)
                return !name.contains("cerebell") && !name.contains("pons")
            }.map(\.labelID)
        case .generic:
            return atlas.classes.map(\.labelID)
        }
    }

    private static func tauGrade(atlas: LabelMap,
                                 regionStats: [BrainPETRegionStatistic],
                                 threshold: Double) -> BrainPETTauGrade {
        let groups: [(id: String, name: String, keywords: [String])] = [
            ("braak12", "Braak I/II-like", ["entorhinal", "hippocampus", "parahippocampal", "amygdala"]),
            ("braak34", "Braak III/IV-like", ["inferior temporal", "middle temporal", "fusiform", "lingual"]),
            ("braak56", "Braak V/VI-like", ["frontal", "parietal", "precuneus", "occipital", "cingulate"])
        ]
        var statsByID: [UInt16: BrainPETRegionStatistic] = [:]
        for stat in regionStats {
            statsByID[stat.labelID] = stat
        }
        let tauGroups = groups.map { group -> BrainPETTauGroup in
            let ids = atlas.classes.filter { cls in
                let name = normalizedRegionName(cls.name)
                return group.keywords.contains { name.contains($0) }
            }.map(\.labelID)
            let values = ids.compactMap { statsByID[$0]?.suvr }
            let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            return BrainPETTauGroup(
                id: group.id,
                name: group.name,
                meanSUVR: mean,
                positive: (mean ?? -Double.infinity) >= threshold
            )
        }

        let stage: String
        if tauGroups.dropFirst(2).first?.positive == true {
            stage = "Braak V/VI-like"
        } else if tauGroups.dropFirst().first?.positive == true {
            stage = "Braak III/IV-like"
        } else if tauGroups.first?.positive == true {
            stage = "Braak I/II-like"
        } else {
            stage = "Tau-negative or below threshold"
        }
        return BrainPETTauGrade(threshold: threshold, stage: stage, groups: tauGroups)
    }
}
