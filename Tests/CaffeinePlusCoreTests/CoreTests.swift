import AppKit
import XCTest
@testable import CaffeinePlusCore

final class FakeAssertion: PowerAssertionHandling {
    var isHeld = false
    func acquire(reason: String) { self.isHeld = true }
    func release() { self.isHeld = false }
}

final class FakeWaker: WakeScheduling {
    var calls: [[Date]] = []
    func sync(wakes: [Date]) async -> WakeStatus { self.calls.append(wakes); return .ready }
    func checkAvailability() async -> WakeStatus { .ready }
}

final class FakeRunner: CommandRunning {
    var commands: [[String]] = []
    var allowed = true
    var delayNanos: UInt64 = 0
    func run(_ launchPath: String, _ arguments: [String]) async -> Int32 {
        if self.delayNanos > 0 { try? await Task.sleep(nanoseconds: self.delayNanos) }
        self.commands.append(arguments)
        return self.allowed ? 0 : 1
    }
}

private func window(_ id: String, start: Date, minutes: Int = 30, lead: Int = 5,
                    recurrence: Recurrence = .none, zone: String = "Europe/Madrid") -> ScheduleWindow
{
    ScheduleWindow(id: id, title: id, start: start, timeZoneID: zone, durationMinutes: minutes,
                   leadMinutes: lead, recurrence: recurrence, enabled: true, source: "test", updatedAt: start)
}

private func date(_ text: String, zone: String = "Europe/Madrid") -> Date {
    MCPRouter.parseDate(text, zone: TimeZone(identifier: zone)!)!
}

final class EngineTests: XCTestCase {
    func testValidation() {
        XCTAssertThrowsError(try window("a", start: Date(), minutes: 0).validate())
        XCTAssertThrowsError(try window("", start: Date()).validate())
        XCTAssertThrowsError(try window("a", start: Date(), recurrence: .weekly([])).validate())
        XCTAssertNoThrow(try window("a", start: Date()).validate())
    }

    func testWeeklyOccurrences() {
        let w = window("w", start: date("2026-11-16T09:00"), recurrence: .weekly([.mon, .thu]))
        let occ = ScheduleEngine.occurrences(of: w, from: date("2026-11-17T00:00"), to: date("2026-11-25T00:00"))
        XCTAssertEqual(occ.map(\.start), [date("2026-11-19T09:00"), date("2026-11-23T09:00")])
        XCTAssertEqual(occ[0].wakeAt, date("2026-11-19T08:55"))
    }

    func testDailyAcrossDST() {
        // Spain leaves DST on 2026-10-25: 09:00 local must stay 09:00 local.
        let w = window("d", start: date("2026-10-24T09:00"), recurrence: .daily)
        let occ = ScheduleEngine.occurrences(of: w, from: date("2026-10-24T00:00"), to: date("2026-10-27T00:00"))
        XCTAssertEqual(occ.map(\.start), [date("2026-10-24T09:00"), date("2026-10-25T09:00"), date("2026-10-26T09:00")])
    }

    func testRecurringNotBeforeFirstStart() {
        let w = window("d", start: date("2026-11-20T09:00"), recurrence: .daily)
        let occ = ScheduleEngine.occurrences(of: w, from: date("2026-11-18T00:00"), to: date("2026-11-21T23:00"))
        XCTAssertEqual(occ.first?.start, date("2026-11-20T09:00"))
    }

    func testOvernightWindowStillActive() {
        let w = window("n", start: date("2026-11-19T23:30"), minutes: 120, recurrence: .daily)
        let now = date("2026-11-20T00:30")
        let occ = ScheduleEngine.occurrences(of: w, from: now, to: now.addingTimeInterval(1))
        XCTAssertEqual(occ.count, 1)
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json")
    }

    func testUpsertIsIdempotentAndPersists() throws {
        let url = tempURL()
        let store = ScheduleStore(fileURL: url)
        try store.upsert(window("a", start: date("2026-11-20T09:00")))
        try store.upsert(window("a", start: date("2026-11-20T10:00")))
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertEqual(ScheduleStore(fileURL: url).windows.first?.start, date("2026-11-20T10:00"))
    }

    func testCorruptFileStartsEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: url)
        XCTAssertTrue(ScheduleStore(fileURL: url).windows.isEmpty)
    }
}

@MainActor
final class PowerTests: XCTestCase {
    var now = date("2026-11-20T08:00")

