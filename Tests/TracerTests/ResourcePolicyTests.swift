import XCTest
@testable import Tracer

final class ResourcePolicyTests: XCTestCase {
    func testCustomPolicyClampsUnsafeValuesAndSetsThreadEnvironment() {
        let policy = ResourcePolicy(
            profile: .custom,
            cpuWorkerLimit: 999,
            indexingWorkerLimit: 999,
            cohortWorkerLimit: 999,
            gpuWorkerLimit: 99,
            mipWorkerLimit: 99,
            memoryBudgetGB: 999,
            undoHistoryBudgetMB: 1,
            sliceCacheEntries: 1,
            petMIPCacheEntries: 1,
            volumeRenderTextureMaxDimension: 10_000,
            volumeRenderSampleLimit: 10_000,
            preferResponsiveBackgroundPriority: true
        )

        XCTAssertEqual(policy.cpuWorkerLimit, 64)
        XCTAssertEqual(policy.indexingWorkerLimit, 64)
        XCTAssertEqual(policy.cohortWorkerLimit, 64)
        XCTAssertEqual(policy.gpuWorkerLimit, 8)
        XCTAssertEqual(policy.mipWorkerLimit, 8)
        XCTAssertEqual(policy.undoHistoryBudgetMB, 64)
        XCTAssertEqual(policy.sliceCacheEntries, 12)
        XCTAssertEqual(policy.petMIPCacheEntries, 2)
        XCTAssertEqual(policy.volumeRenderTextureMaxDimension, 1024)
        XCTAssertEqual(policy.volumeRenderSampleLimit, 1024)

        let env = policy.applyingSubprocessDefaults(to: [:])
        XCTAssertEqual(env["OMP_NUM_THREADS"], "64")
        XCTAssertEqual(env["OPENBLAS_NUM_THREADS"], "64")
        XCTAssertEqual(env["PYTORCH_ENABLE_MPS_FALLBACK"], "1")

        let preserved = policy.applyingSubprocessDefaults(to: ["OMP_NUM_THREADS": "3"])
        XCTAssertEqual(preserved["OMP_NUM_THREADS"], "3")
    }

    func testResourcePolicyLoadsCustomValuesFromDefaults() throws {
        let suite = "TracerTests.ResourcePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(ResourcePolicy.Profile.custom.rawValue, forKey: ResourcePolicy.Keys.profile)
        defaults.set(3, forKey: ResourcePolicy.Keys.cpuWorkerLimit)
        defaults.set(4, forKey: ResourcePolicy.Keys.indexingWorkerLimit)
        defaults.set(2, forKey: ResourcePolicy.Keys.cohortWorkerLimit)
        defaults.set(1, forKey: ResourcePolicy.Keys.gpuWorkerLimit)
        defaults.set(1, forKey: ResourcePolicy.Keys.mipWorkerLimit)
        defaults.set(9.5, forKey: ResourcePolicy.Keys.memoryBudgetGB)
        defaults.set(192, forKey: ResourcePolicy.Keys.undoHistoryBudgetMB)
        defaults.set(72, forKey: ResourcePolicy.Keys.sliceCacheEntries)
        defaults.set(7, forKey: ResourcePolicy.Keys.petMIPCacheEntries)
        defaults.set(320, forKey: ResourcePolicy.Keys.volumeRenderTextureMaxDimension)
        defaults.set(224, forKey: ResourcePolicy.Keys.volumeRenderSampleLimit)
        defaults.set(false, forKey: ResourcePolicy.Keys.preferResponsiveBackgroundPriority)

        let policy = ResourcePolicy.load(defaults: defaults)
        XCTAssertEqual(policy.profile, .custom)
        XCTAssertEqual(policy.cpuWorkerLimit, 3)
        XCTAssertEqual(policy.indexingWorkerLimit, 4)
        XCTAssertEqual(policy.cohortWorkerLimit, 2)
        XCTAssertEqual(policy.memoryBudgetGB, 9.5)
        XCTAssertEqual(policy.undoHistoryBudgetMB, 192)
        XCTAssertEqual(policy.sliceCacheEntries, 72)
        XCTAssertEqual(policy.petMIPCacheEntries, 7)
        XCTAssertEqual(policy.volumeRenderTextureMaxDimension, 320)
        XCTAssertEqual(policy.volumeRenderSampleLimit, 224)
        XCTAssertFalse(policy.preferResponsiveBackgroundPriority)

        defaults.removePersistentDomain(forName: suite)
    }
}
