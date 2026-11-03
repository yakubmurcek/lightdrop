import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Everything the island shows, driven by the drag watcher and the drop.
@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable { case idle, near, hover, sending, sent, failed }

    @Published var phase: Phase = .idle {
        didSet { if phase != oldValue { kick(phase == .sent || phase == .failed ? 1 : 0.7) } }
    }
    /// The last jiggle: when and how hard (the outline ripples, then settles).
    @Published var kickedAt = Date.distantPast
    @Published var kickStrength = 0.0
    /// 0 (far) … 1 (at the notch) while a file is dragged nearby.
    @Published var proximity: CGFloat = 0
    /// Where the cursor is across the island, -1 (left) … 1 (right); the bottom edge leans to it.
    @Published var pull: CGFloat = 0
    @Published var targets: [Peer] = []
    @Published var loadingTargets = false
    /// The device pill under the cursor when there are several.
    @Published var hovered: Peer? {
        didSet { if hovered != oldValue, hovered != nil { kick(0.4) } }
    }
    @Published var progress: Double = 0
    @Published var title = ""
    @Published var detail = ""
    /// What is being dragged: a preview of the first file and how many there are.
    @Published var thumbnail: NSImage?
    @Published var fileCount = 0
    @Published var fileName = ""
    /// Owners' profile pictures by URL.
    @Published var photos: [String: NSImage] = [:]
    /// Bumped on failure to shake the island.
    @Published var shakes = 0

    /// A file (or a whole send of them) arriving here, shown quietly beside the notch.
    struct Incoming: Equatable {
        enum State { case arriving, done, failed }
        var ip: String
        /// Who sends it: their computer's own name until `lightdrop peers` names the person.
        var from: String
        var pic: String?
        /// The file arriving now, the `index`-th of `count`.
        var name: String
        var index: Int
        var count: Int
        /// How far the current file is, nil when its size is unknown.
        var part: Double?
        var state = State.arriving
        var saved: [URL] = []

        var progress: Double? { part.map { (Double(index - 1) + $0) / Double(max(count, 1)) } }
        var title: String { saved.count == 1 ? saved[0].lastPathComponent : "\(saved.count) items" }
    }
    @Published var incoming: Incoming?
    /// Only transfers that take a moment show, so a small file doesn't flash.
    @Published var incomingShown = false
    @Published var incomingThumb: NSImage?
    /// Each saved file and who it came from (the menu lists the last few).
    var received: (URL, String) -> Void = { _, _ in }

    let notchSize: CGSize
    let hasNotch: Bool
    private var lastLoad = Date.distantPast
    private var resetTask: Task<Void, Never>?
    private var incomingID = 0
    private var incomingTask: Task<Void, Never>?
    /// Every online computer, to tell who a file comes from.
    private var known: [Peer] = []

    init(notchSize: CGSize, hasNotch: Bool) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
        if let pic = lastPic, let img = NSImage(contentsOf: Self.cacheFile(pic)) { photos[pic] = img }
    }

    /// Who drops go to, by first name ("Sam", or "Sam & Kim").
    var recipient: String {
        var seen = Set<String>(), people: [String] = []
        for p in targets.map(\.person) where seen.insert(p).inserted { people.append(p) }
        if people.isEmpty { return UserDefaults.standard.string(forKey: "lastRecipient") ?? "" }
        return people.joined(separator: " & ")
    }

    /// The recipient's photo, when they have one; the last one seen while nobody's online.
    var recipientPhoto: NSImage? {
        ((hovered ?? targets.first)?.pic ?? (targets.isEmpty ? lastPic : nil)).flatMap { photos[$0] }
    }

    /// The last recipient's photo URL, remembered across launches.
    var lastPic: String? {
        get { UserDefaults.standard.string(forKey: "lastRecipientPic") }
        set { UserDefaults.standard.set(newValue, forKey: "lastRecipientPic") }
    }

    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LightDrop", isDirectory: true)

    private static func cacheFile(_ url: String) -> URL {
        let name = Data(url.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").suffix(120)
        return cache.appendingPathComponent(String(name))
    }

    func kick(_ strength: Double) {
        kickedAt = Date()
        kickStrength = strength
    }

    var busy: Bool { phase == .sending || phase == .sent || phase == .failed }

    // MARK: drag

    func dragBegan(urls: [URL]) {
        guard !busy else { return }
        fileCount = urls.count
        fileName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        thumbnail = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        if let first = urls.first { loadThumbnail(first) }
        refreshTargets()
    }

    func dragMoved(proximity p: CGFloat, lean: CGFloat) {
        guard !busy, phase != .hover else { return }
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.62)) {
            proximity = p
            pull = lean
            phase = p > 0 ? .near : .idle
        }
    }

    /// Cursor position over the open island, -1 … 1.
    func hoverMoved(_ x: CGFloat) {
        guard phase == .hover else { return }
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.55)) { pull = x }
    }

    func dragEnded() {
        guard !busy else { return }
        collapse()
    }

    func hover(_ inside: Bool) {
        guard !busy else { return }
        if inside, phase != .hover { Haptics.tap() }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            phase = inside ? .hover : (proximity > 0 ? .near : .idle)
            if !inside { hovered = nil }
        }
    }

    func refreshTargets() {
        guard Date().timeIntervalSince(lastLoad) > 4, !loadingTargets else { return }
        lastLoad = Date()
        loadingTargets = true
        Task {
            let found = (try? await Lightdrop.targets()) ?? []
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                targets = found
                loadingTargets = false
            }
            if let first = found.first {
                UserDefaults.standard.set(first.person, forKey: "lastRecipient")
                lastPic = first.pic
            }
            for url in Set(found.compactMap(\.pic)) where photos[url] == nil { loadPhoto(url) }
        }
    }

    // MARK: receiving

    /// What the receiver reports. Nothing here asks for attention: no sound, no
    /// jiggle, and the island stays within the menu bar until the file is in.
    func arrival(_ ev: Lightdrop.Arrival) {
        switch ev {
        case let .incoming(id, name, from, ip, total, index, count):
            incomingID = id
            if var cur = incoming, cur.ip == ip, incomingShown || cur.state == .arriving {
                // The next file of the same send.
                cur.name = name
                (cur.index, cur.count) = (index, count)
                cur.part = total > 0 ? 0 : nil
                cur.state = .arriving
                withAnimation(.easeInOut(duration: 0.3)) { incoming = cur }
                if incomingShown { return later(30) { [self] in failIncoming() } }
            } else {
                incomingShown = false
                incomingThumb = nil
                incoming = Incoming(ip: ip, from: from.isEmpty ? ip : from, name: name, index: index, count: count,
                                    part: total > 0 ? 0 : nil)
                identify(ip)
            }
            later(0.7) { [self] in
                if incoming?.state == .arriving { reveal() }
                later(30) { [self] in failIncoming() }
            }
        case let .progress(id, got, total):
            guard id == incomingID, var cur = incoming, cur.state == .arriving else { return }
            if total > 0 { cur.part = min(1, Double(got) / Double(total)) }
            withAnimation(.spring(response: 0.4, dampingFraction: 1)) { incoming = cur }
            if incomingShown { later(30) { [self] in failIncoming() } }
        case let .done(id, _, path):
            guard id == incomingID, var cur = incoming else { return }
            let url = URL(fileURLWithPath: path)
            cur.part = 1
            cur.saved.append(url)
            withAnimation(.easeOut(duration: 0.3)) { incoming = cur }
            received(url, cur.from)
            // More of this send may follow (old senders don't say): wait for it first.
            later(cur.index < cur.count ? 30 : 0.8) { [self] in finishIncoming() }
        case let .failed(id):
            guard id == incomingID else { return }
            failIncoming()
        }
    }

    /// Runs `then` after `seconds`, replacing whatever was scheduled for the incoming file.
    private func later(_ seconds: Double, _ then: @escaping @MainActor () -> Void) {
        incomingTask?.cancel()
        incomingTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            then()
        }
    }

    private func reveal() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { incomingShown = true }
    }

    private func finishIncoming() {
        guard var cur = incoming, let last = cur.saved.last else { return failIncoming() }
        cur.state = .done
        loadIncomingThumb(last)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            incoming = cur
            incomingShown = true
        }
        later(2.6) { [self] in clearIncoming() }
    }

    /// The sender gave up or vanished. Whatever arrived still counts; otherwise a
    /// short red ring where the progress was, or nothing at all if it never showed.
    private func failIncoming() {
        guard var cur = incoming else { return }
        if !cur.saved.isEmpty { return finishIncoming() }
        guard incomingShown else { return clearIncoming() }
        cur.state = .failed
        withAnimation(.easeOut(duration: 0.3)) { incoming = cur }
        later(1.6) { [self] in clearIncoming() }
    }

    private func clearIncoming() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { incomingShown = false }
        // Kept until the island has closed, so it closes as calmly as it opened.
        later(0.8) { [self] in incoming = nil }
    }

    /// Names the sender from the tailnet's list of computers (photo included).
    private func identify(_ ip: String) {
        func apply(_ p: Peer) {
            guard incoming?.ip == ip else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                incoming?.from = p.person
                incoming?.pic = p.pic
            }
            if let pic = p.pic, photos[pic] == nil { loadPhoto(pic) }
        }
        if let p = known.first(where: { $0.ip == ip }) { return apply(p) }
        Task {
            known = (try? await Lightdrop.peers()) ?? known
            if let p = known.first(where: { $0.ip == ip }) { apply(p) }
        }
    }

    private func loadIncomingThumb(_ url: URL) {
        incomingThumb = NSWorkspace.shared.icon(forFile: url.path)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 80, height: 80),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateRepresentations(for: req) { rep, _, _ in
            guard let img = rep?.nsImage else { return }
            Task { @MainActor in
                guard self.incoming?.saved.last == url else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.incomingThumb = img }
            }
        }
    }

    private func loadPhoto(_ url: String) {
        guard let u = URL(string: url) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
            try? data.write(to: Self.cacheFile(url))
            withAnimation(.easeOut(duration: 0.25)) { photos[url] = img }
        }
    }

    /// The file's Quick Look preview (the actual photo, page, …), replacing its icon when ready.
    private func loadThumbnail(_ url: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateRepresentations(for: req) { rep, _, _ in
            guard let img = rep?.nsImage else { return }
            Task { @MainActor in
                guard self.fileName == url.lastPathComponent || self.fileCount > 1 else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.thumbnail = img }
            }
        }
    }

    // MARK: drop

    /// Accepts a drop when someone is receiving; `peer` is the pill it landed on.
    func drop(_ urls: [URL], on peer: Peer?) -> Bool {
        guard !urls.isEmpty, !busy, let to = peer ?? (targets.count == 1 ? targets.first : nil) else {
            if targets.isEmpty { fail(recipient.isEmpty ? "Nobody is receiving right now" : "\(recipient) isn't online") }
            return false
        }
        if peer != nil { hovered = peer }
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        startSending(name, to: to)
        var done = 0
        Task {
            do {
                try await Lightdrop.send(urls, to: to) { ev in
                    switch ev {
                    case let .progress(_, sent, total):
                        let part = total > 0 ? min(Double(sent) / Double(total), 1) : 1
                        withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
                            self.progress = (Double(done) + part) / Double(urls.count)
                        }
                    case .sent:
                        done += 1
                    }
                }
                succeed(to: to, name: name)
            } catch {
                fail(error.localizedDescription)
            }
        }
        return true
    }

    private func startSending(_ name: String, to: Peer) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.66)) {
            phase = .sending
            progress = 0
            pull = 0
            title = name
            detail = to.person
        }
    }

    static let demoScenes = ["send", "pills", "offline", "retreat", "receive", "batch", "broken"]

    /// `LightDrop --demo <file> [scene]`: plays a scene on its own (no mouse, nothing
    /// sent or received, made-up computers), to watch or record the motion. Scenes
    /// are `demoScenes`; without one, all of them in turn.
    func playDemo(file: URL, scene: String?) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        let sam = Peer(name: "macbook", ip: "100.64.0.2", owner: "Sam Rivera", receiving: true, pic: lastPic)
        let studio = Peer(name: "studio", ip: "100.64.0.3", owner: "Sam Rivera", receiving: true, pic: lastPic)
        lastLoad = .distantFuture
        known = [sam, studio]
        let name = file.lastPathComponent

        /// The cursor coming in from below at drag speed (the watcher's 60 Hz), leaning a little.
        func approach(from: CGFloat = 0, to: CGFloat = 1, seconds: Double = 0.7) async {
            let n = Int(seconds * 60)
            for i in 0...n {
                let p = from + (to - from) * CGFloat(i) / CGFloat(n)
                dragMoved(proximity: p, lean: 6 * sin(p * 3))
                await wait(1.0 / 60)
            }
        }
        /// Over the open island, sweeping from x0 to x1 (-1 … 1), picking pills as the drop delegate does.
        func sweep(_ x0: CGFloat, _ x1: CGFloat, seconds: Double) async {
            let n = Int(seconds * 60)
            for i in 0...n {
                let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n)
                hoverMoved(x)
                if targets.count > 1 {
                    let peer = targets[x < 0 ? 0 : 1]
                    if peer != hovered { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hovered = peer } }
                }
                await wait(1.0 / 60)
            }
        }
        func send(to peer: Peer) async {
            startSending(name, to: peer)
            for i in 1...14 {
                await wait(0.15)
                withAnimation(.spring(response: 0.4, dampingFraction: 1)) { progress = Double(i) / 14 }
            }
            succeed(to: peer, name: name)
            await wait(3.2)
        }
        func receive(_ id: Int, index: Int = 1, count: Int = 1, seconds: Double = 2.4, fail: Bool = false) async {
            arrival(.incoming(id: id, name: name, from: "macbook", ip: sam.ip, total: 1000, index: index, count: count))
            let n = Int(seconds / 0.15)
            for i in 1...n {
                await wait(0.15)
                if fail && i == n * 2 / 3 { return arrival(.failed(id: id)) }
                arrival(.progress(id: id, got: Int64(1000 * i / n), total: 1000))
            }
            arrival(.done(id: id, saved: name, path: file.path))
        }

        for s in scene.map({ [$0] }) ?? Self.demoScenes {
            targets = s == "offline" ? [] : s == "pills" ? [sam, studio] : [sam]
            await wait(0.8)
            switch s {
            case "send", "pills", "offline":
                dragBegan(urls: [file])
                await approach()
                hover(true)
                await sweep(0, -0.6, seconds: 0.5)
                await sweep(-0.6, 0.6, seconds: 1)
                await wait(0.3)
                if s == "offline" {
                    _ = drop([file], on: nil)
                    await wait(3.8)
                } else {
                    await send(to: hovered ?? sam)
                }
            case "retreat":
                // Comes close, backs off, comes in, slides out of the island, lets go nearby.
                dragBegan(urls: [file])
                await approach(to: 0.8, seconds: 0.6)
                await approach(from: 0.8, to: 0.2, seconds: 0.5)
                await approach(from: 0.2, to: 1, seconds: 0.5)
                hover(true)
                await wait(0.8)
                hover(false)
                await approach(from: 1, to: 0.6, seconds: 0.4)
                await wait(0.3)
                dragEnded()
                await wait(1.5)
            case "receive":
                await receive(1)
                await wait(4.5)
            case "batch":
                for i in 1...3 { await receive(10 + i, index: i, count: 3, seconds: 1.2) }
                await wait(4.5)
            case "broken":
                await receive(20, fail: true)
                await wait(3.5)
            default:
                break
            }
        }
        // LIGHTDROP_DEMO_HOLD=<seconds> stays open at rest afterwards (to measure idle CPU).
        await wait(Double(ProcessInfo.processInfo.environment["LIGHTDROP_DEMO_HOLD"] ?? "") ?? 0)
        exit(0)
    }

    private func succeed(to: Peer, name: String) {
        Haptics.success()
        NSSound(named: "Pop")?.play()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
            progress = 1
            phase = .sent
            title = "Delivered to \(to.person)"
            detail = name
        }
        scheduleCollapse(after: 1.8)
    }

    private func fail(_ message: String) {
        Haptics.tap()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            phase = .failed
            title = "Couldn't send"
            detail = message
            pull = 0
        }
        withAnimation(.linear(duration: 0.5)) { shakes += 1 }
        scheduleCollapse(after: 3)
    }

    private func scheduleCollapse(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            collapse(force: true)
        }
    }

    private func collapse(force: Bool = false) {
        guard force || !busy else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.74)) {
            phase = .idle
            proximity = 0
            pull = 0
            hovered = nil
        }
    }
}

enum Haptics {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
