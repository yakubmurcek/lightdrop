import AppKit

/// Notices a file being dragged anywhere on screen and reports where the cursor is.
///
/// A drag shows up as a change of the drag pasteboard after a mouse-down; from
/// then on a 60 Hz timer follows the cursor until the button is released (during
/// a drag session another app owns the mouse, so events are not reliable).
@MainActor
final class DragWatcher {
    var began: () -> Void = {}
    var moved: (NSPoint) -> Void = { _ in }
    var ended: () -> Void = {}

    private let pasteboard = NSPasteboard(name: .drag)
    private var countAtMouseDown = 0
    private var dragging = false
    private var timer: Timer?
    private var monitors: [Any] = []

    func start() {
        countAtMouseDown = pasteboard.changeCount
        let down: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.countAtMouseDown = self?.pasteboard.changeCount ?? 0 }
        }
        let drag: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStart() }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: drag) as Any)
    }

    private func checkStart() {
        guard !dragging, pasteboard.changeCount != countAtMouseDown, carriesFiles else { return }
        dragging = true
        began()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var carriesFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            dragging = false
            countAtMouseDown = pasteboard.changeCount
            ended()
            return
        }
        moved(NSEvent.mouseLocation)
    }

    /// The files being dragged right now.
    var draggedURLs: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
