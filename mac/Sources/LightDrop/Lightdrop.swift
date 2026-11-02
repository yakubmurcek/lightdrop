import Foundation

/// A computer on the tailnet, as `lightdrop peers` reports it.
struct Peer: Decodable, Hashable, Identifiable {
    let name: String
    let ip: String
    /// "you", a person's display name, or "" for a server.
    let owner: String
    let receiving: Bool
    /// The owner's Tailscale profile picture URL.
    let pic: String?
    var id: String { ip }

    /// First name of the owner ("Sam Rivera" → "Sam"); your own computers go by their name.
    var person: String {
        owner == "you" ? name : owner.split(separator: " ").first.map(String.init) ?? owner
    }
}

/// Bridge to the lightdrop command (the core: discovery, transfer, receiving).
/// The app only decides where a drop goes and shows it.
enum Lightdrop {
    static var binary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lightdrop")
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    /// Online computers that are receiving and belong to someone else. With the
    /// `includeOwnDevices` default on (testing alone), your own count too.
    static func targets() async throws -> [Peer] {
        let own = UserDefaults.standard.bool(forKey: "includeOwnDevices")
        return try await peers().filter { $0.receiving && !$0.owner.isEmpty && ($0.owner != "you" || own) }
    }

    /// Every online computer, yours included (to name who a file comes from).
    static func peers() async throws -> [Peer] {
        let out = try await run(["peers"]).stdout
        return try JSONDecoder().decode([Peer].self, from: Data(out.utf8))
    }

    enum Event {
        case progress(file: String, sent: Int64, total: Int64)
        case sent(file: String, savedAs: String)
    }

    /// Sends paths to one computer, streaming progress. Throws the CLI's message on failure.
    static func send(_ urls: [URL], to peer: Peer, onEvent: @escaping @MainActor (Event) -> Void) async throws {
        let args = ["-t", peer.ip, "--json"] + urls.map(\.path)
        let result = try await run(args) { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String, let file = obj["file"] as? String else { return }
            let ev: Event? = switch event {
            case "progress": .progress(file: file, sent: (obj["sent"] as? NSNumber)?.int64Value ?? 0,
                                       total: (obj["total"] as? NSNumber)?.int64Value ?? 0)
            case "sent": .sent(file: file, savedAs: obj["saved"] as? String ?? file)
            default: nil
            }
            if let ev { Task { @MainActor in onEvent(ev) } }
        }
        if result.status != 0 { throw LightdropError(message: result.stderr) }
    }

    /// What this computer's receiver reports while a file comes in (`lightdrop events --json`).
    enum Arrival {
        /// The `index`-th of `count` files from one send; `total` is 0 when unknown.
        case incoming(id: Int, name: String, from: String, ip: String, total: Int64, index: Int, count: Int)
        case progress(id: Int, got: Int64, total: Int64)
        case done(id: Int, saved: String, path: String)
        case failed(id: Int)

        init?(json line: String) {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = o["event"] as? String, let id = (o["id"] as? NSNumber)?.intValue else { return nil }
            func int64(_ k: String) -> Int64 { (o[k] as? NSNumber)?.int64Value ?? 0 }
            func str(_ k: String) -> String { o[k] as? String ?? "" }
            switch event {
            case "incoming":
                self = .incoming(id: id, name: str("name"), from: str("from"), ip: str("ip"), total: int64("total"),
                                 index: (o["index"] as? NSNumber)?.intValue ?? 1, count: (o["count"] as? NSNumber)?.intValue ?? 1)
            case "progress": self = .progress(id: id, got: int64("got"), total: int64("total"))
            case "done": self = .done(id: id, saved: str("saved"), path: str("path"))
            case "failed": self = .failed(id: id)
            default: return nil
            }
        }
    }

    /// Follows the receiver for as long as the app runs: one `lightdrop events`
    /// process, started again a few seconds after it ends (the CLI was updated,
    /// or wasn't installed yet). Closing its stdin, which dies with the app, ends it.
    final class ArrivalWatcher: @unchecked Sendable {
        private var process: Process?
        private var stdin: Pipe?

        func start(onEvent: @escaping @MainActor (Arrival) -> Void) {
            guard isInstalled else { return retry(onEvent) }
            let p = Process(), out = Pipe(), input = Pipe()
            p.executableURL = binary
            p.arguments = ["events", "--json"]
            p.standardOutput = out
            p.standardInput = input
            p.standardError = FileHandle.nullDevice
            let buf = LineBuffer(keepAll: false) { line in
                if let ev = Arrival(json: line) { Task { @MainActor in onEvent(ev) } }
            }
            out.fileHandleForReading.readabilityHandler = { h in buf.append(h.availableData) }
            p.terminationHandler = { [weak self] _ in
                out.fileHandleForReading.readabilityHandler = nil
                self?.retry(onEvent)
            }
            do { try p.run() } catch { return retry(onEvent) }
            process = p
            stdin = input
        }

        private func retry(_ onEvent: @escaping @MainActor (Arrival) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start(onEvent: onEvent) }
        }
    }

    struct LightdropError: LocalizedError {
        let message: String
        var errorDescription: String? {
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "lightdrop: ", with: "")
            return m.isEmpty ? "Sending failed" : m
        }
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    /// Runs lightdrop, handing each stdout line to `onLine` as it arrives.
    private static func run(_ args: [String], onLine: ((String) -> Void)? = nil) async throws -> Result {
        guard isInstalled else {
            throw LightdropError(message: "lightdrop isn't installed — run the install line")
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let buf = LineBuffer(onLine: onLine)
            out.fileHandleForReading.readabilityHandler = { h in buf.append(h.availableData) }
            p.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                buf.append(out.fileHandleForReading.readDataToEndOfFile())
                let o = buf.finish()
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: Result(status: p.terminationStatus, stdout: o, stderr: e))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// Collects a process's stdout and hands over complete lines as they arrive.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data(), pending = Data()
    private let onLine: ((String) -> Void)?
    /// False for a process that runs for hours: only the lines matter.
    private let keepAll: Bool

    init(keepAll: Bool = true, onLine: ((String) -> Void)?) {
        self.keepAll = keepAll
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if keepAll { all.append(chunk) }
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 0x0A) {
            onLine?(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
    }

    /// The whole output; a last line without a newline is handed over too.
    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)); pending = Data() }
        return String(decoding: all, as: UTF8.self)
    }
}
