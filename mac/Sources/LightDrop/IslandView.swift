import SwiftUI
import UniformTypeIdentifiers

/// The island outline: flush with the top of the screen, small outward-curving
/// "shoulders" where it meets the menu bar, and a soft, rounded body (the lower
/// half of a superellipse: notch-like when closed, nearly a drop when open). The
/// bottom edge ripples with `wobble` and sags toward the cursor with `bulge`.
///
/// Not animatable on purpose: `Motion` moves it, frame by frame, so the body, the
/// rim and the mask over the content always draw the very same outline.
struct NotchShape: Shape {
    var shoulder: CGFloat
    /// Superellipse exponent: ~6 is the boxy notch, ~2.6 a soft drop.
    var roundness: CGFloat
    var bulge: CGFloat = 0
    /// Where the sag is, -1 (left) … 1 (right).
    var pull: CGFloat = 0
    /// Ripple height (pt) and its clock.
    var wobble: CGFloat = 0
    var time: Double = 0

    static let steps = 120

    func path(in r: CGRect) -> Path {
        let pts = points(in: r)
        let s = min(shoulder, r.width / 4, r.height / 3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: pts[0], control: CGPoint(x: r.minX + s, y: r.minY))
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }

    /// The body's edge from the left shoulder round to the right one. The superellipse
    /// is walked by angle (its polar form), which spreads the points evenly: walking
    /// it by the usual parameter leaves the flat bottom a few long straight segments,
    /// which show as a kink once the edge ripples.
    func points(in r: CGRect) -> [CGPoint] {
        let s = min(shoulder, r.width / 4, r.height / 3)
        let a = (r.width - 2 * s) / 2, cx = r.midX, h = max(r.height, 1)
        let n = Double(max(2.05, roundness))
        let px = cx + max(-1, min(1, pull)) * a * 0.55
        func radius(_ th: Double) -> Double { pow(pow(abs(cos(th)), n) + pow(abs(sin(th)), n), -1 / n) }
        func point(_ th: Double) -> CGPoint {
            let rr = radius(th)
            let ux = -rr * cos(th)          // -1 … 1 across
            let depth = rr * sin(th)        // 0 at the top, 1 at the bottom
            var x = cx + a * ux
            var y = h * depth
            let u = (ux + 1) / 2
            let ripple = sin(u * .pi * 3 + time * 3.3) + 0.55 * sin(u * .pi * 5.4 - time * 4.6)
            y += wobble * depth * depth * ripple
            x += wobble * 0.35 * depth * sin(time * 2.4 + u * 4)
            y += bulge * depth * exp(-pow((x - px) / (a * 0.38), 2))
            return CGPoint(x: x, y: r.minY + y)
        }
        // Where the shoulder hands over to the body: at depth s / h.
        var lo = 0.0, hi = Double.pi / 2
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if radius(mid) * sin(mid) < Double(s / h) { lo = mid } else { hi = mid }
        }
        return (0...Self.steps).map { point(lo + (.pi - 2 * lo) * Double($0) / Double(Self.steps)) }
    }
}

extension AnyTransition {
    /// Content swapping inside a reshaping island: the old goes quickly, before the
    /// outline cuts through it, and the new comes in as the outline gets there, so
    /// the two never sit on top of each other.
    static func content(scale: CGFloat = 0.95) -> AnyTransition {
        .asymmetric(insertion: AnyTransition.opacity.combined(with: .scale(scale: scale, anchor: .top))
                        .animation(.spring(response: 0.36, dampingFraction: 0.86).delay(0.1)),
                    removal: AnyTransition.opacity.animation(.easeOut(duration: 0.14)))
    }
}

/// Horizontal shake for a failed send.
struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(travel * .pi * 6) * (1 - travel.truncatingRemainder(dividingBy: 1)), y: 0))
    }
}

/// One drop target for the whole island; with several computers the cursor's
/// x position picks the pill (nested drop targets flicker between each other).
struct IslandDrop: DropDelegate {
    let model: NotchModel
    let width: CGFloat
    let urls: () -> [URL]
    @Binding var targeted: Bool

