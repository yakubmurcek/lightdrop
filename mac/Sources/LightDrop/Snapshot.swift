import AppKit
import SwiftUI

/// `LightDrop --snapshot <dir> [photo] [file]`: renders every state of the island
/// to PNGs, so the look can be checked without dragging anything.
@MainActor
enum Snapshot {
    /// True while rendering: animations that ImageRenderer can't draw stay still.
    nonisolated(unsafe) static var active = false

    static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        active = true
        let dir = URL(fileURLWithPath: args[i + 1])
        let photo = args.count > i + 2 ? NSImage(contentsOfFile: args[i + 2]) : nil
        let file = args.count > i + 3 ? NSImage(contentsOfFile: args[i + 3]) : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sam = Peer(name: "macbook", ip: "100.64.0.2", owner: "Sam Rivera", receiving: true, pic: "p")
        let desk = Peer(name: "studio", ip: "100.64.0.3", owner: "Sam Rivera", receiving: true, pic: "p")
        let states: [(String, (NotchModel) -> Void)] = [
            ("1-near-far", { $0.phase = .near; $0.proximity = 0.45; $0.pull = -0.3 }),
            ("2-near-close", { $0.phase = .near; $0.proximity = 0.95; $0.pull = 0.4 }),
            ("3-hover", { $0.phase = .hover; $0.pull = -0.5 }),
            ("4-hover-two-computers", { $0.phase = .hover; $0.targets = [sam, desk]; $0.hovered = desk; $0.pull = 0.4 }),
            ("5-sending", { $0.phase = .sending; $0.progress = 0.62; $0.title = "sunset.jpg"; $0.detail = "Sam" }),
            ("6-sent", { $0.phase = .sent; $0.progress = 1; $0.title = "Delivered to Sam"; $0.detail = "sunset.jpg" }),
            ("7-offline", { $0.phase = .hover; $0.targets = []; $0.lastPic = "p" }),
            ("8-failed", { $0.phase = .failed; $0.title = "Couldn't send"; $0.detail = "Sam isn't online" }),
            ("9-receiving", { $0.incomingShown = true
                $0.incoming = .init(ip: sam.ip, from: "Sam", pic: "p", name: "sunset.jpg", index: 1, count: 1, part: 0.4) }),
            ("10-received", { $0.incomingShown = true; $0.incomingThumb = file
                $0.incoming = .init(ip: sam.ip, from: "Sam", pic: "p", name: "sunset.jpg", index: 1, count: 1, part: 1,
                                    state: .done, saved: [URL(fileURLWithPath: "/Downloads/sunset.jpg")]) }),
            ("11-receiving-folder", { $0.incomingShown = true
                $0.incoming = .init(ip: sam.ip, from: "Ondrejs-MacBook-Pro", name: "HousePlan", index: 1, count: 1, part: nil) }),
            // A Mac without a notch: the island grows out of the top centre.
            ("12-no-notch-near", { $0.phase = .near; $0.proximity = 0.9 }),
            ("13-no-notch-hover", { $0.phase = .hover }),
            ("14-no-notch-receiving", { $0.incomingShown = true
                $0.incoming = .init(ip: sam.ip, from: "Sam", pic: "p", name: "sunset.jpg", index: 1, count: 1, part: 0.4) }),
        ]
        for (name, apply) in states {
            let notch = !name.contains("no-notch")
            let m = NotchModel(notchSize: notch ? CGSize(width: 185, height: 32) : CGSize(width: 190, height: 0), hasNotch: notch)
            m.targets = [sam]
            m.thumbnail = file
            m.fileCount = 1
            m.fileName = "sunset.jpg"
            if let photo { m.photos["p"] = photo }
            apply(m)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.15, blue: 0.30), Color(red: 0.32, green: 0.28, blue: 0.52)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(white: 0.13)).frame(height: notch ? 32 : 24)
                IslandView(model: m, urls: { [] })
            }
            .frame(width: 560, height: 220)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        exit(0)
    }
}
