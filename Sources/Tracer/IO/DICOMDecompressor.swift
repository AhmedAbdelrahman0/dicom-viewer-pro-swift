import Foundation

public enum DICOMDecompressionTool: String, CaseIterable, Sendable {
    case gdcmconv
    case dcmconv
    case dcmdjpeg

    public var executableName: String { rawValue }
}

public struct DICOMDecompressionCommand: Equatable, Sendable {
    public let tool: DICOMDecompressionTool
    public let executablePath: String
    public let arguments: [String]
}

public struct DICOMDecompressionResult: Sendable {
    public let url: URL
    public let tool: DICOMDecompressionTool
    public let cleanup: @Sendable () -> Void
}

public enum DICOMDecompressorError: Error, LocalizedError, Equatable {
    case noDecoderAvailable
    case missingSourcePath
    case decoderFailed(tool: DICOMDecompressionTool, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .noDecoderAvailable:
            return "Compressed DICOM requires an external decoder. Install GDCM (gdcmconv) or DCMTK (dcmconv/dcmdjpeg)."
        case .missingSourcePath:
            return "Compressed DICOM source path is missing."
        case .decoderFailed(let tool, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(tool.executableName) could not decompress this DICOM."
                : "\(tool.executableName) could not decompress this DICOM: \(detail)"
        }
    }
}

public enum DICOMDecompressor {
    private static let uncompressedTransferSyntaxes: Set<String> = [
        "1.2.840.10008.1.2",
        "1.2.840.10008.1.2.1",
    ]

    public static func needsDecompression(_ dcm: DICOMFile) -> Bool {
        let uid = dcm.transferSyntaxUID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return dcm.pixelDataUndefinedLength || !uncompressedTransferSyntaxes.contains(uid)
    }

    public static func command(tool: DICOMDecompressionTool,
                               executablePath: String,
                               source: URL,
                               destination: URL) -> DICOMDecompressionCommand {
        let arguments: [String]
        switch tool {
        case .gdcmconv:
            arguments = ["--raw", source.path, destination.path]
        case .dcmconv:
            arguments = ["+te", source.path, destination.path]
        case .dcmdjpeg:
            arguments = [source.path, destination.path]
        }
        return DICOMDecompressionCommand(tool: tool,
                                         executablePath: executablePath,
                                         arguments: arguments)
    }

    public static func resolvedToolPaths(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         fileManager: FileManager = .default) -> [(DICOMDecompressionTool, String)] {
        var directories = searchPathDirectories(environment: environment)
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        var seen = Set<String>()
        var resolved: [(DICOMDecompressionTool, String)] = []
        for tool in DICOMDecompressionTool.allCases {
            for directory in directories {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(tool.executableName)
                    .path
                guard seen.insert("\(tool.rawValue):\(path)").inserted,
                      fileManager.isExecutableFile(atPath: path) else {
                    continue
                }
                resolved.append((tool, path))
                break
            }
        }
        return resolved
    }

    public static func decompress(_ dcm: DICOMFile,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  fileManager: FileManager = .default) throws -> DICOMDecompressionResult {
        guard needsDecompression(dcm) else {
            return DICOMDecompressionResult(url: URL(fileURLWithPath: dcm.filePath),
                                            tool: .gdcmconv,
                                            cleanup: {})
        }
        guard !dcm.filePath.isEmpty else {
            throw DICOMDecompressorError.missingSourcePath
        }

        let toolPaths = resolvedToolPaths(environment: environment, fileManager: fileManager)
        guard !toolPaths.isEmpty else {
            throw DICOMDecompressorError.noDecoderAvailable
        }

        let source = URL(fileURLWithPath: dcm.filePath)
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tracer-dicom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        var lastFailure: DICOMDecompressorError?
        for (tool, executablePath) in toolPaths {
            let destination = tempDirectory
                .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(tool.rawValue).dcm")
            let request = command(tool: tool,
                                  executablePath: executablePath,
                                  source: source,
                                  destination: destination)
            do {
                let stderr = try run(request)
                if fileManager.fileExists(atPath: destination.path) {
                    let cleanupURL = tempDirectory
                    return DICOMDecompressionResult(
                        url: destination,
                        tool: tool,
                        cleanup: { try? FileManager.default.removeItem(at: cleanupURL) }
                    )
                }
                lastFailure = .decoderFailed(tool: tool, stderr: stderr)
            } catch let error as DICOMDecompressorError {
                lastFailure = error
            }
        }

        try? fileManager.removeItem(at: tempDirectory)
        throw lastFailure ?? DICOMDecompressorError.noDecoderAvailable
    }

    private static func run(_ command: DICOMDecompressionCommand) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw DICOMDecompressorError.decoderFailed(tool: command.tool,
                                                       stderr: error.localizedDescription)
        }
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw DICOMDecompressorError.decoderFailed(tool: command.tool, stderr: stderr)
        }
        return stderr
    }

    private static func searchPathDirectories(environment: [String: String]) -> [String] {
        let path = environment["PATH"] ?? ""
        return path
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
