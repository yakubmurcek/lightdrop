import SwiftUI

/// A damped spring solved in closed form, so any frame can ask where it is.
/// Retargeting starts from the current position and velocity: nothing jumps.
struct Spring {
    private(set) var target: Double
    /// Offset from the target and velocity at `start` (seconds since the reference date).
    private var offset = 0.0, velocity = 0.0, start = 0.0
    private var omega = 2 * Double.pi / 0.4, damping = 1.0
    /// When it is within `tolerance` of the target and stays there.
    private(set) var settles = 0.0
    let tolerance: Double

    init(_ value: Double, tolerance: Double = 0.05) {
        target = value
        self.tolerance = tolerance
    }

    func value(at t: Double) -> Double { target + state(t).x }

    /// Heads for `to` from wherever it is at `t`. `response` is the period in seconds;
    /// `damping` 1 never passes the target, below 1 overshoots a little.
    mutating func retarget(_ to: Double, at t: Double, response: Double, damping: Double) {
        let now = state(t)
        offset = target + now.x - to
        velocity = now.v
        target = to
        start = t
        omega = 2 * .pi / max(0.05, response)
        self.damping = min(1, max(0.05, damping))
        settles = t + settleTime()
    }

    /// Straight to `value`, at rest.
    mutating func jump(_ value: Double) {
        target = value
        offset = 0
        velocity = 0
        settles = 0
    }

    private func state(_ t: Double) -> (x: Double, v: Double) {
        let tau = max(0, t - start), w = omega, z = damping
        if offset == 0 && velocity == 0 { return (0, 0) }
        if z >= 1 {
            let a = offset, b = velocity + w * a, e = exp(-w * tau)
            return ((a + b * tau) * e, (b - w * (a + b * tau)) * e)
        }
        let wd = w * (1 - z * z).squareRoot(), a = offset, b = (velocity + z * w * a) / wd
        let e = exp(-z * w * tau), c = cos(wd * tau), s = sin(wd * tau)
        return (e * (a * c + b * s), e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s))
    }

    /// Seconds until the motion's envelope is below the tolerance.
    private func settleTime() -> Double {
        let w = omega, z = damping
        if offset == 0 && velocity == 0 { return 0 }
        if z >= 1 {
            let a = abs(offset), b = abs(velocity + w * offset)
            var tau = 0.0
            for _ in 0..<8 { tau = max(0, log(max(a + b * tau, tolerance) / tolerance) / w) }
            return tau
        }
        let wd = w * (1 - z * z).squareRoot(), b = (velocity + z * w * offset) / wd
        let amp = (offset * offset + b * b).squareRoot()
        return max(0, log(max(amp, tolerance) / tolerance) / (z * w))
    }
}

/// A colour as numbers, so the rim can blend from one look to the next.
struct RGB: Equatable {
    var r, g, b: Double

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        (r, g, b) = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    func mixed(with o: RGB, _ t: Double) -> RGB {
        var m = self
        (m.r, m.g, m.b) = (r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
        return m
    }
}

/// One glowing edge: five colours going round (a turning angular gradient) and how bright.
struct RimPaint: Equatable {
    var colors: [RGB]
    var opacity: Double

    static let off = RimPaint(colors: Array(repeating: RGB(.white), count: 5), opacity: 0)
    static func solid(_ c: Color, _ opacity: Double) -> RimPaint {
        RimPaint(colors: Array(repeating: RGB(c), count: 5), opacity: opacity)
    }
    static let rainbow = Palette.glow.map(RGB.init)
    /// Blue and violet, twice round.
    static let flow: [RGB] = {
        let b = RGB(Palette.blue), v = RGB(Palette.violet), m = b.mixed(with: v, 0.5)
        return [b, m, v, m, b]
    }()
}

/// A rim layer on its way from one paint to another: the colours cross-fade, the
/// brightness follows a spring. A layer that is out of sight takes new colours at once.
struct RimLayer {
    private var from = RimPaint.off.colors, to = RimPaint.off.colors, start = 0.0
    var opacity = Spring(0, tolerance: 0.004)
    static let fade = 0.35

    mutating func retarget(_ paint: RimPaint, at t: Double) {
        if paint.colors != to {
            from = opacity.value(at: t) < 0.03 ? paint.colors : colors(at: t)
            to = paint.colors
            start = t
        }
        if paint.opacity != opacity.target {
            opacity.retarget(paint.opacity, at: t, response: 0.32, damping: 1)
        }
    }

    mutating func jump(_ paint: RimPaint) {
        (from, to) = (paint.colors, paint.colors)
        opacity.jump(paint.opacity)
    }

