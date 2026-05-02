import Darwin
import Foundation
import Tracer

@main
struct TracerAutoPETVMain {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments)
            if options.showHelp {
                print(Options.help)
                return
            }

            var nnunet = NNUnetRunner.Configuration(
                predictBinaryPath: options.predictBinaryPath,
                resultsDir: options.resultsDir,
                rawDir: options.rawDir,
                preprocessedDir: options.preprocessedDir,
                modelFolder: options.modelFolder,
                configuration: options.configuration,
                folds: options.folds,
                checkpoint: options.checkpoint,
                disableTestTimeAugmentation: !options.enableTTA,
                timeoutSeconds: options.timeoutSeconds
            )
            nnunet.quiet = options.quiet

            let runner = AutoPETVChallengeRunner(
                configuration: AutoPETVChallengeRunner.Configuration(
                    nnunet: nnunet,
                    datasetID: options.datasetID,
                    promptEncoding: options.promptEncoding
                )
            )
            let result = try await runner.run(
                inputRoot: options.inputRoot,
                outputRoot: options.outputRoot
            ) { line in
                print(line)
            }
            print("AutoPET V prediction written to \(result.outputURL.path)")
        } catch {
            fputs("TracerAutoPETV failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private struct Options {
    var inputRoot = URL(fileURLWithPath: "/input")
    var outputRoot = URL(fileURLWithPath: "/output")
    var datasetID = "Dataset998_AutoPETV"
    var predictBinaryPath: String?
    var resultsDir: URL?
    var rawDir: URL?
    var preprocessedDir: URL?
    var modelFolder: URL?
    var configuration = "3d_fullres"
    var folds = ["0"]
    var checkpoint: String?
    var promptDistanceMM: Double = 40
    var promptEncoding: AutoPETVChallenge.PromptEncoding = .distanceTransform(maxDistanceMM: 40)
    var enableTTA = false
    var quiet = true
    var timeoutSeconds: TimeInterval?
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--input":
                options.inputRoot = try urlValue(arguments, at: &index, name: argument)
            case "--output":
                options.outputRoot = try urlValue(arguments, at: &index, name: argument)
            case "--dataset-id":
                options.datasetID = try stringValue(arguments, at: &index, name: argument)
            case "--predict-binary":
                options.predictBinaryPath = try stringValue(arguments, at: &index, name: argument)
            case "--results-dir":
                options.resultsDir = try urlValue(arguments, at: &index, name: argument)
            case "--raw-dir":
                options.rawDir = try urlValue(arguments, at: &index, name: argument)
            case "--preprocessed-dir":
                options.preprocessedDir = try urlValue(arguments, at: &index, name: argument)
            case "--model-folder":
                options.modelFolder = try urlValue(arguments, at: &index, name: argument)
            case "--configuration":
                options.configuration = try stringValue(arguments, at: &index, name: argument)
            case "--folds":
                options.folds = try stringValue(arguments, at: &index, name: argument)
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if options.folds.isEmpty {
                    throw ParseError.invalidValue("--folds must contain at least one fold")
                }
            case "--checkpoint":
                options.checkpoint = try stringValue(arguments, at: &index, name: argument)
            case "--prompt-encoding":
                let value = try stringValue(arguments, at: &index, name: argument).lowercased()
                switch value {
                case "binary":
                    options.promptEncoding = .binary
                case "edt", "distance", "distance-transform":
                    options.promptEncoding = .distanceTransform(maxDistanceMM: options.promptDistanceMM)
                default:
                    throw ParseError.invalidValue("--prompt-encoding must be binary or edt")
                }
            case "--prompt-distance-mm":
                let value = try stringValue(arguments, at: &index, name: argument)
                guard let distance = Double(value), distance > 0 else {
                    throw ParseError.invalidValue("--prompt-distance-mm must be a positive number")
                }
                options.promptDistanceMM = distance
                options.promptEncoding = .distanceTransform(maxDistanceMM: distance)
            case "--enable-tta":
                options.enableTTA = true
            case "--verbose":
                options.quiet = false
            case "--timeout-seconds":
                let value = try stringValue(arguments, at: &index, name: argument)
                guard let seconds = TimeInterval(value), seconds > 0 else {
                    throw ParseError.invalidValue("--timeout-seconds must be a positive number")
                }
                options.timeoutSeconds = seconds
            default:
                throw ParseError.unknownArgument(argument)
            }
            index += 1
        }
        return options
    }

    private static func stringValue(_ arguments: [String],
                                    at index: inout Int,
                                    name: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ParseError.missingValue(name)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func urlValue(_ arguments: [String],
                                 at index: inout Int,
                                 name: String) throws -> URL {
        let value = try stringValue(arguments, at: &index, name: name)
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    static let help = """
    Usage: TracerAutoPETV [options]

    Runs the AutoPET V / AutoPET5 challenge adapter.

    Expected input:
      /input/images/ct/*.mha
      /input/images/pet/*.mha
      /input/lesion-clicks.json

    Output:
      /output/images/tumor-lesion-segmentation/<case>.mha

    Options:
      --input <path>             Input root. Default: /input
      --output <path>            Output root. Default: /output
      --dataset-id <id>          nnU-Net dataset id. Default: Dataset998_AutoPETV
      --model-folder <path>      Direct nnU-Net trained model folder.
      --results-dir <path>       nnUNet_results directory.
      --raw-dir <path>           nnUNet_raw directory.
      --preprocessed-dir <path>  nnUNet_preprocessed directory.
      --predict-binary <path>    nnUNetv2_predict binary or sibling folder.
      --configuration <name>     nnU-Net config. Default: 3d_fullres
      --folds <csv>              Folds, for example 0 or 0,1,2,3,4. Default: 0
      --checkpoint <name>        Optional checkpoint override.
      --prompt-encoding <value>  Prompt channels: edt or binary. Default: edt
      --prompt-distance-mm <mm>  EDT falloff distance. Default: 40
      --enable-tta               Enable nnU-Net test-time augmentation.
      --timeout-seconds <value>  Stop after this many seconds.
      --verbose                  Let nnU-Net emit full logs.
      --help                     Show this help.
    """
}

private enum ParseError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let name):
            return "Missing value for \(name)."
        case .invalidValue(let message):
            return message
        case .unknownArgument(let argument):
            return "Unknown argument \(argument). Use --help for usage."
        }
    }
}
