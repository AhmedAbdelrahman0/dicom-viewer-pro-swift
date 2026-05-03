import XCTest
@testable import Tracer

final class GAAINReferencePipelineTests: XCTestCase {
    func testRemoteConfigurationDefaultsToWorkdirScopedDataImportPath() {
        let config = DGXSparkConfig(host: "remote.local",
                                    user: "tester",
                                    remoteWorkdir: "~/tracer-remote",
                                    enabled: true)
        let remote = RemoteGAAINReferenceBuilder.Configuration(dgx: config)

        XCTAssertEqual(remote.remoteDataRoot, "~/tracer-remote/gaain-centiloid-data")
        XCTAssertEqual(remote.timeoutSeconds, 24 * 60 * 60)
        XCTAssertTrue(remote.uploadArchivesIfMissing)
        XCTAssertFalse(remote.removeRemoteScratch)
    }

    func testDiscoversDownloadedGAAINManifestAndWritesBuildPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaain-pipeline-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaain-package-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let rows: [(String, Int)] = [
            ("Avid_VOIs.zip", 3),
            ("Florbetapir_Young_Control_florbetapir.zip", 4),
            ("FBBproject_E-25_FBB_90110.zip", 5),
            ("GE_AD_F18_NIFTI.7z", 6),
            ("NAVProject_YC-10_NAV_5070.zip", 7),
            ("AD-100_MR.zip", 8)
        ]
        var manifest = "filename\turl\tstatus\tcontent_length\tcontent_type\tlast_modified\n"
        for (filename, size) in rows {
            manifest += "\(filename)\thttps://example.test/\(filename)\t200\t\(size)\tapplication/octet-stream\tMon, 01 Jan 2024 00:00:00 GMT\n"
            try Data(repeating: 0x2A, count: size).write(to: root.appendingPathComponent(filename))
        }
        try Data(manifest.utf8).write(to: root.appendingPathComponent("download_manifest.tsv"))

        let summary = try GAAINReferencePipeline.discover(root: root, now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(summary.files.count, rows.count)
        XCTAssertEqual(summary.completeFileCount, rows.count)
        XCTAssertTrue(summary.tracerSummaries.contains { $0.tracer == .florbetapir && $0.completeFileCount == 1 })
        XCTAssertTrue(summary.tracerSummaries.contains { $0.tracer == .florbetaben && $0.completeFileCount == 1 })
        XCTAssertTrue(summary.tracerSummaries.contains { $0.tracer == .flutemetamol && $0.completeFileCount == 1 })
        XCTAssertTrue(summary.tracerSummaries.contains { $0.tracer == .nav4694 && $0.completeFileCount == 1 })

        let plan = try GAAINReferencePipeline.makeBuildPlan(summary: summary, outputRoot: packageRoot)
        XCTAssertTrue(plan.jobs.contains { $0.tracer == .florbetapir })
        XCTAssertTrue(plan.jobs.contains { $0.tracer == .florbetaben })
        XCTAssertTrue(plan.jobs.contains { $0.tracer == .flutemetamol })
        XCTAssertTrue(plan.jobs.contains { $0.tracer == .nav4694 })
        XCTAssertFalse(plan.jobs.contains { $0.tracer == .mri })
        XCTAssertTrue(plan.notes.contains { $0.contains("user-downloaded GAAIN") })
        XCTAssertTrue(plan.notes.contains { $0.contains("does not bundle GAAIN data") })

        let package = try GAAINReferencePipeline.writeBuildPackage(root: root, packageRoot: packageRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.planURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.workerScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.runScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.readmeURL.path))

        let script = try String(contentsOf: package.workerScriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("nibabel"))
        XCTAssertTrue(script.contains("normal_database_"))
        let readme = try String(contentsOf: package.readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains("GAAIN Centiloid Data Import Package"))
        XCTAssertTrue(readme.contains("Tracer does not bundle GAAIN data"))
    }

    func testBuildPackageScriptsUseDataImportNamingAndNoBundledDataPromise() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaain-script-copy-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaain-script-package-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let filename = "Florbetapir_Young_Control_florbetapir.zip"
        let manifest = """
        filename\turl\tstatus\tcontent_length\tcontent_type\tlast_modified
        \(filename)\thttps://example.test/\(filename)\t200\t4\tapplication/octet-stream\tMon, 01 Jan 2024 00:00:00 GMT
        """
        try Data(repeating: 0x2A, count: 4).write(to: root.appendingPathComponent(filename))
        try Data(manifest.utf8).write(to: root.appendingPathComponent("download_manifest.tsv"))

        let package = try GAAINReferencePipeline.writeBuildPackage(root: root, packageRoot: packageRoot)
        let readme = try String(contentsOf: package.readmeURL, encoding: .utf8)
        let runScript = try String(contentsOf: package.runScriptURL, encoding: .utf8)
        let plan = try String(contentsOf: package.planURL, encoding: .utf8)

        XCTAssertTrue(readme.contains("Data Import Package"))
        XCTAssertTrue(readme.contains("does not bundle GAAIN data"))
        XCTAssertTrue(runScript.contains("gaain_reference_build.py"))
        XCTAssertTrue(plan.contains("user-downloaded GAAIN"))
        XCTAssertFalse(readme.contains("reference " + "builder"))
        XCTAssertFalse(readme.contains("Spark " + "archive"))
        XCTAssertFalse(runScript.contains("Spark " + "Job"))
        XCTAssertFalse(plan.contains("Spark " + "Dataset"))
    }

    func testRemotePlanRewritesRemotePathsAndShellPathExpandsTilde() throws {
        let plan = GAAINReferenceBuildPlan(
            id: "plan",
            createdAt: Date(timeIntervalSince1970: 1),
            sourceRoot: "/local/source",
            outputRoot: "/local/output",
            fileCount: 1,
            totalBytes: 10,
            jobs: [],
            notes: ["local"]
        )

        let remote = GAAINReferencePipeline.remoteExecutionPlan(
            from: plan,
            sourceRoot: "~/tracer-remote/gaain-data",
            outputRoot: "~/tracer-remote/gaain-out"
        )

        XCTAssertEqual(remote.sourceRoot, "~/tracer-remote/gaain-data")
        XCTAssertEqual(remote.outputRoot, "~/tracer-remote/gaain-out")
        XCTAssertTrue(remote.notes.contains { $0.contains("Remote execution") })
        XCTAssertEqual(RemoteExecutor.shellPath("~/tracer remote"), "$HOME/'tracer remote'")
        XCTAssertEqual(RemoteExecutor.shellPath("/tmp/a b"), "'/tmp/a b'")
    }
}
