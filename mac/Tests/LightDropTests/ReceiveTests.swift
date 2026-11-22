import XCTest
@testable import LightDrop

final class ArrivalTests: XCTestCase {
    func testParsesEachEvent() {
        guard case let .incoming(id, name, from, ip, total, index, count)? = Lightdrop.Arrival(json:
            #"{"event":"incoming","id":7,"name":"a.jpg","kind":"file","from":"box","ip":"100.64.0.2","total":2048,"index":2,"count":3}"#)
        else { return XCTFail("incoming") }
        XCTAssertEqual([id, index, count], [7, 2, 3])
        XCTAssertEqual([name, from, ip], ["a.jpg", "box", "100.64.0.2"])
        XCTAssertEqual(total, 2048)

        guard case let .progress(_, got, of)? = Lightdrop.Arrival(json: #"{"event":"progress","id":7,"got":1024,"total":2048}"#)
        else { return XCTFail("progress") }
        XCTAssertEqual([got, of], [1024, 2048])

        guard case let .done(_, saved, path)? = Lightdrop.Arrival(json: #"{"event":"done","id":7,"saved":"a 2.jpg","path":"/D/a 2.jpg"}"#)
        else { return XCTFail("done") }
        XCTAssertEqual([saved, path], ["a 2.jpg", "/D/a 2.jpg"])

        guard case .failed(7)? = Lightdrop.Arrival(json: #"{"event":"failed","id":7,"error":"EOF"}"#) else { return XCTFail("failed") }
    }

    /// Older senders give no batch position: it counts as file 1 of 1.
    func testOldSenderIsOneOfOne() {
        guard case let .incoming(_, _, _, _, total, index, count)? = Lightdrop.Arrival(json:
            #"{"event":"incoming","id":1,"name":"F","kind":"dir","from":"","ip":"100.64.0.2","total":0}"#)
        else { return XCTFail("incoming") }
        XCTAssertEqual([index, count], [1, 1])
        XCTAssertEqual(total, 0)
    }

    func testIgnoresWhatItDoesNotKnow() {
        XCTAssertNil(Lightdrop.Arrival(json: "not json"))
        XCTAssertNil(Lightdrop.Arrival(json: #"{"event":"incoming"}"#))
        XCTAssertNil(Lightdrop.Arrival(json: #"{"event":"party","id":1}"#))
    }
}

final class IncomingTests: XCTestCase {
    func testProgressSpansTheWholeSend() {
        var a = NotchModel.Incoming(ip: "", from: "Sam", name: "b", index: 2, count: 4, part: 0.5)
        XCTAssertEqual(a.progress!, 0.375, accuracy: 1e-9)
        a.part = nil
        XCTAssertNil(a.progress, "unknown size → no progress, the ring spins")
    }

    func testTitleNamesOneFileOrCountsThem() {
        var a = NotchModel.Incoming(ip: "", from: "Sam", name: "a", index: 1, count: 1, part: 1,
                                    saved: [URL(fileURLWithPath: "/D/sunset.jpg")])
        XCTAssertEqual(a.title, "sunset.jpg")
        a.saved.append(URL(fileURLWithPath: "/D/b.jpg"))
        XCTAssertEqual(a.title, "2 items")
    }

    func testPersonIsTheOwnersFirstName() {
        XCTAssertEqual(Peer(name: "macbook", ip: "", owner: "Sam Rivera", receiving: true, pic: nil).person, "Sam")
        XCTAssertEqual(Peer(name: "studio", ip: "", owner: "you", receiving: true, pic: nil).person, "studio")
    }
}

@MainActor
final class ReceiveFlowTests: XCTestCase {
    private func model() -> NotchModel { NotchModel(notchSize: CGSize(width: 185, height: 32), hasNotch: true) }
    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Waits up to a few seconds for `ok` (a slow CI runner delays the model's timers).
    private func eventually(_ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while !ok(), Date() < end { await wait(0.05) }
        return ok()
    }

    /// A send of several files ends in one card, not one per file.
    func testBatchEndsInOneCard() async {
        let m = model()
        var received: [String] = []
        m.received = { url, _ in received.append(url.lastPathComponent) }
        m.arrival(.incoming(id: 1, name: "a.mov", from: "box", ip: "100.64.0.9", total: 10, index: 1, count: 2))
        m.arrival(.progress(id: 1, got: 5, total: 10))
        XCTAssertEqual(m.incoming?.progress ?? -1, 0.25, accuracy: 1e-9)
        m.arrival(.done(id: 1, saved: "a.mov", path: "/D/a.mov"))
        m.arrival(.incoming(id: 2, name: "b.mov", from: "box", ip: "100.64.0.9", total: 10, index: 2, count: 2))
        XCTAssertEqual(m.incoming?.state, .arriving)
        m.arrival(.done(id: 2, saved: "b.mov", path: "/D/b.mov"))
        let finished = await eventually { m.incoming?.state == .done }
        XCTAssertTrue(finished)
        XCTAssertTrue(m.incomingShown)
        XCTAssertEqual(m.incoming?.title, "2 items")
        XCTAssertEqual(received, ["a.mov", "b.mov"])
    }

    /// A file that's in within a moment skips the progress view and goes straight to the card.
    func testQuickFileNeverShowsProgress() async {
        let m = model()
        m.arrival(.incoming(id: 1, name: "a.txt", from: "box", ip: "100.64.0.9", total: 5, index: 1, count: 1))
        m.arrival(.done(id: 1, saved: "a.txt", path: "/D/a.txt"))
        await wait(0.3)
        XCTAssertFalse(m.incomingShown)
        let shown = await eventually { m.incomingShown }
        XCTAssertTrue(shown)
        XCTAssertEqual(m.incoming?.state, .done)
    }

    /// A slow file shows beside the notch while it arrives.
    func testSlowFileShowsWhileArriving() async {
        let m = model()
        m.arrival(.incoming(id: 1, name: "big.mov", from: "box", ip: "100.64.0.9", total: 100, index: 1, count: 1))
        let shown = await eventually { m.incomingShown }
        XCTAssertTrue(shown)
        XCTAssertEqual(m.incoming?.state, .arriving)
    }

    /// A send that breaks off before showing leaves nothing on screen.
    func testFailureBeforeShowingLeavesNothing() async {
        let m = model()
        m.arrival(.incoming(id: 1, name: "a.mov", from: "box", ip: "100.64.0.9", total: 100, index: 1, count: 1))
        m.arrival(.failed(id: 1))
        let cleared = await eventually { m.incoming == nil }
        XCTAssertTrue(cleared)
        XCTAssertFalse(m.incomingShown)
    }

    /// Events from an older transfer don't move the current one.
    func testStaleEventsAreIgnored() {
        let m = model()
        m.arrival(.incoming(id: 2, name: "new.mov", from: "box", ip: "100.64.0.9", total: 100, index: 1, count: 1))
        m.arrival(.progress(id: 1, got: 90, total: 100))
        XCTAssertEqual(m.incoming?.progress, 0)
    }
}