    func colors(at t: Double) -> [RGB] {
        let p = min(1, max(0, (t - start) / Self.fade)), e = p * p * (3 - 2 * p)
        return zip(from, to).map { $0.mixed(with: $1, e) }
    }

    func paint(at t: Double) -> RimPaint { RimPaint(colors: colors(at: t), opacity: max(0, opacity.value(at: t))) }
    var settles: Double { max(start + Self.fade, opacity.settles) }
}

/// Where the island is headed: its size, outline and glow for what's happening now.
struct Look: Equatable {
    var size: CGSize
    var shoulder: CGFloat
    var roundness: CGFloat
    var bulge: CGFloat
    /// Shadow strength, 0 … 1.
    var shade: CGFloat
    /// The full edge, and the edge traced as far as the progress.
    var outline: RimPaint
    var trace: RimPaint
}

/// The island's moving parts, each on its own spring, read per frame by everything that
/// draws (the body, the rim and the mask over the content), so they never disagree.
@MainActor
final class Motion {
    var w = Spring(0), h = Spring(0)
    var shoulder = Spring(6), roundness = Spring(6, tolerance: 0.005), bulge = Spring(0), shade = Spring(0, tolerance: 0.005)
    var pull = Spring(0, tolerance: 0.002)
    var progress = Spring(0, tolerance: 0.001)
    var outline = RimLayer(), trace = RimLayer()
    private(set) var look: Look?
    /// The last frame drawn: changes start from there, so a retarget never steps back in time.
    var lastFrame = 0.0

    var clock: Double { max(Date().timeIntervalSinceReferenceDate, lastFrame) }

    /// Every part at rest from here on.
    var settles: Double {
        [w.settles, h.settles, shoulder.settles, roundness.settles, bulge.settles, shade.settles,
         pull.settles, progress.settles, outline.settles, trace.settles].max() ?? 0
    }

    enum Pace {
        /// Following the cursor in.
        case track
        /// Opening for a drop or a send: lively, a hint of overshoot.
        case open
        /// A file arriving: calm, never bouncy.
        case calm
    }

    func jump(to look: Look) {
        self.look = look
        w.jump(look.size.width)
        h.jump(look.size.height)
        shoulder.jump(look.shoulder)
        roundness.jump(look.roundness)
        bulge.jump(look.bulge)
        shade.jump(look.shade)
        outline.jump(look.outline)
        trace.jump(look.trace)
    }

    /// Heads for `look`. Growing uses `pace`; shrinking always settles without passing
    /// the target, so the island never dips inside the notch on its way closed.
    func retarget(to look: Look, pace: Pace) {
        guard self.look != nil else { return jump(to: look) }
        let t = clock
        self.look = look
        func go(_ s: inout Spring, _ to: CGFloat, grow: (Double, Double), shrink: (Double, Double)) {
            guard Double(to) != s.target else { return }
            let (r, d) = Double(to) > s.value(at: t) ? grow : shrink
            s.retarget(Double(to), at: t, response: r, damping: d)
        }
        switch pace {
        case .track:
            go(&w, look.size.width, grow: (0.3, 0.82), shrink: (0.3, 1))
            go(&h, look.size.height, grow: (0.26, 0.8), shrink: (0.26, 1))
        case .open:
            go(&w, look.size.width, grow: (0.52, 0.72), shrink: (0.44, 1))
            go(&h, look.size.height, grow: (0.44, 0.68), shrink: (0.38, 1))
        case .calm:
            go(&w, look.size.width, grow: (0.5, 0.9), shrink: (0.46, 1))
            go(&h, look.size.height, grow: (0.46, 0.9), shrink: (0.42, 1))
        }
        let shape = pace == .track ? (0.28, 1.0) : (0.42, 1.0)
        go(&shoulder, look.shoulder, grow: shape, shrink: shape)
        go(&roundness, look.roundness, grow: shape, shrink: shape)
        go(&bulge, look.bulge, grow: (0.4, 0.75), shrink: (0.36, 1))
        go(&shade, look.shade, grow: (0.4, 1), shrink: (0.36, 1))
        outline.retarget(look.outline, at: t)
        trace.retarget(look.trace, at: t)
        // A trace coming into view starts from its own progress, not from where the last one ended.
        if trace.opacity.value(at: t) < 0.03 { progress.jump(progress.target) }
    }

    func follow(pull to: CGFloat) {
        pull.retarget(Double(to), at: clock, response: 0.35, damping: 0.7)
    }

    func follow(progress to: Double) {
        guard to != progress.target else { return }
        if trace.opacity.value(at: clock) < 0.03 { return progress.jump(to) }
        progress.retarget(to, at: clock, response: 0.4, damping: 1)
    }
}