    func dropEntered(info: DropInfo) { targeted = true; model.hover(true); track(info) }
    func dropExited(info: DropInfo) { targeted = false; model.hover(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        // Accepted even with nobody online, so letting go says why instead of nothing.
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return model.drop(urls(), on: model.targets.count > 1 ? model.hovered : nil)
    }

    private func track(_ info: DropInfo) {
        model.hoverMoved((info.location.x - width / 2) / (width / 2))
        let n = model.targets.count
        guard n > 1 else { return }
        let total = CGFloat(n) * DevicePill.width + CGFloat(n - 1) * DevicePill.spacing
        let i = Int(((info.location.x - (width - total) / 2) / (DevicePill.width + DevicePill.spacing)).rounded(.down))
        let peer = (0..<n).contains(i) ? model.targets[i] : nil
        if peer != model.hovered {
            if peer != nil { Haptics.tap() }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { model.hovered = peer }
        }
    }
}

enum Palette {
    static let blue = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let violet = Color(red: 0.66, green: 0.45, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.42, blue: 0.70)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.36)
    static let green = Color(red: 0.32, green: 0.86, blue: 0.52)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let glow: [Color] = [blue, violet, pink, amber, blue]
}

struct IslandView: View {
    @ObservedObject var model: NotchModel
    let urls: () -> [URL]
    @State private var targeted = false
    /// The drawn outline, per frame: width and height chase `size` on different
    /// springs, so the island squashes and stretches like jelly.
    @State private var motion = Motion()
    /// Bumped to look again at whether everything has come to rest.
    @State private var wake = 0

    private var notch: CGSize { model.notchSize }

    /// A file arriving, while nothing else uses the island (a drag always wins).
    private var arrival: NotchModel.Incoming? {
        model.phase == .idle && model.incomingShown ? model.incoming : nil
    }

    /// Arriving: a sliver either side of the notch, no taller than the menu bar.
    private var compact: Bool { arrival.map { $0.state != .done } ?? false }
    static let ear: CGFloat = 33

    /// The resting island, just around the notch; it never draws smaller.
    private var idle: CGSize { CGSize(width: notch.width + 12, height: max(notch.height, 1)) }

    /// Island size per phase; "near" grows with proximity.
    private var size: CGSize {
        switch model.phase {
        case .idle:
            guard let arrival else { return idle }
            return arrival.state == .done ? CGSize(width: 360, height: notch.height + 58)
                : CGSize(width: notch.width + 2 * Self.ear, height: max(notch.height, 24))
        case .near:
            let p = model.proximity
            return CGSize(width: idle.width + 120 * p, height: idle.height + 42 * p)
        case .hover:
            if model.targets.count > 1 {
                let n = CGFloat(model.targets.count)
                return CGSize(width: max(400, n * (DevicePill.width + DevicePill.spacing) + 62), height: notch.height + 126)
            }
            return CGSize(width: 430, height: notch.height + 132)
        case .sending, .sent, .failed:
            return CGSize(width: 410, height: notch.height + 96)
        }
    }

    private var expanded: CGFloat {
        switch model.phase {
        case .idle: arrival?.state == .done ? 0.6 : 0
        case .near: model.proximity
        default: 1
        }
    }

    private var bulge: CGFloat {
        switch model.phase {
        case .near: 6 * model.proximity * model.proximity
        case .hover: 5
        default: 0
        }
    }

    private var roundness: CGFloat {
        switch model.phase {
        case .idle: arrival?.state == .done ? 3.4 : 6
        case .near: 6 - 3 * model.proximity
        case .hover: 2.8
        case .sending, .sent, .failed: 3.4
        }
    }

    /// Resting ripple per phase; a kick (any change) adds a jiggle that dies away.
    private func wobble(_ t: Double) -> CGFloat {
        let base: CGFloat = switch model.phase {
        case .idle: 0
        case .near: 0.9 * model.proximity
        case .hover: 1.6
        case .sending: 1.0
        case .sent, .failed: 0.5
        }
        return base + kick(t) * 4
    }