    func make(_ windows: [ScheduleWindow]) throws -> (PowerController, FakeAssertion, FakeWaker, ScheduleStore) {
        let store = ScheduleStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json"))
        for w in windows { try store.upsert(w) }
        let assertion = FakeAssertion(), waker = FakeWaker()
        let power = PowerController(store: store, assertion: assertion, waker: waker,
                                    clock: { [unowned self] in self.now }, observeSystem: false)
        return (power, assertion, waker, store)
    }

    func testHoldsFromWakeUntilEndAndReleases() throws {
        let (power, assertion, _, _) = try make([window("a", start: date("2026-11-20T09:00"))])
        power.reconcile()
        XCTAssertFalse(assertion.isHeld)
        now = date("2026-11-20T08:56"); power.reconcile()
        XCTAssertTrue(assertion.isHeld)
        now = date("2026-11-20T09:30"); power.reconcile()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(power.upcoming.first?.state, .finished)
    }

    func testOverlapKeepsAssertionUntilLastEnds() throws {
        let (power, assertion, _, _) = try make([
            window("a", start: date("2026-11-20T09:00"), minutes: 30),
            window("b", start: date("2026-11-20T09:15"), minutes: 60),
        ])
        now = date("2026-11-20T09:20"); power.reconcile()
        XCTAssertTrue(assertion.isHeld)
        now = date("2026-11-20T09:40"); power.reconcile()
        XCTAssertTrue(assertion.isHeld)
        now = date("2026-11-20T10:30"); power.reconcile()
        XCTAssertFalse(assertion.isHeld)
    }

    func testWakeAfterWindowEndedDoesNotHold() throws {
        let (power, assertion, _, _) = try make([window("a", start: date("2026-11-20T09:00"))])
        now = date("2026-11-20T09:10"); power.reconcile()
        XCTAssertTrue(assertion.isHeld)
        now = date("2026-11-20T12:00"); power.reconcile() // slept through the end
        XCTAssertFalse(assertion.isHeld)
    }

    func testDisablingReleasesAndSkipDoesNotReactivate() throws {
        let (power, assertion, _, store) = try make([window("a", start: date("2026-11-20T09:00"))])
        now = date("2026-11-20T09:10"); power.reconcile()
        XCTAssertTrue(assertion.isHeld)
        power.skip(occurrenceID: power.upcoming[0].id)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(power.upcoming.first?.state, .skipped)
        try store.setEnabled(id: "a", enabled: false); power.reconcile()
        XCTAssertTrue(power.upcoming.isEmpty)
    }

    func testSchedulesWakeForFutureWindows() async throws {
        let (power, _, waker, _) = try make([window("a", start: date("2026-11-20T09:00"))])
        power.reconcile()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(waker.calls.last, [date("2026-11-20T08:55")])
    }
}

final class WakeTests: XCTestCase {
    func testSchedulesAndCancelsOnlyOwnEvents() async {
        let runner = FakeRunner()
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let now = date("2026-11-20T08:00")
        let scheduler = PmsetSudoWakeScheduler(runner: runner, ledgerURL: ledger, now: { now })
        let a = date("2026-11-20T08:55"), b = date("2026-11-21T08:55")
        _ = await scheduler.sync(wakes: [a, b])
        runner.commands.removeAll()
        _ = await scheduler.sync(wakes: [b])
        let cancels = runner.commands.filter { $0.contains("cancel") }
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.last, "11/20/26 08:55:00")
        XCTAssertFalse(runner.commands.contains { $0.contains("wake") && !$0.contains("cancel") && $0.last == "11/21/26 08:55:00" })
    }

    func testUnavailableWithoutRule() async {
        let runner = FakeRunner(); runner.allowed = false
        let scheduler = PmsetSudoWakeScheduler(runner: runner, ledgerURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        let status = await scheduler.sync(wakes: [Date().addingTimeInterval(3600)])
        if case .unavailable = status {} else { XCTFail("expected unavailable") }
        XCTAssertEqual(runner.commands.count, 1) // only the probe
    }

    func testSudoersRuleRejectsOddUsernames() {
        XCTAssertNil(SudoersInstaller.rule(for: "a b; rm"))
        XCTAssertNotNil(SudoersInstaller.rule(for: "ruben"))
    }
}

@MainActor
final class MCPTests: XCTestCase {
    func router() -> (MCPRouter, ScheduleStore) {
        let store = ScheduleStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json"))
        let power = PowerController(store: store, assertion: FakeAssertion(), waker: FakeWaker(), observeSystem: false)
        return (MCPRouter(store: store, power: power), store)
    }

    func rpc(_ r: MCPRouter, _ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try! JSONSerialization.jsonObject(with: r.handle(body)!) as! [String: Any]
    }

