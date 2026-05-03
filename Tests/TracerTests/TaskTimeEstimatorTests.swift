import XCTest
@testable import Tracer

final class TaskTimeEstimatorTests: XCTestCase {
    func testMeasuredProgressPredictsRemainingTime() {
        let start = Date(timeIntervalSince1970: 100)
        let now = start.addingTimeInterval(30)

        let estimate = TaskTimeEstimator.estimate(kind: .nnunet,
                                                  progress: 0.25,
                                                  startedAt: start,
                                                  now: now)

        XCTAssertEqual(estimate.source, .measuredProgress)
        XCTAssertEqual(estimate.displayProgress ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(estimate.estimatedTotal ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(estimate.estimatedRemaining ?? 0, 90, accuracy: 1e-9)
        XCTAssertTrue(estimate.summaryLabel.contains("1m 30s left"))
    }

    func testFallbackPredictionProvidesProgressForIndeterminateTasks() {
        let start = Date(timeIntervalSince1970: 100)
        let now = start.addingTimeInterval(60)

        let estimate = TaskTimeEstimator.estimate(kind: .petAC,
                                                  progress: nil,
                                                  startedAt: start,
                                                  now: now)

        XCTAssertEqual(estimate.source, .predictedFromTaskKind)
        XCTAssertNotNil(estimate.displayProgress)
        XCTAssertGreaterThan(estimate.displayProgress ?? 0, 0)
        XCTAssertTrue(estimate.summaryLabel.contains("expected 1m-10m"))
    }

    func testDurationLabelsStayCompact() {
        XCTAssertEqual(TaskTimeEstimator.durationLabel(9.4), "9s")
        XCTAssertEqual(TaskTimeEstimator.durationLabel(60), "1m")
        XCTAssertEqual(TaskTimeEstimator.durationLabel(125), "2m 5s")
        XCTAssertEqual(TaskTimeEstimator.durationLabel(3_600), "1h")
        XCTAssertEqual(TaskTimeEstimator.durationLabel(3_900), "1h 5m")
    }
}
