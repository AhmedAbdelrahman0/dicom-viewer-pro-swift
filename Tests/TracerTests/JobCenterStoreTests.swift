import XCTest
@testable import Tracer

@MainActor
final class JobCenterStoreTests: XCTestCase {
    func testSyncCreatesUpdatesAndCompletesJobRecords() {
        let store = JobCenterStore(maximumRecords: 20)
        let start = Date(timeIntervalSince1970: 100)

        store.sync(active: [
            JobUpdate(operationID: "nnunet",
                      kind: .nnunet,
                      title: "nnU-Net",
                      stage: "Local",
                      detail: "Preparing",
                      progress: nil,
                      systemImage: "brain",
                      canCancel: true)
        ], now: start)

        XCTAssertEqual(store.activeRecords.count, 1)
        XCTAssertEqual(store.records.first?.state, .running)
        XCTAssertEqual(store.metrics.started, 1)

        store.sync(active: [
            JobUpdate(operationID: "nnunet",
                      kind: .nnunet,
                      title: "nnU-Net",
                      stage: "Local",
                      detail: "Predicting",
                      progress: 0.4,
                      systemImage: "brain",
                      canCancel: true)
        ], now: start.addingTimeInterval(4))

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.detail, "Predicting")
        XCTAssertEqual(store.records.first?.progress, 0.4)
        store.heartbeat(operationID: "nnunet",
                        detail: "Still predicting",
                        progress: 0.6,
                        now: start.addingTimeInterval(6))
        XCTAssertEqual(store.metrics.heartbeats, 1)
        XCTAssertEqual(store.records.first?.heartbeatCount, 1)

        store.sync(active: [], now: start.addingTimeInterval(8))

        XCTAssertEqual(store.activeRecords.count, 0)
        XCTAssertEqual(store.records.first?.state, .succeeded)
        XCTAssertEqual(store.records.first?.progress, 1)
        XCTAssertEqual(store.metrics.succeeded, 1)
    }

    func testRepeatedOperationCreatesSeparateHistoryRecords() {
        let store = JobCenterStore(maximumRecords: 20)
        let start = Date(timeIntervalSince1970: 100)
        let update = JobUpdate(operationID: "viewer-loading",
                               kind: .studyLoading,
                               title: "Loading study",
                               stage: "Import",
                               detail: "Loading",
                               systemImage: "square.and.arrow.down")

        store.sync(active: [update], now: start)
        store.sync(active: [], now: start.addingTimeInterval(1))
        store.sync(active: [update], now: start.addingTimeInterval(2))

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.activeRecords.count, 1)
        XCTAssertNotEqual(store.records[0].id, store.records[1].id)
    }

    func testCancellationRequestBecomesCancelledWhenOperationStops() throws {
        let store = JobCenterStore(maximumRecords: 20)
        let start = Date(timeIntervalSince1970: 100)
        store.sync(active: [
            JobUpdate(operationID: "cohort",
                      kind: .cohort,
                      title: "Cohort",
                      stage: "Running",
                      detail: "10/200 studies",
                      progress: 0.05,
                      systemImage: "rectangle.stack.badge.play",
                      canCancel: true)
        ], now: start)

        let id = try XCTUnwrap(store.activeRecords.first?.id)
        store.markCancellationRequested(recordID: id, now: start.addingTimeInterval(2))
        store.sync(active: [], now: start.addingTimeInterval(3))

        XCTAssertEqual(store.records.first?.state, .cancelled)
        XCTAssertEqual(store.unreadIssueCount, 1)
    }

    func testFailureIsInferredFromLastDetailWhenJobDisappears() {
        let store = JobCenterStore(maximumRecords: 20)
        let start = Date(timeIntervalSince1970: 100)

        store.sync(active: [
            JobUpdate(operationID: "pet-ac",
                      kind: .petAC,
                      title: "PET AC",
                      stage: "Correction",
                      detail: "AC failed: model unavailable",
                      systemImage: "wand.and.stars")
        ], now: start)
        store.sync(active: [], now: start.addingTimeInterval(1))

        XCTAssertEqual(store.records.first?.state, .failed)
        XCTAssertEqual(store.unreadIssueCount, 1)
    }

    func testExplicitTerminalCompletionOverridesSuccessInference() {
        let store = JobCenterStore(maximumRecords: 20)
        let start = Date(timeIntervalSince1970: 100)

        store.sync(active: [
            JobUpdate(operationID: "download-model",
                      kind: .modelDownload,
                      title: "Model download",
                      stage: "AutoPET",
                      detail: "2 MB / 10 MB",
                      progress: 0.2,
                      systemImage: "arrow.down.circle",
                      canCancel: true)
        ], now: start)

        store.complete(operationID: "download-model",
                       state: .failed,
                       detail: "AutoPET download failed: checksum mismatch",
                       error: JobErrorInfo(code: "checksum_mismatch",
                                           message: "checksum mismatch",
                                           recoverySuggestion: "Delete the partial artifact and retry.",
                                           isRetryable: true),
                       now: start.addingTimeInterval(5))
        store.sync(active: [], now: start.addingTimeInterval(6))

        XCTAssertEqual(store.records.first?.state, .failed)
        XCTAssertEqual(store.records.first?.detail, "AutoPET download failed: checksum mismatch")
        XCTAssertEqual(store.records.first?.structuredError?.code, "checksum_mismatch")
        XCTAssertEqual(store.unreadIssueCount, 1)
    }
}
