import Foundation
import SwiftUI

@MainActor
public final class Lu177DosimetryViewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusMessage = "Ready"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var result: Lu177DosimetryResult?
    @Published public private(set) var cumulativeResult: Lu177CumulativeTherapyDoseResult?

    private var task: Task<Void, Never>?

    public init() {}

    public func run(timePoints: [Lu177DosimetryTimePoint],
                    ctVolume: ImageVolume? = nil,
                    labelMap: LabelMap? = nil,
                    options: Lu177DosimetryOptions = .standard,
                    installInto viewer: ViewerViewModel? = nil) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        cumulativeResult = nil
        statusMessage = "Computing Lu-177 absorbed dose map..."

        task = Task {
            do {
                let computed = try await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                    try Lu177DosimetryEngine.createAbsorbedDoseMap(
                        timePoints: timePoints,
                        ctVolume: ctVolume,
                        labelMap: labelMap,
                        options: options
                    )
                }.value

                result = computed
                if let viewer {
                    let dose = viewer.addLoadedVolumeIfNeeded(computed.absorbedDoseMapGy).volume
                    _ = viewer.addLoadedVolumeIfNeeded(computed.timeIntegratedActivityMapBqHoursPerML)
                    if let density = computed.densityMapGPerML {
                        _ = viewer.addLoadedVolumeIfNeeded(density)
                    }
                    viewer.displayVolume(dose)
                }
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
        cumulativeResult = nil
        errorMessage = nil
        statusMessage = "Ready"
    }

    public func computeCumulativeTherapy(cycleCount: Int,
                                         installInto viewer: ViewerViewModel? = nil) {
        guard let result else {
            statusMessage = "Run dosimetry before calculating cumulative therapy dose."
            return
        }
        do {
            let cumulative = try Lu177DosimetryEngine.cumulativeTherapyDose(
                referenceResult: result,
                cycleCount: cycleCount
            )
            cumulativeResult = cumulative
            if let viewer {
                let installed = viewer.addLoadedVolumeIfNeeded(cumulative.cumulativeDoseMapGy).volume
                viewer.displayVolume(installed)
            }
            statusMessage = "Cumulative \(cycleCount)-cycle dose: mean \(String(format: "%.3g", cumulative.meanDoseGy)) Gy"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Cumulative dose failed"
        }
    }
}