    func testListsToolsAndUpsert() {
        let (r, store) = router()
        let tools = (rpc(r, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }), ["list_windows", "upsert_window", "delete_window", "get_status"])
        let res = rpc(r, "tools/call", ["name": "upsert_window", "arguments": [
            "id": "task-1", "start": "2026-12-01T09:00", "duration_minutes": 20,
            "timezone": "Europe/Madrid", "recurrence": ["type": "weekly", "days": ["mon"]],
        ]])
        XCTAssertEqual((res["result"] as! [String: Any])["isError"] as? Bool, false)
        XCTAssertEqual(store.windows.first?.recurrence, .weekly([.mon]))
        _ = rpc(r, "tools/call", ["name": "delete_window", "arguments": ["id": "task-1"]])
        XCTAssertTrue(store.windows.isEmpty)
    }

    func testValidationErrorIsToolError() {
        let (r, _) = router()
        let res = rpc(r, "tools/call", ["name": "upsert_window", "arguments": ["id": "x", "start": "2026-12-01T09:00", "duration_minutes": 0]])
        XCTAssertEqual((res["result"] as! [String: Any])["isError"] as? Bool, true)
    }

    func testNotificationHasNoResponse() {
        let (r, _) = router()
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(r.handle(body))
    }

    func testHTTPRequestParsing() {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertNil(HTTPRequest(parsing: raw.dropLast()))
        let req = HTTPRequest(parsing: raw)
        XCTAssertEqual(req?.path, "/mcp"); XCTAssertEqual(req?.body, Data("{}".utf8))
        XCTAssertTrue(MCPHTTPServer.isLoopbackHost("http://localhost:3000"))
        XCTAssertFalse(MCPHTTPServer.isLoopbackHost("evil.com"))
    }
}

@MainActor
final class DraftTests: XCTestCase {
    func testNewDraftIsValidAndRoundTrips() throws {
        var draft = WindowDraft(newAt: date("2026-11-20T08:07"))
        XCTAssertEqual(draft.start, date("2026-11-20T08:30"))
        draft.title = "  Informe "
        draft.kind = .weekly
        draft.days = [.thu, .mon]
        let window = try draft.makeWindow()
        XCTAssertEqual(window.title, "Informe")
        XCTAssertEqual(window.recurrence.days, [.mon, .thu])
        XCTAssertEqual(WindowDraft(window).id, draft.id)
        XCTAssertFalse(WindowDraft(window).isNew)
    }

    func testInvalidDraftsRejected() {
        var draft = WindowDraft(newAt: Date())
        draft.durationMinutes = 0
        XCTAssertThrowsError(try draft.makeWindow())
        draft.durationMinutes = 10; draft.kind = .weekly; draft.days = []
        XCTAssertThrowsError(try draft.makeWindow())
    }

    func testEditedWindowReplacesOriginal() throws {
        let store = ScheduleStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json"))
        try store.upsert(window("a", start: date("2026-11-20T09:00")))
        var draft = WindowDraft(store.windows[0])
        draft.start = date("2026-11-20T10:00")
        try store.upsert(draft.makeWindow())
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertEqual(store.windows[0].start, date("2026-11-20T10:00"))
    }
}

@MainActor
final class ExtraTests: XCTestCase {
    func store() -> ScheduleStore {
        ScheduleStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json"))
    }

    func testDisabledWindowHasNoOccurrences() {
        var w = window("a", start: date("2026-11-20T09:00"))
        w.enabled = false
        XCTAssertTrue(ScheduleEngine.occurrences(of: w, from: date("2026-11-20T00:00"), to: date("2026-11-21T00:00")).isEmpty)
    }

    func testOneOffOutsideRangeIsExcluded() {
        let w = window("a", start: date("2026-11-20T09:00"))
        XCTAssertTrue(ScheduleEngine.occurrences(of: w, from: date("2026-11-21T00:00"), to: date("2026-11-22T00:00")).isEmpty)
    }

    func testStoreDeleteAndSetEnabled() throws {
        let s = store()
        try s.upsert(window("a", start: date("2026-11-20T09:00")))
        try s.setEnabled(id: "a", enabled: false)
        XCTAssertEqual(s.window(id: "a")?.enabled, false)
        XCTAssertTrue(try s.delete(id: "a"))
        XCTAssertFalse(try s.delete(id: "a"))
    }

