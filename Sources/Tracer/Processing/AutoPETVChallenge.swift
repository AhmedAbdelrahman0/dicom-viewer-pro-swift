import Foundation

/// AutoPET V / AutoPET5 challenge-facing helpers.
///
/// The challenge inference contract is not the same as the app's regular
/// viewer workflow: each interaction step provides CT MHA, PET MHA, and a
/// foreground/background scribble JSON; the algorithm writes one lesion mask
/// MHA. These types keep that contract explicit while still reusing Tracer's
/// normal `ImageVolume`, `LabelMap`, and `NNUnetRunner` machinery.
public enum AutoPETVChallenge {
    public enum Error: Swift.Error, LocalizedError {
        case missingInput(String)
        case invalidScribbles(String)
        case geometryMismatch(String)
        case noPrediction

        public var errorDescription: String? {
            switch self {
            case .missingInput(let message):
                return "AutoPET V input missing: \(message)"
            case .invalidScribbles(let message):
                return "AutoPET V scribbles invalid: \(message)"
            case .geometryMismatch(let message):
                return "AutoPET V geometry mismatch: \(message)"
            case .noPrediction:
                return "AutoPET V runner produced no prediction."
            }
        }
    }

    public struct VoxelPoint: Codable, Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let z: Int

        public init(x: Int, y: Int, z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }

        init(array: [Double]) throws {
            guard array.count >= 3 else {
                throw Error.invalidScribbles("point must contain x, y, z")
            }
            self.x = Int(array[0].rounded())
            self.y = Int(array[1].rounded())
            self.z = Int(array[2].rounded())
        }

        public func clamped(to volume: ImageVolume) -> VoxelPoint? {
            guard volume.width > 0, volume.height > 0, volume.depth > 0 else { return nil }
            return VoxelPoint(
                x: min(max(x, 0), volume.width - 1),
                y: min(max(y, 0), volume.height - 1),
                z: min(max(z, 0), volume.depth - 1)
            )
        }
    }

    public struct ScribbleSet: Equatable, Sendable {
        public var foreground: [VoxelPoint]
        public var background: [VoxelPoint]

        public init(foreground: [VoxelPoint] = [], background: [VoxelPoint] = []) {
            self.foreground = foreground
            self.background = background
        }

        public static func load(from url: URL) throws -> ScribbleSet {
            try parse(Data(contentsOf: url))
        }

        public static func parse(_ data: Data) throws -> ScribbleSet {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw Error.invalidScribbles("root must be a JSON object")
            }

            var set = ScribbleSet()
            if let points = root["points"] as? [[String: Any]] {
                for point in points {
                    let name = String(describing: point["name"] ?? point["label"] ?? "")
                        .lowercased()
                    guard let raw = point["point"] ?? point["coord"] ?? point["coordinate"] else {
                        continue
                    }
                    let voxel = try VoxelPoint(array: Self.doubleArray(raw))
                    if name == "tumor" || name == "foreground" || name == "fg" || name == "lesion" {
                        set.foreground.append(voxel)
                    } else if name == "background" || name == "bg" || name == "non_tumor" || name == "non-tumor" {
                        set.background.append(voxel)
                    }
                }
            }

            set.foreground += try pointArray(root["tumor"])
            set.foreground += try pointArray(root["foreground"])
            set.foreground += try pointArray(root["fg"])
            set.background += try pointArray(root["background"])
            set.background += try pointArray(root["bg"])

            return set
        }

        private static func pointArray(_ raw: Any?) throws -> [VoxelPoint] {
            guard let raw else { return [] }
            guard let arrays = raw as? [[Any]] else {
                throw Error.invalidScribbles("point list must be an array of coordinate arrays")
            }
            return try arrays.map { try VoxelPoint(array: doubleArray($0)) }
        }

        private static func doubleArray(_ raw: Any) throws -> [Double] {
            guard let values = raw as? [Any] else {
                throw Error.invalidScribbles("point must be an array")
            }
            let doubles = values.compactMap { value -> Double? in
                if let number = value as? NSNumber { return number.doubleValue }
                if let string = value as? String { return Double(string) }
                return nil
            }
            guard doubles.count == values.count else {
                throw Error.invalidScribbles("point coordinates must be numeric")
            }
            return doubles
        }
    }

    public struct ChallengeInput: Sendable {
        public let ctURL: URL
        public let petURL: URL
        public let scribblesURL: URL
        public let outputName: String

        public init(ctURL: URL, petURL: URL, scribblesURL: URL, outputName: String) {
            self.ctURL = ctURL
            self.petURL = petURL
            self.scribblesURL = scribblesURL
            self.outputName = outputName
        }
    }

    public enum PromptEncoding: Equatable, Sendable {
        case binary
        case distanceTransform(maxDistanceMM: Double)
    }

    public static func discoverInput(root: URL) throws -> ChallengeInput {
        let ctURL = try firstFile(in: root.appendingPathComponent("images/ct", isDirectory: true),
                                  suffixes: [".mha", ".mhd"])
        let petURL = try firstFile(in: root.appendingPathComponent("images/pet", isDirectory: true),
                                   suffixes: [".mha", ".mhd"])
        let scribblesURL = root.appendingPathComponent("lesion-clicks.json")
        guard FileManager.default.fileExists(atPath: scribblesURL.path) else {
            throw Error.missingInput("lesion-clicks.json")
        }
        return ChallengeInput(
            ctURL: ctURL,
            petURL: petURL,
            scribblesURL: scribblesURL,
            outputName: stripKnownExtension(ctURL.lastPathComponent)
        )
    }

    public static func makeScribbleHeatmap(reference: ImageVolume,
                                           points: [VoxelPoint],
                                           name: String) -> ImageVolume {
        var pixels = [Float](repeating: 0, count: reference.pixels.count)
        for point in points {
            guard let p = point.clamped(to: reference) else { continue }
            let index = p.z * reference.height * reference.width + p.y * reference.width + p.x
            pixels[index] = 1
        }
        return ImageVolume(
            pixels: pixels,
            depth: reference.depth,
            height: reference.height,
            width: reference.width,
            spacing: reference.spacing,
            origin: reference.origin,
            direction: reference.direction,
            modality: "OT",
            seriesUID: "autopetv:\(name):\(UUID().uuidString)",
            studyUID: reference.studyUID,
            patientID: reference.patientID,
            patientName: reference.patientName,
            seriesDescription: name,
            studyDescription: reference.studyDescription
        )
    }

    public static func makeChannels(ct: ImageVolume,
                                    pet: ImageVolume,
                                    scribbles: ScribbleSet,
                                    promptEncoding: PromptEncoding = .binary) throws -> [ImageVolume] {
        if let mismatch = NNUnetRunner.gridMismatchDescription(ct, reference: pet, channelIndex: 0) {
            throw Error.geometryMismatch(mismatch)
        }
        let foreground: ImageVolume
        let background: ImageVolume
        switch promptEncoding {
        case .binary:
            foreground = makeScribbleHeatmap(reference: pet,
                                             points: scribbles.foreground,
                                             name: "AutoPET V foreground scribbles")
            background = makeScribbleHeatmap(reference: pet,
                                             points: scribbles.background,
                                             name: "AutoPET V background scribbles")
        case .distanceTransform(let maxDistanceMM):
            foreground = AutoPETVWorkbench.makeEDTPromptChannel(
                reference: pet,
                points: scribbles.foreground,
                name: "AutoPET V foreground EDT scribbles",
                maxDistanceMM: maxDistanceMM
            )
            background = AutoPETVWorkbench.makeEDTPromptChannel(
                reference: pet,
                points: scribbles.background,
                name: "AutoPET V background EDT scribbles",
                maxDistanceMM: maxDistanceMM
            )
        }
        return [ct, pet, foreground, background]
    }

    public static func writeOutput(_ labelMap: LabelMap,
                                   outputRoot: URL,
                                   outputName: String,
                                   parentVolume: ImageVolume) throws -> URL {
        let outputDirectory = outputRoot
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("tumor-lesion-segmentation", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent("\(outputName).mha")
        try MetaImageIO.writeLabelMap(labelMap, to: outputURL, parentVolume: parentVolume, binary: true)
        return outputURL
    }

    private static func firstFile(in directory: URL, suffixes: [String]) throws -> URL {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw Error.missingInput(directory.path)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { url in
            let lower = url.lastPathComponent.lowercased()
            return suffixes.contains { lower.hasSuffix($0) }
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = files.first else {
            throw Error.missingInput("no MHA file in \(directory.path)")
        }
        return first
    }

    private static func stripKnownExtension(_ filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".mha") || lower.hasSuffix(".mhd") ||
           lower.hasSuffix(".nii") {
            return String(filename.dropLast(4))
        }
        if lower.hasSuffix(".nii.gz") {
            return String(filename.dropLast(7))
        }
        return filename
    }
}