    /// 1 right after a kick, fading to 0 over about a second.
    private func kick(_ t: Double) -> CGFloat {
        CGFloat(model.kickStrength * exp(-max(0, t - model.kickedAt.timeIntervalSinceReferenceDate) * 3.4))
    }

    private var look: Look {
        Look(size: size, shoulder: 6 + 9 * expanded, roundness: roundness, bulge: bulge, shade: expanded,
             outline: outlinePaint, trace: tracePaint)
    }

    /// The edge as a whole: a slowly turning rainbow while a file hovers, a green or
    /// red glow after, a faint line while a file comes near.
    private var outlinePaint: RimPaint {
        switch model.phase {
        case .near: .solid(.white, 0.14 * model.proximity)
        case .hover: RimPaint(colors: RimPaint.rainbow, opacity: 0.95)
        case .sent: .solid(Palette.green, 0.85)
        case .failed: .solid(Palette.red, 0.8)
        case .sending: .off
        case .idle: arrival?.state == .done ? .solid(Palette.green, 0.6) : .off
        }
    }

    /// The edge traced as far as the progress: while sending, and faintly while a file comes in.
    private var tracePaint: RimPaint {
        switch model.phase {
        case .sending: RimPaint(colors: RimPaint.flow, opacity: 0.9)
        case .idle where arrival?.state == .arriving: RimPaint(colors: RimPaint.flow, opacity: 0.5)
        default: .off
        }
    }

    private var traced: Double {
        switch model.phase {
        case .sending: model.progress
        case .idle: arrival.map { $0.state == .arriving ? $0.progress ?? 0 : 1 } ?? 1
        default: 1
        }
    }

    /// How the island moves to its next look.
    private var pace: Motion.Pace {
        if model.phase == .near { return .track }
        // Receiving opens and closes calmly: no jelly while someone's working.
        if model.phase == .idle && model.incoming != nil { return .calm }
        return .open
    }

    /// Still: nothing moving, nothing about to (the timeline stops drawing).
    private func resting(_ look: Look) -> Bool {
        _ = wake
        if Snapshot.active { return true }
        let now = Date().timeIntervalSinceReferenceDate
        return model.phase == .idle && motion.look == look && now >= motion.settles
            && now - model.kickedAt.timeIntervalSinceReferenceDate > 1.5
    }

    var body: some View {
        let look = self.look
        VStack(spacing: 0) {
            TimelineView(.animation(paused: resting(look))) { tl in
                let now = Snapshot.active ? model.kickedAt.addingTimeInterval(5) : tl.date
                island(look, at: now.timeIntervalSinceReferenceDate)
            }
            .modifier(Shake(travel: CGFloat(model.shakes)))
            .opacity(model.hasNotch || model.phase != .idle || model.incomingShown ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: look) { new in
            motion.retarget(to: new, pace: pace)
            wake += 1
        }
        .onChange(of: model.pull) { new in
            motion.follow(pull: new)
            wake += 1
        }
        .onChange(of: traced) { new in
            motion.follow(progress: new)
            wake += 1
        }
        // Once it has all come to rest, look again so the timeline can stop.
        .task(id: wake) {
            let now = Date().timeIntervalSinceReferenceDate
            let quiet = max(motion.settles, model.kickedAt.timeIntervalSinceReferenceDate + 1.5)
            guard quiet > now else { return }
            try? await Task.sleep(nanoseconds: UInt64((quiet - now + 0.05) * 1e9))
            if !Task.isCancelled { wake += 1 }
        }
    }

    /// One frame: the outline where the springs are at `t`, the content laid out at
    /// its final size and seen through that outline (so nothing shows outside it).
    private func island(_ look: Look, at t: Double) -> some View {
        if motion.look == nil {
            motion.jump(to: look)
            motion.progress.jump(traced)
        }
        motion.lastFrame = max(motion.lastFrame, t)
        let k = kick(t)
        let w = max(idle.width, motion.w.value(at: t)), h = max(idle.height, motion.h.value(at: t))
        let shape = NotchShape(shoulder: motion.shoulder.value(at: t), roundness: motion.roundness.value(at: t),
                               bulge: motion.bulge.value(at: t), pull: motion.pull.value(at: t),
                               wobble: wobble(t), time: t)
        return ZStack(alignment: .top) {
            Backdrop(shape: shape, shade: motion.shade.value(at: t), outline: motion.outline.paint(at: t),
                     trace: motion.trace.paint(at: t), traced: motion.progress.value(at: t),
                     angle: .degrees(t * 70))
                .frame(width: w, height: h)
            // One container, so what follows applies once: on a bare conditional SwiftUI gives
            // the outgoing content its own copy of the mask, frozen at the old outline.
            ZStack(alignment: .top) { content }
                .padding(.top, compact ? 0 : notch.height + 6)
                // Round sides: keep content away from where the outline curves in.
                .padding(.horizontal, sideInset)
                .frame(width: look.size.width, height: look.size.height, alignment: .top)
                // The content animates only on its own changes (below the reset further down).
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: scene)
                // Contents bob with the jiggle, a beat behind the outline.
                .offset(y: 1.5 * k * sin(t * 13 + 1))
                .mask(alignment: .top) { shape.frame(width: w, height: h) }
                // The mask is this frame's outline. Changed inside an animation, SwiftUI would
                // cross-fade it from the last one, and the old outline would show content
                // outside the island for as long as that lasts.
                .transaction { $0.animation = nil }
                .contentShape(Rectangle())
                .modifier(DropArea(active: !Snapshot.active,
                                   delegate: IslandDrop(model: model, width: look.size.width, urls: urls, targeted: $targeted)))
        }
    }

