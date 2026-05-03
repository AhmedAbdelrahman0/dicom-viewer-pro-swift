import CoreGraphics
import Foundation

public struct PACSThumbnail: Codable, Equatable, Sendable {
    public let seriesID: String
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(seriesID: String, width: Int, height: Int, pixels: [UInt8]) {
        self.seriesID = seriesID
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var cgImage: CGImage? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

public struct PACSThumbnailStore: Sendable {
    public let rootURL: URL
    public let thumbnailSize: Int

    public init(rootURL: URL? = nil, thumbnailSize: Int = 64) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = base
                .appendingPathComponent("Tracer", isDirectory: true)
                .appendingPathComponent("PACSThumbnails", isDirectory: true)
        }
        self.thumbnailSize = max(16, min(256, thumbnailSize))
    }

    public func thumbnail(for study: PACSWorklistStudy) -> PACSThumbnail? {
        guard let series = preferredThumbnailSeries(for: study) else { return nil }
        return thumbnail(for: series)
    }

    public func thumbnail(for series: PACSIndexedSeriesSnapshot) -> PACSThumbnail? {
        if let cached = load(seriesID: series.id) {
            return cached
        }
        guard let generated = generateThumbnail(for: series) else { return nil }
        try? save(generated)
        return generated
    }

    public func load(seriesID: String) -> PACSThumbnail? {
        let url = thumbnailURL(seriesID: seriesID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PACSThumbnail.self, from: data)
    }

    public func save(_ thumbnail: PACSThumbnail) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(thumbnail)
        try data.write(to: thumbnailURL(seriesID: thumbnail.seriesID), options: [.atomic])
    }

    private func preferredThumbnailSeries(for study: PACSWorklistStudy) -> PACSIndexedSeriesSnapshot? {
        study.preferredPETSeriesForPETCT
            ?? study.preferredAnatomicalSeriesForPETCT
            ?? PACSWorklistStudy.preferredPrimaryImageSeries(in: study.series)
    }

    private func generateThumbnail(for series: PACSIndexedSeriesSnapshot) -> PACSThumbnail? {
        guard series.kind == .dicom,
              let firstPath = firstDICOMPath(for: series) else {
            return nil
        }
        do {
            let file = try DICOMLoader.parseHeader(at: URL(fileURLWithPath: firstPath))
            let pixels = try DICOMLoader.loadSlicePixels(file)
            return makeThumbnail(seriesID: series.id,
                                 source: pixels,
                                 sourceWidth: file.columns,
                                 sourceHeight: file.rows)
        } catch {
            return nil
        }
    }

    private func firstDICOMPath(for series: PACSIndexedSeriesSnapshot) -> String? {
        if let first = series.filePaths.first, !first.isEmpty {
            return first
        }
        return series.sourcePath.isEmpty ? nil : series.sourcePath
    }

    private func makeThumbnail(seriesID: String,
                               source: [Float],
                               sourceWidth: Int,
                               sourceHeight: Int) -> PACSThumbnail? {
        guard sourceWidth > 0,
              sourceHeight > 0,
              source.count >= sourceWidth * sourceHeight else {
            return nil
        }
        let scale = min(Double(thumbnailSize) / Double(sourceWidth),
                        Double(thumbnailSize) / Double(sourceHeight))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let range = robustRange(source)
        let denominator = max(0.000_001, range.max - range.min)
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, Int(Double(y) / Double(height) * Double(sourceHeight)))
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, Int(Double(x) / Double(width) * Double(sourceWidth)))
                let value = Double(source[sourceY * sourceWidth + sourceX])
                let normalized = min(1, max(0, (value - range.min) / denominator))
                output[y * width + x] = UInt8((normalized * 255).rounded())
            }
        }
        return PACSThumbnail(seriesID: seriesID, width: width, height: height, pixels: output)
    }

    private func robustRange(_ values: [Float]) -> (min: Double, max: Double) {
        let finite = values.filter { $0.isFinite }.map(Double.init).sorted()
        guard !finite.isEmpty else { return (0, 1) }
        let lowIndex = min(finite.count - 1, max(0, finite.count / 100))
        let highIndex = min(finite.count - 1, max(0, finite.count - finite.count / 100 - 1))
        let low = finite[lowIndex]
        let high = finite[highIndex]
        if high > low { return (low, high) }
        return (finite.first ?? 0, (finite.first ?? 0) + 1)
    }

    private func thumbnailURL(seriesID: String) -> URL {
        rootURL
            .appendingPathComponent(safePathComponent(seriesID))
            .appendingPathExtension("json")
    }

    private func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return value.isEmpty ? "thumbnail" : value
    }
}