public final class AutoPETVChallengeRunner: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var nnunet: NNUnetRunner.Configuration
        public var datasetID: String
        public var promptEncoding: AutoPETVChallenge.PromptEncoding

        public init(nnunet: NNUnetRunner.Configuration = NNUnetRunner.Configuration(),
                    datasetID: String = "Dataset998_AutoPETV",
                    promptEncoding: AutoPETVChallenge.PromptEncoding = .distanceTransform(maxDistanceMM: 40)) {
            self.nnunet = nnunet
            self.datasetID = datasetID
            self.promptEncoding = promptEncoding
        }
    }

    public struct Result: Sendable {
        public let labelMap: LabelMap
        public let outputURL: URL
        public let durationSeconds: TimeInterval
        public let stderr: String
    }

    private let runner: NNUnetRunner
    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.runner = NNUnetRunner(configuration: configuration.nnunet)
    }

    public func cancel() {
        runner.cancel()
    }

    @discardableResult
    public func run(inputRoot: URL = URL(fileURLWithPath: "/input"),
                    outputRoot: URL = URL(fileURLWithPath: "/output"),
                    logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let input = try AutoPETVChallenge.discoverInput(root: inputRoot)
        let ct = try MetaImageIO.load(input.ctURL, modalityHint: "CT")
        let pet = try MetaImageIO.load(input.petURL, modalityHint: "PT")
        let scribbles = try AutoPETVChallenge.ScribbleSet.load(from: input.scribblesURL)
        let channels = try AutoPETVChallenge.makeChannels(ct: ct,
                                                           pet: pet,
                                                           scribbles: scribbles,
                                                           promptEncoding: configuration.promptEncoding)

        runner.update(configuration: configuration.nnunet)
        let inference = try await runner.runInference(
            channels: channels,
            referenceVolume: pet,
            datasetID: configuration.datasetID,
            logSink: logSink
        )
        let output = try AutoPETVChallenge.writeOutput(
            inference.labelMap,
            outputRoot: outputRoot,
            outputName: input.outputName,
            parentVolume: pet
        )
        return Result(labelMap: inference.labelMap,
                      outputURL: output,
                      durationSeconds: inference.durationSeconds,
                      stderr: inference.stderr)
    }
}
