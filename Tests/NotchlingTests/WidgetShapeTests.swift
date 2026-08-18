import AppKit
import Testing

@testable import Notchling

@Suite("WidgetShape")
struct WidgetShapeTests {
    @Test("the path stays inside its rect at every size", arguments: [
        CGSize(width: 60, height: 30),
        CGSize(width: 500, height: 400),
        CGSize(width: 20, height: 8),
    ])
    func staysInBounds(size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let path = WidgetShape(topRadius: 13, bottomRadius: 20).path(in: rect)
        let bounds = path.boundingRect
        #expect(bounds.minX >= -0.01 && bounds.minY >= -0.01)
        #expect(bounds.maxX <= size.width + 0.01)
        #expect(bounds.maxY <= size.height + 0.01)
        #expect(!path.isEmpty)
    }

    /// Radii larger than the shape fold the path inside out if they are not clamped, which renders as a
    /// black smear.
    @Test("oversized radii are clamped rather than inverting the path")
    func clampsRadii() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 10)
        let path = WidgetShape(topRadius: 200, bottomRadius: 200).path(in: rect)
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width <= 24.01)
        #expect(path.boundingRect.height <= 10.01)
    }

    @Test("a degenerate rect produces no path instead of crashing")
    func degenerate() {
        let path = WidgetShape(topRadius: 6, bottomRadius: 12).path(in: .zero)
        #expect(path.boundingRect.width == 0 || path.isEmpty)
    }

    @Test("the corners are animatable, so growing is one continuous movement")
    func animatable() {
        var shape = WidgetShape(topRadius: 6, bottomRadius: 12)
        shape.animatableData = .init(13, 20)
        #expect(shape.topRadius == 13)
        #expect(shape.bottomRadius == 20)
    }
}
