import Foundation

public enum AutoPETVManifestBuilder {
    public struct DraftCase: Identifiable, Equatable, Sendable {
        public var id: String { caseID }
        public var caseID: String
        public var split: AutoPETVCaseManifestEntry.Split
        public var ctVolumeIdentity: String
        public var petVolumeIdentity: String
        public var labelMapID: UUID?
        public var labelParentVolumeIdentity: String?
        public var ctDescription: String
        public var petDescription: String
        public var labelDescription: String
        public var patientID: String
        public var patientName: String
        public var studyDescription: String
        public var tracer: String
        public var center: String
        public var warnings: [String]
        public var include: Bool

        public init(caseID: String,
                    split: AutoPETVCaseManifestEntry.Split = .train,
                    ctVolumeIdentity: String,
                    petVolumeIdentity: String,
                    labelMapID: UUID?,
                    labelParentVolumeIdentity: String?,
                    ctDescription: String,
                    petDescription: String,
                    labelDescription: String,
                    patientID: String,
                    patientName: String,
                    studyDescription: String,
                    tracer: String,
                    center: String,
                    warnings: [String] = [],
                    include: Bool = true) {
            self.caseID = caseID
            self.split = split
            self.ctVolumeIdentity = ctVolumeIdentity
            self.petVolumeIdentity = petVolumeIdentity
            self.labelMapID = labelMapID
            self.labelParentVolumeIdentity = labelParentVolumeIdentity
            self.ctDescription = ctDescription
            self.petDescription = petDescription
            self.labelDescription = labelDescription
            self.patientID = patientID
            self.patientName = patientName
            self.studyDescription = studyDescription
            self.tracer = tracer
            self.center = center
            self.warnings = warnings
            self.include = include
        }
    }