    func testInterruptedStateWhenSleepSpansTheEnd() throws {
        var now = date("2026-11-20T09:10")
        let s = store()
        try s.upsert(window("a", start: date("2026-11-20T09:00")))
        let power = PowerController(store: s, assertion: FakeAssertion(), waker: FakeWaker(),
                                    clock: { now }, observeSystem: true)
        power.reconcile()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let expectation = XCTestExpectation(description: "willSleep handled")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            now = date("2026-11-20T11:00"); power.reconcile()
            XCTAssertEqual(power.upcoming.first?.state, .interrupted)
            power.stop()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testRouterErrors() {
        let s = store()
        let power = PowerController(store: s, assertion: FakeAssertion(), waker: FakeWaker(), observeSystem: false)
        let r = MCPRouter(store: s, power: power)
        func call(_ args: [String: Any], tool: String = "upsert_window") -> Bool {
            let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": args]])
            let res = try! JSONSerialization.jsonObject(with: r.handle(body)!) as! [String: Any]
            return (res["result"] as! [String: Any])["isError"] as! Bool
        }
        XCTAssertTrue(call(["id": "x", "start": "mañana", "duration_minutes": 5]))
        XCTAssertTrue(call(["id": "x", "start": "2026-12-01T09:00", "duration_minutes": 5, "timezone": "Mars/Base"]))
        XCTAssertTrue(call(["id": "x", "start": "2026-12-01T09:00", "duration_minutes": 5,
                            "recurrence": ["type": "weekly", "days": ["funday"]]]))
        XCTAssertTrue(call([:], tool: "nope"))
        XCTAssertTrue(s.windows.isEmpty)
        XCTAssertFalse(call(["id": "x", "start": "2026-12-01T09:00:00+01:00", "duration_minutes": 5]))
        XCTAssertFalse(call(["id": "x", "title": "Nuevo título", "start": "2026-12-01T10:00", "duration_minutes": 5]))
        XCTAssertEqual(s.windows.first?.title, "Nuevo título")
    }

    func testRouterRejectsGarbageAndUnknownMethod() {
        let s = store()
        let power = PowerController(store: s, assertion: FakeAssertion(), waker: FakeWaker(), observeSystem: false)
        let r = MCPRouter(store: s, power: power)
        let garbage = try! JSONSerialization.jsonObject(with: r.handle(Data("no json".utf8))!) as! [String: Any]
        XCTAssertEqual((garbage["error"] as! [String: Any])["code"] as? Int, -32700)
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 9, "method": "bogus"])
        let res = try! JSONSerialization.jsonObject(with: r.handle(body)!) as! [String: Any]
        XCTAssertEqual((res["error"] as! [String: Any])["code"] as? Int, -32601)
    }

    func testTokenFileIsCreatedPrivateAndStable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tok")
        let first = MCPHTTPServer.loadOrCreateToken(at: url)
        XCTAssertGreaterThanOrEqual(first.count, 32)
        XCTAssertEqual(MCPHTTPServer.loadOrCreateToken(at: url), first)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testHTTPServerEndToEnd() async throws {
        let server = MCPHTTPServer(port: 47990, token: "secret-token") { body in Data("{\"echo\":true}".utf8) }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func send(_ method: String, token: String?, extra: [String: String] = [:]) async throws -> Int {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:47990/mcp")!)
            req.httpMethod = method
            if method == "POST" { req.httpBody = Data("{}".utf8) }
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as! HTTPURLResponse).statusCode
        }
        let noToken = try await send("POST", token: nil)
        let badToken = try await send("POST", token: "wrong")
        let ok = try await send("POST", token: "secret-token")
        let get = try await send("GET", token: "secret-token")
        let origin = try await send("POST", token: "secret-token", extra: ["Origin": "https://evil.example"])
        XCTAssertEqual([noToken, badToken, ok, get, origin], [401, 401, 200, 405, 403])
    }
}

final class WakeConcurrencyTests: XCTestCase {
    func testConcurrentSyncsDoNotDuplicateEvents() async {
        let runner = FakeRunner(); runner.delayNanos = 5_000_000
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let now = date("2026-11-20T08:00")
        let scheduler = PmsetSudoWakeScheduler(runner: runner, ledgerURL: ledger, now: { now })
        let wakes = [date("2026-11-20T08:55"), date("2026-11-21T08:55")]
        async let a = scheduler.sync(wakes: wakes)
        async let b = scheduler.sync(wakes: wakes)
        async let c = scheduler.sync(wakes: wakes)
        _ = await (a, b, c)
        let schedules = runner.commands.filter { $0.contains("wake") && !$0.contains("cancel") && !$0.contains("-l") }
        XCTAssertEqual(schedules.count, 2)
    }
}
