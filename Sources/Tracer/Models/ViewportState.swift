import Foundation

public struct ViewportTransformState: Equatable, Sendable {
    public var zoom: Double
    public var panX: Double
    public var panY: Double

    public init(zoom: Double = 1.0, panX: Double = 0, panY: Double = 0) {
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
    }

    public static let identity = ViewportTransformState()

    public var isIdentity: Bool {
        abs(zoom - 1.0) < 0.0001 && abs(panX) < 0.0001 && abs(panY) < 0.0001
    }
}
