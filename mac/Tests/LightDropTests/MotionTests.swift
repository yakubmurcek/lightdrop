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

    /// The island opens with a hint of overshoot, not a bounce.
    func testOpeningOvershootsOnlyALittle() {
        var s = Spring(32)
        s.retarget(164, at: 0, response: 0.44, damping: 0.68)
        let peak = (0...300).map { s.value(at: Double($0) / 100) }.max()!
        XCTAssertGreaterThan(peak, 164)
        XCTAssertLessThan((peak - 164) / (164 - 32), 0.08)
    }
}

final class NotchShapeTests: XCTestCase {
    /// Every look the island takes, through its ripple: the edge is a smooth run of short
    /// segments (a long straight one shows as a kink once it ripples) within its width.
    func testEdgeIsSmoothAndInside() {
        let looks: [(CGSize, CGFloat, CGFloat)] = [
            (CGSize(width: 197, height: 32), 6, 6),      // resting
            (CGSize(width: 251, height: 32), 6, 6),      // a file arriving
            (CGSize(width: 430, height: 164), 2.8, 15),  // a file over it
            (CGSize(width: 410, height: 128), 3.4, 15),  // sending
            (CGSize(width: 360, height: 90), 3.4, 11),   // received
        ]
        for (size, roundness, shoulder) in looks {
            let rect = CGRect(origin: .zero, size: size)
            for t in stride(from: 0.0, to: 2, by: 0.2) {
                let shape = NotchShape(shoulder: shoulder, roundness: roundness, bulge: 5, pull: 0.4, wobble: 4, time: t)
                let pts = shape.points(in: rect)
                for (a, b) in zip(pts, pts.dropFirst()) {
                    XCTAssertLessThan(hypot(b.x - a.x, b.y - a.y), 9, "\(size) n=\(roundness): a long straight run")
                }
                XCTAssertTrue(pts.allSatisfy { $0.x >= rect.minX - 2 && $0.x <= rect.maxX + 2 }, "\(size): out of bounds")
                XCTAssertEqual(pts.first!.y, shoulder, accuracy: 2, "the body starts where the shoulder ends")
            }
        }
    }
}