    /// What the content shows, coarsely: when this changes, the content animates.
    private struct Scene: Equatable {
        var phase: NotchModel.Phase
        var arrival: NotchModel.Incoming.State?
        var pills: Bool
        var nobody: Bool
        var looking: Bool
    }

    private var scene: Scene {
        Scene(phase: model.phase, arrival: arrival?.state, pills: model.targets.count > 1,
              nobody: model.targets.isEmpty, looking: model.loadingTargets)
    }

    private var sideInset: CGFloat {
        switch model.phase {
        case .idle: compact ? 6 : 40
        case .near: 24
        case .hover: model.targets.count < 2 ? 58 : 46
        default: 46
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if let arrival {
                Group {
                    if arrival.state == .done { receivedContent(arrival) } else { arrivingContent(arrival) }
                }
                .transition(.content())
            } else {
                Color.clear
            }
        case .near:
            HStack(spacing: 8) {
                Avatar(name: model.recipient, photo: model.recipientPhoto, size: 22)
                Text(model.recipient.isEmpty ? "LightDrop" : model.recipient)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            // Centred in the part below the notch (its sag included), however far it has grown.
            .frame(height: max(0, size.height + bulge - notch.height - 12))
            .opacity(Double(max(0, model.proximity - 0.35) / 0.65))
            .scaleEffect(0.8 + 0.2 * model.proximity)
            .blur(radius: 4 * (1 - model.proximity))
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: model.proximity)
            .transition(.content())
        case .hover:
            Group {
                if model.targets.count > 1 { pillsContent } else { handoffContent }
            }
            .transition(.content(scale: 0.88))
        case .sending, .sent, .failed:
            statusContent
                .transition(.content())
        }
    }

