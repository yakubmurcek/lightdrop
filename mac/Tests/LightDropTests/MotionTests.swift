import XCTest
@testable import LightDrop

final class SpringTests: XCTestCase {
    func testDampingOneNeverPassesTheTarget() {
        var s = Spring(0)
        s.retarget(100, at: 0, response: 0.4, damping: 1)
        var last = 0.0
        for i in 0...200 {
            let v = s.value(at: Double(i) / 100)
            XCTAssertLessThanOrEqual(v, 100 + 1e-9)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9, "moves one way only")
            last = v
        }
        XCTAssertEqual(s.value(at: 2), 100, accuracy: 0.05)
    }

    /// A new target mid-flight: no jump in position, no jolt in speed.
    func testRetargetKeepsPositionAndVelocity() {
        var s = Spring(0)
        s.retarget(100, at: 0, response: 0.5, damping: 0.7)
        let t = 0.12, dt = 1e-5
        let before = s.value(at: t)
        let speedBefore = (s.value(at: t) - s.value(at: t - dt)) / dt
        s.retarget(40, at: t, response: 0.3, damping: 1)
        XCTAssertEqual(s.value(at: t), before, accuracy: 1e-9)
        let speedAfter = (s.value(at: t + dt) - s.value(at: t)) / dt
        XCTAssertEqual(speedAfter, speedBefore, accuracy: abs(speedBefore) * 0.01)
    }

    func testAtRestOnceItSaysSo() {
        var s = Spring(0)
        s.retarget(300, at: 10, response: 0.5, damping: 0.7)
        XCTAssertGreaterThan(s.settles, 10)
        XCTAssertLessThan(s.settles, 12)
        for i in 0..<100 { XCTAssertEqual(s.value(at: s.settles + Double(i) / 50), 300, accuracy: 0.05) }
    }

    /// The island opens with a hint of overshoot, not a bounce; it closes without any.
    func testOpeningOvershootsOnlyALittle() {
        let (r, d) = Motion.spring(.open, growing: true)
        var s = Spring(32)
        s.retarget(154, at: 0, response: r, damping: d)
        let peak = (0...300).map { s.value(at: Double($0) / 100) }.max()!
        XCTAssertGreaterThan(peak, 154)
        XCTAssertLessThan((peak - 154) / (154 - 32), 0.03)
        for pace in [Motion.Pace.track, .open, .calm] {
            XCTAssertEqual(Motion.spring(pace, growing: false).1, 1, "closing never passes the notch")
        }
        XCTAssertEqual(Motion.spring(.calm, growing: true).1, 1, "a file arriving never bounces")
    }
}

final class NotchShapeTests: XCTestCase {
    static let looks: [(CGSize, CGFloat, CGFloat)] = [
        (CGSize(width: 197, height: 32), 6, 14),     // resting
        (CGSize(width: 251, height: 32), 6, 14),     // a file arriving
        (CGSize(width: 260, height: 50), 9, 17),     // a file coming near
        (CGSize(width: 420, height: 154), 14, 24),   // a file over it
        (CGSize(width: 420, height: 128), 14, 24),   // sending
        (CGSize(width: 360, height: 90), 14, 24),    // received
        (CGSize(width: 200, height: 20), 14, 24),    // mid-way, shorter than its corners
    ]

    /// The two sides are mirror images, in every look.
    func testSymmetric() {
        for (size, top, bottom) in Self.looks {
            let rect = CGRect(origin: .zero, size: size)
            let shape = NotchShape(top: top, bottom: bottom)
            let left = shape.edge(in: rect, side: .left), right = shape.edge(in: rect, side: .right)
            for i in 1...40 {
                let f = Double(i) / 40
                let a = left.trimmedPath(from: 0, to: f).currentPoint!, b = right.trimmedPath(from: 0, to: f).currentPoint!
                XCTAssertEqual(a.x, size.width - b.x, accuracy: 0.01, "\(size)")
                XCTAssertEqual(a.y, b.y, accuracy: 0.01, "\(size)")
            }
            // Both halves end at the bottom centre.
            XCTAssertEqual(left.currentPoint!.x, size.width / 2, accuracy: 0.01)
            XCTAssertEqual(left.currentPoint!.y, size.height, accuracy: 0.01)
        }
    }

    /// Inside its frame, flat on top and bottom, and the corners never outgrow the sides
    /// (a short island is a rounded bar, not a half-circle blob).
    func testInsideAndCornersFit() {
        for (size, top, bottom) in Self.looks {
            let rect = CGRect(origin: .zero, size: size)
            let shape = NotchShape(top: top, bottom: bottom)
            let box = shape.path(in: rect).boundingRect
            XCTAssertEqual(box.minX, 0, accuracy: 0.01)
            XCTAssertEqual(box.maxX, size.width, accuracy: 0.01)
            XCTAssertEqual(box.minY, 0, accuracy: 0.01)
            XCTAssertEqual(box.maxY, size.height, accuracy: 0.01)
            let (t, b) = shape.radii(in: rect)
            XCTAssertLessThanOrEqual(t + b, size.height + 0.01)
            XCTAssertLessThanOrEqual(2 * (t + b), size.width + 0.01)
            XCTAssertEqual(t, min(top, size.height / 2), accuracy: 0.01)
        }
    }
}
