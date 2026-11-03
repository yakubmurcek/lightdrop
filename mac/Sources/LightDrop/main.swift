import AppKit
import ServiceManagement
import SwiftUI

/// A borderless panel over the notch. It ignores the mouse except while a file is
/// being dragged, so it never gets in the way of the menu bar.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: NotchPanel?
    private var model: NotchModel?
    private let watcher = DragWatcher()
    private let arrivals = Lightdrop.ArrivalWatcher()
    private var statusItem: NSStatusItem?
    /// The last files that came in, newest first, for the menu.
    private var recent: [(url: URL, from: String)] = []
    private static let panelSize = CGSize(width: 640, height: 240)

    func applicationDidFinishLaunching(_ note: Notification) {
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        watcher.began = { [weak self] in
            self?.panel?.ignoresMouseEvents = false
            self?.model?.dragBegan(urls: self?.watcher.draggedURLs ?? [])
        }
        watcher.moved = { [weak self] point in self?.track(point) }
        watcher.ended = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            self?.model?.dragEnded()
        }
        watcher.start()
        arrivals.start { [weak self] ev in self?.model?.arrival(ev) }
        addStatusItem()
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count, let model {
            panel?.ignoresMouseEvents = true
            let scene = i + 2 < args.count ? args[i + 2] : nil
            Task { await model.playDemo(file: URL(fileURLWithPath: args[i + 1]), scene: scene) }
        }
    }

    /// The screen with the notch, else the main one.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let screen else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        var notch = CGSize(width: 190, height: 0)
        if hasNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        let s = Self.panelSize
        let frame = NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height, width: s.width, height: s.height)
        let model = NotchModel(notchSize: notch, hasNotch: hasNotch)
        model.received = { [weak self] url, from in
            self?.recent.removeAll { $0.url == url }
            self?.recent.insert((url, from), at: 0)
            self?.recent = Array(self?.recent.prefix(5) ?? [])
        }
        self.model = model
        let view = IslandView(model: model) { [weak self] in self?.watcher.draggedURLs ?? [] }
        if let panel {
            panel.setFrame(frame, display: true)
            panel.contentView = NSHostingView(rootView: view)
        } else {
            let p = NotchPanel(frame: frame)
            p.contentView = NSHostingView(rootView: view)
            p.orderFrontRegardless()
            panel = p
        }
    }

    /// Proximity of the cursor to the notch: 1 at it, 0 beyond ~300 pt.
    private func track(_ point: NSPoint) {
        guard let screen, let model else { return }
        let top = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - model.notchSize.height / 2)
        let dx = point.x - top.x, dy = point.y - top.y
        let d = hypot(dx * 0.7, dy)
        let p = max(0, min(1, 1 - (d - 50) / 260))
        model.dragMoved(proximity: p, lean: max(-12, min(12, dx * 0.05)))
    }

    private func addStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "LightDrop")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Built on open, so the files received lately are listed (click: show in Finder).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Drag a file to the notch to send it", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let live = recent.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !live.isEmpty {
            menu.addItem(withTitle: "Received", action: nil, keyEquivalent: "").isEnabled = false
            for r in live {
                let item = menu.addItem(withTitle: "\(r.url.lastPathComponent) — \(r.from)",
                                        action: #selector(reveal(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r.url
                item.image = NSWorkspace.shared.icon(forFile: r.url.path)
                item.image?.size = NSSize(width: 16, height: 16)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Open Downloads", action: #selector(openDownloads), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit LightDrop", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openDownloads() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    Snapshot.run(CommandLine.arguments)
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