    /// File → flowing dots → person, with the name underneath.
    private var handoffContent: some View {
        VStack(spacing: 9) {
            HStack(spacing: 0) {
                FileCard(image: model.thumbnail, count: model.fileCount)
                FlowDots(active: !model.targets.isEmpty)
                    .frame(maxWidth: .infinity)
                Avatar(name: model.recipient, photo: model.recipientPhoto, size: 48,
                       glow: targeted && !model.targets.isEmpty, dimmed: model.targets.isEmpty && !model.loadingTargets)
            }
            .frame(height: 54)
            VStack(spacing: 1) {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.fileName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
    }

    private var headline: String {
        if model.loadingTargets && model.targets.isEmpty { return "Looking for \(model.recipient.isEmpty ? "them" : model.recipient)…" }
        if model.targets.isEmpty { return model.recipient.isEmpty ? "Nobody's receiving" : "\(model.recipient) isn't online" }
        return "Send to \(model.recipient)"
    }

    private var pillsContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                FileCard(image: model.thumbnail, count: model.fileCount, small: true)
                Text("Drop on a computer")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: DevicePill.spacing) {
                ForEach(model.targets) { peer in
                    DevicePill(peer: peer, photo: peer.pic.flatMap { model.photos[$0] }, hovered: model.hovered == peer)
                }
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(name: (model.hovered ?? model.targets.first)?.person ?? model.recipient,
                       photo: model.recipientPhoto, size: 44)
                    .overlay(
                        Circle()
                            .trim(from: 0, to: model.phase == .sending ? max(0.02, model.progress) : 1)
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(-5)
                            .animation(.spring(response: 0.4, dampingFraction: 1), value: model.progress)
                    )
                if model.phase != .sending {
                    Image(systemName: model.phase == .sent ? "checkmark" : "exclamationmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(ringColor))
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .offset(x: 5, y: 5)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: 54, height: 54)
            // The badge pops in with a little bounce.
            .animation(.spring(response: 0.4, dampingFraction: 0.55), value: model.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .sending ? "Sending to \(model.detail)" : model.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusDetail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if model.phase == .sending {
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    // Count up in place; a cross-fade between numbers ghosts.
                    .transaction { $0.animation = nil }
            }
        }
        .padding(.top, 4)
    }

    /// Who sends it on the left of the notch, the progress on the right, each in the
    /// middle of the island's visible "ear" beside the notch.
    private func arrivingContent(_ a: NotchModel.Incoming) -> some View {
        let ear = (size.width - notch.width) / 2 - sideInset
        return HStack(spacing: 0) {
            Avatar(name: a.from, photo: a.pic.flatMap { model.photos[$0] }, size: 20)
                .frame(width: ear)
            Spacer(minLength: 0)
            ArrivalRing(progress: a.progress, failed: a.state == .failed)
                .frame(width: ear)
        }
        .frame(height: max(notch.height, 24))
    }

    /// The file is in: its preview, its name and who it's from, for a moment.
    private func receivedContent(_ a: NotchModel.Incoming) -> some View {
        HStack(spacing: 12) {
            FileCard(image: model.incomingThumb, count: a.saved.count, small: false, still: true)
                .scaleEffect(0.8)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("from \(a.from) · in Downloads")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .bottomTrailing) {
                Avatar(name: a.from, photo: a.pic.flatMap { model.photos[$0] }, size: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Palette.green))
                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
        }
        .padding(.top, 1)
    }

    private var statusDetail: String {
        model.phase == .sending ? model.title : model.detail
    }

    private var ringColor: Color {
        switch model.phase {
        case .sent: Palette.green
        case .failed: Palette.red
        default: Palette.blue
        }
    }
}

/// The island's black body, its shadow and its glowing edge, drawn from one frame's
/// outline. Two edge layers are always there and only change paint, so one look
/// cross-fades into the next instead of a stale outline fading out on its own.
struct Backdrop: View {
    let shape: NotchShape
    let shade: CGFloat
    let outline: RimPaint
    let trace: RimPaint
    /// How far round `trace` goes, 0 … 1.
    let traced: Double
    let angle: Angle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.5 * shade), radius: 26 * shade, y: 10 * shade)
                ZStack {
                    if outline.opacity > 0.004 { glow(shape, outline) }
                    if trace.opacity > 0.004 && traced > 0.002 { glow(shape.trim(from: 0, to: traced), trace) }
                }
                // Only the sides and bottom glow; the top merges with the menu bar. The mask
                // reaches past the frame, so the blur and the sag below it aren't cut off.
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: geo.size.height * 0.28)
                        Color.black.frame(height: geo.size.height * 0.72 + 40)
                    }
                    .padding(.horizontal, -40)
                }
            }
        }
        // Every value here is already this frame's; SwiftUI mustn't tween them again.
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
    }

    private func glow<S: Shape>(_ edge: S, _ paint: RimPaint) -> some View {
        let style = AngularGradient(colors: paint.colors.map(\.color), center: .center, angle: angle)
        return ZStack {
            edge.stroke(style, style: StrokeStyle(lineWidth: 7, lineCap: .round)).blur(radius: 9).opacity(paint.opacity * 0.55)
            edge.stroke(style, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).opacity(paint.opacity)
        }
    }
}

