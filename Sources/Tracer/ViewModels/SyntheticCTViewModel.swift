import Foundation
import SwiftUI

@MainActor
public final class SyntheticCTViewModel: ObservableObject {
    @Published public var method: SyntheticCTMethod = .researchHeuristicPETToCT
    @Published public var bodySUVThreshold: Double = 0.05
    @Published public var intenseUptakeSUV: Double = 12
    @Published public var airHU: Double = -1_000
    @Published public var softTissueHU: Double = 35
    @Published public var highUptakeHU: Double = 110
    @Published public var minimumHU: Double = -1_024
    @Published public var maximumHU: Double = 3_071
    @Published public var smoothingRadiusVoxels: Int = 1
    @Published public var seriesDescription: String = "Synthetic CT from PET"

    @Published public private(set) var isRunning = false
    @Published public private(set) var statusMessage = "Ready"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastResult: SyntheticCTResult?

    private var task: Task<Void, Never>?

    public init() {}

    public var canRunConfiguredMethod: Bool {
        method == .researchHeuristicPETToCT
    }

    public func run(viewer: ViewerViewModel) {
        guard !isRunning else { return }
        guard let petVolume = viewer.activePETQuantificationVolume else {
            statusMessage = "Load or fuse a PET volume first."
            return
        }

        let options: SyntheticCTOptions
        do {
            options = try SyntheticCTOptions(
                method: method,
                bodySUVThreshold: bodySUVThreshold,
                intenseUptakeSUV: intenseUptakeSUV,
                airHU: Float(airHU),
                softTissueHU: Float(softTissueHU),
                highUptakeHU: Float(highUptakeHU),
                minimumHU: Float(minimumHU),
                maximumHU: Float(maximumHU),
                smoothingRadiusVoxels: smoothingRadiusVoxels,
                seriesDescription: seriesDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Synthetic CT from PET"
                    : seriesDescription
            )
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Synthetic CT options invalid"
            return
        }

        isRunning = true
        errorMessage = nil
        statusMessage = "Generating synthetic CT..."
        let suvSettings = viewer.suvSettings

        task = Task { [weak self, petVolume, suvSettings, options, viewer] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SyntheticCTGenerator.generate(
                        from: petVolume,
                        suvSettings: suvSettings,
                        options: options
                    )
                }.value

                guard !Task.isCancelled else { return }
                let installed = viewer.addLoadedVolumeIfNeeded(result.volume).volume
                viewer.displayVolume(installed)
                self?.lastResult = SyntheticCTResult(volume: installed, report: result.report)
                self?.statusMessage = "Synthetic CT ready: mean \(String(format: "%.1f", result.report.meanHU)) HU"
            } catch is CancellationError {
                self?.statusMessage = "Synthetic CT cancelled"
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.statusMessage = "Synthetic CT failed"
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        statusMessage = "Synthetic CT cancelled"
    }
}
