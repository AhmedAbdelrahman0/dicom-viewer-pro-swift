import Foundation
import CoreGraphics

public enum AnnotationType: String, CaseIterable {
    case distance, angle, area, ellipse, text
}

public struct Annotation: Identifiable {
    public let id = UUID()
    public var type: AnnotationType
    public var points: [CGPoint]   // in slice pixel coordinates
    public var axis: Int
    public var sliceIndex: Int
    public var value: Double?
    public var unit: String = "mm"
    public var label: String = ""

    public init(type: AnnotationType,
                points: [CGPoint] = [],
                axis: Int = 2,
                sliceIndex: Int = 0) {
        self.type = type
        self.points = points
        self.axis = axis
        self.sliceIndex = sliceIndex
    }

    public var displayText: String {
        guard let v = value else { return label }
        switch type {
        case .distance: return String(format: "%.1f mm", v)
        case .angle:    return String(format: "%.1f°", v)
        case .area, .ellipse:
            if v >= 100 { return String(format: "%.2f cm²", v / 100) }
            return String(format: "%.1f mm²", v)
        default:        return label
        }
    }

    public var minPointsRequired: Int {
        switch type {
        case .distance, .ellipse: return 2
        case .angle:              return 3
        case .area:               return 3
        case .text:               return 1
        }
    }
}