/// The drop target, left out while rendering snapshots (ImageRenderer can't draw it).
struct DropArea: ViewModifier {
    let active: Bool
    let delegate: IslandDrop

    func body(content: Content) -> some View {
        if active { content.onDrop(of: [UTType.fileURL], delegate: delegate) } else { content }
    }
}

/// A tilted card with the dragged file's preview; a badge counts several.
struct FileCard: View {
    let image: NSImage?
    let count: Int
    var small = false
    /// No bobbing (the receive view keeps still).
    var still = false
    @State private var lifted = false

    var body: some View {
        let s: CGFloat = small ? 22 : 46
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.fill").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: small ? 5 : 11, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
            .rotationEffect(.degrees(small ? 0 : (lifted ? -9 : -4)))
            .offset(y: small ? 0 : (lifted ? -2 : 1))
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Palette.pink))
                    .offset(x: 6, y: -5)
            }
        }
        .onAppear {
            guard !small, !still else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { lifted = true }
        }
    }
}

/// Progress of a file coming in: a thin ring around a small arrow. Spins slowly
/// when the size is unknown (a folder from an older sender), red if it broke off.
struct ArrivalRing: View {
    let progress: Double?
    let failed: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 2)
            Circle()
                .trim(from: 0, to: failed ? 1 : progress.map { max(0.03, $0) } ?? 0.25)
                .stroke(failed ? Palette.red : Palette.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .animation(.spring(response: 0.4, dampingFraction: 1), value: progress)
                .rotationEffect(.degrees(progress == nil && !failed && spin ? 270 : -90))
            Image(systemName: failed ? "xmark" : "arrow.down")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 17, height: 17)
        .onAppear {
            guard progress == nil, !Snapshot.active else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// Dots drifting from the file toward the person.
struct FlowDots: View {
    let active: Bool

    var body: some View {
        if Snapshot.active { dots(0.5) } else {
            TimelineView(.animation(paused: !active)) { t in
                dots(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
            }
        }
    }

    private func dots(_ phase: Double) -> some View {
            HStack(spacing: 7) {
                ForEach(0..<5) { i in
                    let wave = max(0, 1 - abs(Double(i) / 4 - phase) * 3)
                    Circle()
                        .fill(active ? Palette.blue.opacity(0.25 + 0.75 * wave) : .white.opacity(0.15))
                        .frame(width: 4 + 2 * wave, height: 4 + 2 * wave)
                }
            }
    }
}

/// The person: their Tailscale profile photo, or a gradient initial.
struct Avatar: View {
    let name: String
    let photo: NSImage?
    let size: CGFloat
    var glow = false
    var dimmed = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if glow {
                Circle()
                    .stroke(Palette.blue.opacity(pulse ? 0 : 0.8), lineWidth: 2)
                    .scaleEffect(pulse ? 1.5 : 1)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
                    }
                    .onDisappear { pulse = false }
            }
            if let photo {
                Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Palette.violet, Palette.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(name.first.map { String($0).uppercased() } ?? "↑")
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Circle().stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .scaleEffect(glow ? 1.08 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: glow)
    }
}

struct DevicePill: View {
    static let width: CGFloat = 124, spacing: CGFloat = 10
    let peer: Peer
    let photo: NSImage?
    let hovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(name: peer.person, photo: photo, size: 26)
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(.black))
                    .offset(x: 4, y: 3)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(peer.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(peer.owner == "you" ? "yours" : peer.person)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.55)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(hovered ? 0.2 : 0.07))
                .overlay(Capsule(style: .continuous)
                    .stroke(hovered ? Palette.blue.opacity(0.9) : .white.opacity(0.06), lineWidth: 1))
        )
        .scaleEffect(hovered ? 1.07 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovered)
    }

    private var icon: String {
        let n = peer.name.lowercased()
        if n.contains("mac") || n.contains("book") { return "laptopcomputer" }
        if n.contains("ipad") { return "ipad" }
        return "desktopcomputer"
    }
}