    public enum BuildError: Error, LocalizedError {
        case noCases
        case missingVolume(String)
        case missingLabel(String)
        case geometryMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .noCases:
                return "No AutoPET V cases are selected."
            case .missingVolume(let message):
                return message
            case .missingLabel(let message):
                return message
            case .geometryMismatch(let message):
                return message
            }
        }
    }

    public static func draftCases(volumes: [ImageVolume],
                                  labelMaps: [LabelMap],
                                  defaultSplit: AutoPETVCaseManifestEntry.Split = .train) -> [DraftCase] {
        let pets = volumes.filter { Modality.normalize($0.modality) == .PT }
        let cts = volumes.filter { Modality.normalize($0.modality) == .CT }
        guard !pets.isEmpty, !cts.isEmpty else { return [] }

        var usedCaseIDs = Set<String>()
        return pets.enumerated().compactMap { index, pet -> DraftCase? in
            guard let ct = bestCT(for: pet, candidates: cts) else { return nil }
            let labelPair = bestLabel(for: pet, ct: ct, labels: labelMaps, volumes: volumes)
            var warnings: [String] = []
            if labelPair.map == nil {
                warnings.append("No matching label map")
            }
            if geometryMismatch(ct, pet) != nil {
                warnings.append("PET/CT geometry differs; DGX script will require pre-registration or resampling")
            }
            let caseID = uniqueCaseID(base: baseCaseID(for: pet, index: index), used: &usedCaseIDs)
            return DraftCase(
                caseID: caseID,
                split: defaultSplit,
                ctVolumeIdentity: ct.sessionIdentity,
                petVolumeIdentity: pet.sessionIdentity,
                labelMapID: labelPair.map?.id,
                labelParentVolumeIdentity: labelPair.parent?.sessionIdentity,
                ctDescription: volumeDescription(ct),
                petDescription: volumeDescription(pet),
                labelDescription: labelPair.map?.name ?? "None",
                patientID: pet.patientID.isEmpty ? ct.patientID : pet.patientID,
                patientName: pet.patientName.isEmpty ? ct.patientName : pet.patientName,
                studyDescription: pet.studyDescription.isEmpty ? ct.studyDescription : pet.studyDescription,
                tracer: inferredTracer(from: pet),
                center: "",
                warnings: warnings,
                include: labelPair.map != nil
            )
        }
    }

    public static func makePackageSources(drafts: [DraftCase],
                                          volumes: [ImageVolume],
                                          labelMaps: [LabelMap]) throws -> [AutoPETVCasePackageSource] {
        let selected = drafts.filter(\.include)
        guard !selected.isEmpty else { throw BuildError.noCases }
        var sources: [AutoPETVCasePackageSource] = []
        for draft in selected {
            guard let ct = volumes.first(where: { $0.sessionIdentity == draft.ctVolumeIdentity }) else {
                throw BuildError.missingVolume("Missing CT volume for \(draft.caseID).")
            }
            guard let pet = volumes.first(where: { $0.sessionIdentity == draft.petVolumeIdentity }) else {
                throw BuildError.missingVolume("Missing PET volume for \(draft.caseID).")
            }
            let label = draft.labelMapID.flatMap { id in labelMaps.first { $0.id == id } }
            if draft.split != .test, label == nil {
                throw BuildError.missingLabel("\(draft.caseID) is \(draft.split.rawValue) but has no label map.")
            }
            if let mismatch = geometryMismatch(ct, pet) {
                throw BuildError.geometryMismatch("\(draft.caseID): \(mismatch)")
            }
            if let label, !sameGrid(label, pet), !sameGrid(label, ct) {
                throw BuildError.geometryMismatch("\(draft.caseID): label map does not match PET or CT grid.")
            }
            let parent = draft.labelParentVolumeIdentity.flatMap { identity in
                volumes.first { $0.sessionIdentity == identity }
            } ?? label.flatMap { sameGrid($0, pet) ? pet : ct }
            sources.append(AutoPETVCasePackageSource(
                caseID: draft.caseID,
                split: draft.split,
                ctVolume: ct,
                petVolume: pet,
                labelMap: label,
                labelParentVolume: parent,
                tracer: draft.tracer,
                center: draft.center,
                notes: draft.warnings.joined(separator: "; ")
            ))
        }
        return sources
    }

    private static func bestCT(for pet: ImageVolume,
                               candidates: [ImageVolume]) -> ImageVolume? {
        candidates.sorted { lhs, rhs in
            score(ct: lhs, pet: pet) > score(ct: rhs, pet: pet)
        }.first
    }

    private static func score(ct: ImageVolume, pet: ImageVolume) -> Int {
        var score = 0
        if !pet.studyUID.isEmpty, pet.studyUID == ct.studyUID { score += 100 }
        if !pet.patientID.isEmpty, pet.patientID == ct.patientID { score += 40 }
        if parentFolder(pet) == parentFolder(ct) { score += 25 }
        if geometryMismatch(ct, pet) == nil { score += 15 }
        return score
    }

    private static func bestLabel(for pet: ImageVolume,
                                  ct: ImageVolume,
                                  labels: [LabelMap],
                                  volumes: [ImageVolume]) -> (map: LabelMap?, parent: ImageVolume?) {
        let pairs = labels.compactMap { label -> (LabelMap, ImageVolume, Int)? in
            let parent = volumes.first { $0.seriesUID == label.parentSeriesUID }
                ?? (sameGrid(label, pet) ? pet : nil)
                ?? (sameGrid(label, ct) ? ct : nil)
            guard let parent else { return nil }
            var score = 0
            if parent.seriesUID == pet.seriesUID { score += 100 }
            if parent.seriesUID == ct.seriesUID { score += 80 }
            if sameGrid(label, pet) { score += 25 }
            if sameGrid(label, ct) { score += 15 }
            if label.voxels.contains(where: { $0 != 0 }) { score += 10 }
            return (label, parent, score)
        }
        guard let best = pairs.sorted(by: { $0.2 > $1.2 }).first else {
            return (nil, nil)
        }
        return (best.0, best.1)
    }

    private static func sameGrid(_ label: LabelMap, _ volume: ImageVolume) -> Bool {
        label.width == volume.width
            && label.height == volume.height
            && label.depth == volume.depth
    }

    private static func geometryMismatch(_ ct: ImageVolume, _ pet: ImageVolume) -> String? {
        NNUnetRunner.gridMismatchDescription(ct, reference: pet, channelIndex: 0)
    }

    private static func baseCaseID(for pet: ImageVolume, index: Int) -> String {
        let patient = pet.patientID.isEmpty ? "patient" : pet.patientID
        let study = pet.studyDate.isEmpty ? "study" : pet.studyDate
        let series = pet.seriesNumber > 0 ? String(format: "s%03d", pet.seriesNumber) : "pet\(index + 1)"
        return sanitize("\(patient)-\(study)-\(series)")
    }

    private static func uniqueCaseID(base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "autopetv-case" : cleaned
    }

    private static func volumeDescription(_ volume: ImageVolume) -> String {
        let modality = Modality.normalize(volume.modality).displayName
        let series = volume.seriesDescription.isEmpty ? "Series \(volume.seriesNumber)" : volume.seriesDescription
        return "\(modality) - \(series) - \(volume.width)x\(volume.height)x\(volume.depth)"
    }

    private static func inferredTracer(from pet: ImageVolume) -> String {
        let text = [
            pet.seriesDescription,
            pet.studyDescription,
            pet.bodyPartExamined
        ].joined(separator: " ").lowercased()
        if text.contains("psma") { return "PSMA" }
        if text.contains("fdg") { return "FDG" }
        if text.contains("dotatate") || text.contains("dota") { return "DOTATATE" }
        return ""
    }

    private static func parentFolder(_ volume: ImageVolume) -> String {
        guard let first = volume.sourceFiles.first else { return "" }
        return (first as NSString).deletingLastPathComponent
    }
}
