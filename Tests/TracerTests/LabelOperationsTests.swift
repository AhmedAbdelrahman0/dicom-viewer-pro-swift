import XCTest
@testable import Tracer

final class LabelOperationsTests: XCTestCase {
    func testFillHolesFillsEnclosedBackgroundOnly() {
        let map = LabelMap(parentSeriesUID: "series", depth: 1, height: 5, width: 5)
        for y in 1...3 {
            for x in 1...3 where y == 1 || y == 3 || x == 1 || x == 3 {
                map.setValue(1, z: 0, y: y, x: x)
            }
        }

        let changed = LabelOperations.fillHoles(label: map, classID: 1)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(map.value(z: 0, y: 2, x: 2), 1)
        XCTAssertEqual(map.value(z: 0, y: 0, x: 0), 0)
    }

    func testHollowKeepsOneVoxelShell() {
        let map = LabelMap(parentSeriesUID: "series", depth: 3, height: 3, width: 3)
        map.voxels = [UInt16](repeating: 1, count: 27)

        let removed = LabelOperations.hollow(label: map, classID: 1, thickness: 1)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(map.value(z: 1, y: 1, x: 1), 0)
        XCTAssertEqual(map.voxelCounts()[1], 26)
    }

    func testOpeningSmoothingRemovesIsolatedIsland() {
        let map = LabelMap(parentSeriesUID: "series", depth: 5, height: 5, width: 5)
        for z in 1...3 {
            for y in 1...3 {
                for x in 1...3 {
                    map.setValue(1, z: z, y: y, x: x)
                }
            }
        }
        map.setValue(1, z: 0, y: 0, x: 0)

        _ = LabelOperations.smooth(label: map,
                                   classID: 1,
                                   mode: .opening,
                                   iterations: 1)

        XCTAssertEqual(map.value(z: 0, y: 0, x: 0), 0)
        XCTAssertEqual(map.value(z: 2, y: 2, x: 2), 1)
    }

    func testFillBetweenSlicesInterpolatesAxialGap() {
        let map = LabelMap(parentSeriesUID: "series", depth: 3, height: 5, width: 5)
        for z in [0, 2] {
            for y in 1...3 {
                for x in 1...3 {
                    map.setValue(1, z: z, y: y, x: x)
                }
            }
        }

        let filled = LabelOperations.fillBetweenSlices(label: map,
                                                       classID: 1,
                                                       axis: 2)

        XCTAssertEqual(filled, 9)
        for y in 1...3 {
            for x in 1...3 {
                XCTAssertEqual(map.value(z: 1, y: y, x: x), 1)
            }
        }
        XCTAssertEqual(map.value(z: 1, y: 0, x: 0), 0)
    }
}
