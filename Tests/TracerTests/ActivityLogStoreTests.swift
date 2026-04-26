import XCTest
@testable import Tracer

@MainActor
final class ActivityLogStoreTests: XCTestCase {
    func testLogStoreDeduplicatesConsecutiveSourceMessagesAndCapsEntries() {
        let store = ActivityLogStore(maximumEntries: 4)

        store.log("Preparing", source: "Viewer")
        store.log("Preparing", source: "Viewer")
        store.log("Running", source: "Viewer")
        store.log("Running", source: "nnU-Net")
        store.log("Running", source: "Viewer")
        store.log("Done", source: "Viewer", level: .success)

        XCTAssertEqual(store.entries.map(\.message), ["Running", "Running", "Running", "Done"])
        XCTAssertEqual(store.entries.map(\.source), ["Viewer", "nnU-Net", "Viewer", "Viewer"])
        XCTAssertEqual(store.unreadCount, 4)

        store.markRead()
        XCTAssertEqual(store.unreadCount, 0)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testStatusLevelInference() {
        let store = ActivityLogStore()

        store.logStatus("CoreML error: model missing", source: "nnU-Net")
        store.logStatus("Warning: using fallback", source: "Viewer")
        store.logStatus("Dose map ready", source: "Dosimetry")

        XCTAssertEqual(store.entries.map(\.level), [.error, .warning, .success])
    }
}
