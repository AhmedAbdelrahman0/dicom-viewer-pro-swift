import Foundation
import SwiftUI

@MainActor
public final class Lu177DosimetryViewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusMessage = "Ready"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var result: Lu177DosimetryResult?

    private var task: Task<Void, Never>?

    public init() {}

    public func run(timePoints: [Lu177DosimetryTimePoint],
                    ctVolume: ImageVolume? = nil,
                    labelMap: LabelMap? = nil,
                    options: Lu177DosimetryOptions = .standard) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        statusMessage = "Computing Lu-177 absorbed dose map..."

        task = Task {
            do {
                let computed = try await Task.detached(priority: .userInitiated) {
                    try Lu177DosimetryEngine.createAbsorbedDoseMap(
                        timePoints: timePoints,
                        ctVolume: ctVolume,
                        labelMap: labelMap,
                        options: options
                    )
                }.value

                result = computed
                statusMessage = "Dose map ready: mean \(String(format: "%.3g", computed.report.meanDoseGy)) Gy, max \(String(format: "%.3g", computed.report.maxDoseGy)) Gy"
            } catch is CancellationError {
                statusMessage = "Dosimetry cancelled"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Dosimetry failed"
            }
            isRunning = false
            task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        statusMessage = "Dosimetry cancelled"
    }

    public func clear() {
        guard !isRunning else { return }
        result = nil
        errorMessage = nil
        statusMessage = "Ready"
    }
}
