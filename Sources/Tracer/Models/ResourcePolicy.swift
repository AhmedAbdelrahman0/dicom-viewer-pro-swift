import Foundation
#if canImport(Metal)
import Metal
#endif

/// Operator-controlled resource limits for work that can otherwise swamp the
/// workstation. The defaults keep a couple of cores and a modest memory slice
/// free for SwiftUI/Metal so the viewer remains interactive during batch work.
public struct ResourcePolicy: Equatable, Sendable {
    public enum Profile: String, CaseIterable, Identifiable, Sendable {
        case interactive
        case balanced
        case throughput
        case custom

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .interactive: return "Interactive"
            case .balanced: return "Balanced"
            case .throughput: return "Throughput"
            case .custom: return "Custom"
            }
        }

        public var description: String {
            switch self {
            case .interactive:
                return "Keeps more CPU/GPU headroom for scrolling, drawing, and window changes."
            case .balanced:
                return "Good default for reading studies while background tasks run."
            case .throughput:
                return "Uses more workers for indexing and batch jobs; best when the workstation can be dedicated to processing."
            case .custom:
                return "Uses the manual CPU, GPU, cache, and memory limits below."
            }
        }
    }

    public enum Keys {
        public static let profile = "Tracer.Prefs.Resources.Profile"
        public static let cpuWorkerLimit = "Tracer.Prefs.Resources.CPUWorkerLimit"
        public static let indexingWorkerLimit = "Tracer.Prefs.Resources.IndexingWorkerLimit"
        public static let cohortWorkerLimit = "Tracer.Prefs.Resources.CohortWorkerLimit"
        public static let gpuWorkerLimit = "Tracer.Prefs.Resources.GPUWorkerLimit"
        public static let mipWorkerLimit = "Tracer.Prefs.Resources.MIPWorkerLimit"
        public static let memoryBudgetGB = "Tracer.Prefs.Resources.MemoryBudgetGB"
        public static let undoHistoryBudgetMB = "Tracer.Prefs.Resources.UndoHistoryBudgetMB"
        public static let sliceCacheEntries = "Tracer.Prefs.Resources.SliceCacheEntries"
        public static let petMIPCacheEntries = "Tracer.Prefs.Resources.PETMIPCacheEntries"
        public static let volumeRenderTextureMaxDimension = "Tracer.Prefs.Resources.VolumeRenderTextureMaxDimension"
        public static let volumeRenderSampleLimit = "Tracer.Prefs.Resources.VolumeRenderSampleLimit"
        public static let preferResponsiveBackgroundPriority = "Tracer.Prefs.Resources.PreferResponsiveBackgroundPriority"
    }

    public var profile: Profile
    public var cpuWorkerLimit: Int
    public var indexingWorkerLimit: Int
    public var cohortWorkerLimit: Int
    public var gpuWorkerLimit: Int
    public var mipWorkerLimit: Int
    public var memoryBudgetGB: Double
    public var undoHistoryBudgetMB: Int
    public var sliceCacheEntries: Int
    public var petMIPCacheEntries: Int
    public var volumeRenderTextureMaxDimension: Int
    public var volumeRenderSampleLimit: Int
    public var preferResponsiveBackgroundPriority: Bool

    public init(profile: Profile,
                cpuWorkerLimit: Int,
                indexingWorkerLimit: Int,
                cohortWorkerLimit: Int,
                gpuWorkerLimit: Int,
                mipWorkerLimit: Int,
                memoryBudgetGB: Double,
                undoHistoryBudgetMB: Int,
                sliceCacheEntries: Int,
                petMIPCacheEntries: Int,
                volumeRenderTextureMaxDimension: Int,
                volumeRenderSampleLimit: Int,
                preferResponsiveBackgroundPriority: Bool) {
        self.profile = profile
        self.cpuWorkerLimit = Self.clampWorkers(cpuWorkerLimit)
        self.indexingWorkerLimit = Self.clampWorkers(indexingWorkerLimit)
        self.cohortWorkerLimit = Self.clampWorkers(cohortWorkerLimit)
        self.gpuWorkerLimit = max(1, min(8, gpuWorkerLimit))
        self.mipWorkerLimit = max(1, min(8, mipWorkerLimit))
        let clampedMemoryBudgetGB = max(1, min(512, memoryBudgetGB))
        self.memoryBudgetGB = clampedMemoryBudgetGB
        let memoryBudgetMB = max(64, Int((clampedMemoryBudgetGB * 1024).rounded(.down)))
        self.undoHistoryBudgetMB = max(64, min(4096, undoHistoryBudgetMB, max(64, memoryBudgetMB / 4)))
        self.sliceCacheEntries = max(12, min(512, sliceCacheEntries))
        self.petMIPCacheEntries = max(2, min(64, petMIPCacheEntries))
        let textureBudgetBytes = max(64.0 * 1024.0 * 1024.0,
                                     clampedMemoryBudgetGB * 1_073_741_824.0 * 0.20)
        let textureDimensionBudget = Int(pow(textureBudgetBytes / Double(MemoryLayout<Float>.stride), 1.0 / 3.0).rounded(.down))
        self.volumeRenderTextureMaxDimension = max(96, min(1024, volumeRenderTextureMaxDimension, max(96, textureDimensionBudget)))
        self.volumeRenderSampleLimit = max(64, min(1024, volumeRenderSampleLimit))
        self.preferResponsiveBackgroundPriority = preferResponsiveBackgroundPriority
    }

    public static var activeProcessorCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    public static var processorCount: Int {
        max(1, ProcessInfo.processInfo.processorCount)
    }

    public static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    public static var interactivePreset: ResourcePolicy {
        let cpu = max(1, min(4, activeProcessorCount - 2))
        return ResourcePolicy(
            profile: .interactive,
            cpuWorkerLimit: cpu,
            indexingWorkerLimit: max(1, min(3, cpu)),
            cohortWorkerLimit: 1,
            gpuWorkerLimit: 1,
            mipWorkerLimit: 1,
            memoryBudgetGB: max(2, min(physicalMemoryGB * 0.35, 12)),
            undoHistoryBudgetMB: 128,
            sliceCacheEntries: 48,
            petMIPCacheEntries: 6,
            volumeRenderTextureMaxDimension: 256,
            volumeRenderSampleLimit: 192,
            preferResponsiveBackgroundPriority: true
        )
    }

    public static var balancedPreset: ResourcePolicy {
        let cpu = max(2, min(8, activeProcessorCount - 1))
        return ResourcePolicy(
            profile: .balanced,
            cpuWorkerLimit: cpu,
            indexingWorkerLimit: max(2, min(6, cpu)),
            cohortWorkerLimit: max(1, min(2, cpu)),
            gpuWorkerLimit: 1,
            mipWorkerLimit: 2,
            memoryBudgetGB: max(4, min(physicalMemoryGB * 0.55, 32)),
            undoHistoryBudgetMB: 256,
            sliceCacheEntries: 96,
            petMIPCacheEntries: 12,
            volumeRenderTextureMaxDimension: 384,
            volumeRenderSampleLimit: 384,
            preferResponsiveBackgroundPriority: true
        )
    }

    public static var throughputPreset: ResourcePolicy {
        let cpu = max(2, min(16, activeProcessorCount))
        return ResourcePolicy(
            profile: .throughput,
            cpuWorkerLimit: cpu,
            indexingWorkerLimit: max(2, min(12, cpu)),
            cohortWorkerLimit: max(2, min(6, cpu)),
            gpuWorkerLimit: 1,
            mipWorkerLimit: 3,
            memoryBudgetGB: max(6, min(physicalMemoryGB * 0.75, 64)),
            undoHistoryBudgetMB: 384,
            sliceCacheEntries: 160,
            petMIPCacheEntries: 18,
            volumeRenderTextureMaxDimension: 512,
            volumeRenderSampleLimit: 576,
            preferResponsiveBackgroundPriority: false
        )
    }

    public static func preset(_ profile: Profile) -> ResourcePolicy {
        switch profile {
        case .interactive: return interactivePreset
        case .balanced: return balancedPreset
        case .throughput: return throughputPreset
        case .custom: return balancedPreset.withProfile(.custom)
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> ResourcePolicy {
        let rawProfile = defaults.string(forKey: Keys.profile) ?? Profile.balanced.rawValue
        let profile = Profile(rawValue: rawProfile) ?? .balanced
        guard profile == .custom else { return preset(profile) }

        let fallback = balancedPreset
        return ResourcePolicy(
            profile: .custom,
            cpuWorkerLimit: defaults.integerOrDefault(forKey: Keys.cpuWorkerLimit, defaultValue: fallback.cpuWorkerLimit),
            indexingWorkerLimit: defaults.integerOrDefault(forKey: Keys.indexingWorkerLimit, defaultValue: fallback.indexingWorkerLimit),
            cohortWorkerLimit: defaults.integerOrDefault(forKey: Keys.cohortWorkerLimit, defaultValue: fallback.cohortWorkerLimit),
            gpuWorkerLimit: defaults.integerOrDefault(forKey: Keys.gpuWorkerLimit, defaultValue: fallback.gpuWorkerLimit),
            mipWorkerLimit: defaults.integerOrDefault(forKey: Keys.mipWorkerLimit, defaultValue: fallback.mipWorkerLimit),
            memoryBudgetGB: defaults.doubleOrDefault(forKey: Keys.memoryBudgetGB, defaultValue: fallback.memoryBudgetGB),
            undoHistoryBudgetMB: defaults.integerOrDefault(forKey: Keys.undoHistoryBudgetMB, defaultValue: fallback.undoHistoryBudgetMB),
            sliceCacheEntries: defaults.integerOrDefault(forKey: Keys.sliceCacheEntries, defaultValue: fallback.sliceCacheEntries),
            petMIPCacheEntries: defaults.integerOrDefault(forKey: Keys.petMIPCacheEntries, defaultValue: fallback.petMIPCacheEntries),
            volumeRenderTextureMaxDimension: defaults.integerOrDefault(forKey: Keys.volumeRenderTextureMaxDimension, defaultValue: fallback.volumeRenderTextureMaxDimension),
            volumeRenderSampleLimit: defaults.integerOrDefault(forKey: Keys.volumeRenderSampleLimit, defaultValue: fallback.volumeRenderSampleLimit),
            preferResponsiveBackgroundPriority: defaults.boolOrDefault(forKey: Keys.preferResponsiveBackgroundPriority, defaultValue: fallback.preferResponsiveBackgroundPriority)
        )
    }

    public func saveManualValues(to defaults: UserDefaults = .standard) {
        defaults.set(profile.rawValue, forKey: Keys.profile)
        defaults.set(cpuWorkerLimit, forKey: Keys.cpuWorkerLimit)
        defaults.set(indexingWorkerLimit, forKey: Keys.indexingWorkerLimit)
        defaults.set(cohortWorkerLimit, forKey: Keys.cohortWorkerLimit)
        defaults.set(gpuWorkerLimit, forKey: Keys.gpuWorkerLimit)
        defaults.set(mipWorkerLimit, forKey: Keys.mipWorkerLimit)
        defaults.set(memoryBudgetGB, forKey: Keys.memoryBudgetGB)
        defaults.set(undoHistoryBudgetMB, forKey: Keys.undoHistoryBudgetMB)
        defaults.set(sliceCacheEntries, forKey: Keys.sliceCacheEntries)
        defaults.set(petMIPCacheEntries, forKey: Keys.petMIPCacheEntries)
        defaults.set(volumeRenderTextureMaxDimension, forKey: Keys.volumeRenderTextureMaxDimension)
        defaults.set(volumeRenderSampleLimit, forKey: Keys.volumeRenderSampleLimit)
        defaults.set(preferResponsiveBackgroundPriority, forKey: Keys.preferResponsiveBackgroundPriority)
    }

    public var undoHistoryBudgetBytes: Int {
        undoHistoryBudgetMB * 1024 * 1024
    }

    public func boundedCPUWorkers(requested: Int) -> Int {
        min(Self.clampWorkers(requested), cpuWorkerLimit)
    }

    public func boundedIndexingWorkers(requested: Int) -> Int {
        min(Self.clampWorkers(requested), indexingWorkerLimit)
    }

    public func boundedCohortWorkers(requested: Int) -> Int {
        min(Self.clampWorkers(requested), cohortWorkerLimit)
    }

    public func boundedVolumeSamples(_ requested: Int) -> Int {
        max(32, min(requested, volumeRenderSampleLimit))
    }

    public func boundedVolumeTextureDimension(_ requested: Int) -> Int {
        max(96, min(requested, volumeRenderTextureMaxDimension))
    }

    public func applyingSubprocessDefaults(to environment: [String: String]) -> [String: String] {
        var env = environment
        let threads = "\(max(1, cpuWorkerLimit))"
        for key in ["OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"] {
            if env[key]?.isEmpty ?? true {
                env[key] = threads
            }
        }
        if env["PYTORCH_ENABLE_MPS_FALLBACK"]?.isEmpty ?? true {
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        }
        return env
    }

    public var backgroundTaskPriority: TaskPriority {
        preferResponsiveBackgroundPriority ? .utility : .userInitiated
    }

    private func withProfile(_ profile: Profile) -> ResourcePolicy {
        var copy = self
        copy.profile = profile
        return copy
    }

    private static func clampWorkers(_ value: Int) -> Int {
        max(1, min(64, value))
    }
}

public struct ResourceSystemSnapshot: Equatable, Sendable {
    public var processorCount: Int
    public var activeProcessorCount: Int
    public var physicalMemoryBytes: UInt64
    public var lowPowerModeEnabled: Bool
    public var thermalStateDescription: String
    public var gpuName: String?
    public var gpuRecommendedWorkingSetBytes: UInt64?

    public static func current() -> ResourceSystemSnapshot {
        #if canImport(Metal)
        let device = MTLCreateSystemDefaultDevice()
        let gpuName = device?.name
        let gpuWorkingSet = device?.recommendedMaxWorkingSetSize
        #else
        let gpuName: String? = nil
        let gpuWorkingSet: UInt64? = nil
        #endif

        return ResourceSystemSnapshot(
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalStateDescription: ProcessInfo.processInfo.thermalState.tracerDescription,
            gpuName: gpuName,
            gpuRecommendedWorkingSetBytes: gpuWorkingSet
        )
    }
}

private extension ProcessInfo.ThermalState {
    var tracerDescription: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

private extension UserDefaults {
    func integerOrDefault(forKey key: String, defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }

    func doubleOrDefault(forKey key: String, defaultValue: Double) -> Double {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }

    func boolOrDefault(forKey key: String, defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
