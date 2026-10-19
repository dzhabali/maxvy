import XCTest
@testable import Vajra

final class StatsTests: XCTestCase {
    private func day(count: [Int: Int] = [:], sleep: Range<Int>? = nil) -> [Slot] {
        var s = Slots.empty()
        for (i, n) in count { s[i].count = n }
        if let sleep { for i in sleep { s[i].sleep = true } }
        return s
    }

    func testDayTotalAndGoal() {
        let d = day(count: [0: 3, 40: 10, 95: 2])
        XCTAssertEqual(Slots.total(d), 15)
        XCTAssertEqual(VajraStats.goalPct(15), 15)
        XCTAssertEqual(VajraStats.goalPct(150), 100)
        XCTAssertEqual(VajraStats.footerColorHex(pct: 100), 0xf59e0b)
        XCTAssertEqual(VajraStats.footerColorHex(pct: 33), 0x94a3b8)
        XCTAssertEqual(VajraStats.scoreColorHex(100), 0xc0185a)
        XCTAssertEqual(VajraStats.scoreColorHex(51), 0x22c55e)
    }

    /// Среднее — без сегодняшнего дня и без нулевых; сумма/лучший/дней — с сегодня.
    func testMonthStatsAverageExcludesToday() {
        let days = ["2026-10-01": day(count: [1: 80]),
                    "2026-10-02": day(count: [1: 41]),
                    "2026-10-03": day(),
                    "2026-10-19": day(count: [1: 5])]
        let st = VajraStats.month(days, today: "2026-10-19")
        XCTAssertEqual(st.sum, 126)
        XCTAssertEqual(st.best, 80)
        XCTAssertEqual(st.days, 3)
        XCTAssertEqual(st.avg, 61)    // (80+41)/2 = 60.5 → Math.round → 61
        XCTAssertEqual(VajraStats.month([:], today: "2026-10-19"), .init(sum: nil, avg: nil, best: nil, days: nil))
    }

    func testSleepNightAndMonth() {
        let night = day(sleep: 0..<29)              // 0:00–7:15 → 29 слотов
        XCTAssertEqual(VajraStats.sleepMinutes(night), 435)
        XCTAssertEqual(VajraStats.fmtSleep(435), "7:15")
        XCTAssertNil(VajraStats.fmtSleep(0))
        let days = ["2026-10-01": day(sleep: 0..<29),   // 435
                    "2026-10-02": day(sleep: 0..<30),   // 450
                    "2026-10-03": day(),                // 0 — не считается
                    "2026-10-19": day(sleep: 0..<4)]    // сегодня — не считается
        // (435+450)/2 = 442.5 → /5 = 88.5 → round 89 → 445 = 7:25
        XCTAssertEqual(VajraStats.monthSleepAvg(days, today: "2026-10-19"), 445)
        XCTAssertNil(VajraStats.monthSleepAvg(["2026-10-19": night], today: "2026-10-19"))
    }

    func testQualityAndMilestones() {
        var d = Slots.empty()
        d[1].qc = 3; d[2].qm = 1; d[3].qa = 2
        let q = VajraStats.quality(d)
        XCTAssertEqual(q.n, 6)
        XCTAssertEqual(q.clearPct, 50)
        XCTAssertEqual(Milestone.crossed(prev: 24, total: 25, shown: [])?.n, 25)
        XCTAssertNil(Milestone.crossed(prev: 24, total: 25, shown: [25]))
        XCTAssertNil(Milestone.crossed(prev: 30, total: 31, shown: []))
        XCTAssertEqual(Milestone.crossed(prev: 99, total: 100, shown: [25, 50, 75])?.khechara, true)
    }

    func testTimerFormat() {
        XCTAssertEqual(AppModel.formatTimer(180), "3:00")
        XCTAssertEqual(AppModel.formatTimer(5), "0:05")
        XCTAssertEqual(AppModel.formatTimer(-75), "+1:15")
        XCTAssertEqual(AppModel.formatTimer(-3725), "+1:02")
    }
}

/// Модель сервера в памяти: тот же vajra_apply_ops (VajraOps), журнал applied, applied_tail.
final class FakeServer: VajraBackend {
    private let lock = NSLock()
    private var days: [String: (slots: [Slot], applied: [String], n: Int)] = [:]
    /// Применить следующую пачку, но «потерять» ответ (сеть оборвалась / процесс убит).
    var loseNextResponse = false
    var delayNs: UInt64 = 0
    private(set) var postSizes: [Int] = []

    private func day(_ d: String) -> ServerDay {
        let x = days[d] ?? (Slots.empty(), [], 0)
        return ServerDay(slots: x.slots, updatedAt: x.n == 0 ? nil : String(format: "2026-10-19T00:00:%06dZ", x.n), appliedTail: Array(x.applied.suffix(200)))
    }

    func slots(_ d: String) -> [Slot] { lock.withLock { days[d]?.slots ?? Slots.empty() } }

    func getDay(_ date: String) async throws -> ServerDay { lock.withLock { day(date) } }

    func postOps(_ date: String, _ ops: [Op]) async throws -> ServerDay {
        if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
        if ops.count > VajraOps.batch { throw SyncError.server(400) }
        let (r, lose): (ServerDay, Bool) = lock.withLock {
            postSizes.append(ops.count)
            var x = days[date] ?? (Slots.empty(), [], 0)
            let before = x.applied
            x.slots = VajraOps.apply(x.slots, ops, applied: &x.applied)
            if x.applied != before { x.n += 1 }
            days[date] = x
            let lose = loseNextResponse
            loseNextResponse = false
            return (day(date), lose)
        }
        if lose { throw SyncError.network }
        return r
    }

    func putDay(_ date: String, _ slots: [Slot]) async throws -> ServerDay {
        lock.withLock {
            var x = days[date] ?? (Slots.empty(), [], 0)
            x.slots = Slots.merge(x.slots, slots)
            x.n += 1
            days[date] = x
            return day(date)
        }
    }
}

/// Интент «+1», очередь операций и синк — на временном каталоге (как App Group), без UI и без сети.
final class IntentStoreTests: XCTestCase {
    private var dir: URL!
    private var store: DayStore!
    private let D = "2026-10-19"
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vajra-test-\(UUID().uuidString)", isDirectory: true)
        store = DayStore(dir: dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func at(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m, second: s))!
    }

    /// Эталон — прогон серверного vajra_apply_ops (Python) на тех же входах.
    func testOpsMatchPython() {
        let base = Slots.norm([["count": 2, "t": 10, "qm": 1], ["sleep": true, "t": 4]])
        let ops = [Op(id: "e1", kind: .add, i: 0, t: 5, count: -1, qc: 2, qm: -2),
                   Op(id: "e2", kind: .set, i: 1, t: 20, qa: 3, sleep: false, forgot: true),
                   Op(id: "e1", kind: .add, i: 0, t: 99, count: 9),
                   Op(id: "e3", kind: .set, i: 2, t: 0, count: 7)]
        var applied: [String] = []
        let out = VajraOps.apply(base, ops, applied: &applied)
        XCTAssertEqual(out[0], Slot(count: 1, t: 11, qc: 2))
        XCTAssertEqual(out[1], Slot(forgot: true, t: 20, qa: 3))
        XCTAssertEqual(out[2], Slot(count: 7, t: 1))
        XCTAssertEqual(applied, ["e1", "e2", "e3"])
        XCTAssertFalse(VajraOps.validID("bad id!"))
    }

    func testIncrementIsAddOnCurrentSlot() async {
        let now = at(19, 14, 20)
        let r1 = await RecollectionAction.increment(store: store, now: now, calendar: cal, api: nil)
        let r2 = await RecollectionAction.increment(store: store, now: now.addingTimeInterval(30), calendar: cal, api: nil)
        XCTAssertEqual(r1.total, 1)
        XCTAssertEqual(r2.total, 2)
        XCTAssertFalse(r2.sent)
        let rec = store.record(D)!
        XCTAssertEqual(rec.display[57].count, 2)
        XCTAssertEqual(rec.display[57].t, VajraDate.ms(now.addingTimeInterval(30)))
        XCTAssertEqual(rec.ops.count, 2)
        XCTAssertEqual(store.dirtyDates(), [D])
    }

    /// Через полночь: 23:59:59 — слот 95 вчерашнего дня, 00:00:01 — слот 0 нового; счёт не перетекает.
    func testMidnightGoesToNewDay() async {
        _ = await RecollectionAction.increment(store: store, now: at(19, 23, 59, 59), calendar: cal, api: nil)
        let r = await RecollectionAction.increment(store: store, now: at(20, 0, 0, 1), calendar: cal, api: nil)
        XCTAssertEqual(r.total, 1)
        XCTAssertEqual(store.slots(D)[95].count, 1)
        XCTAssertEqual(store.slots("2026-10-20")[0].count, 1)
        XCTAssertEqual(Set(store.dirtyDates()), [D, "2026-10-20"])
    }

    /// Интент с сервером: +1 ложится поверх серверных данных; очередь пуста; повтор отправки ничего не меняет.
    func testIntentSendsAndServerKeepsOthers() async {
        let srv = FakeServer()
        _ = try? await srv.postOps(D, [.set(40, SetFields(count: 5, sleep: true), t: 1)])
        let r = await RecollectionAction.increment(store: store, now: at(19, 10, 0), calendar: cal, api: srv)
        XCTAssertTrue(r.sent)
        XCTAssertEqual(r.total, 6)
        XCTAssertEqual(srv.slots(D)[40].count, 6)
        XCTAssertTrue(srv.slots(D)[40].sleep)
        XCTAssertTrue(store.record(D)!.ops.isEmpty)
    }

    /// A: PUT/POST дошёл, ответ потерян → повтор не задваивает; GET с applied_tail — без +2.
    func testLostResponseNoDoubleApply() async throws {
        let srv = FakeServer()
        srv.loseNextResponse = true
        let r = await RecollectionAction.increment(store: store, now: at(19, 10, 0), calendar: cal, api: srv)
        XCTAssertFalse(r.sent)
        XCTAssertEqual(srv.slots(D)[40].count, 1)          // сервер применил
        XCTAssertEqual(store.record(D)!.ops.count, 1)       // а мы не знаем
        // показ после GET: снимок уже содержит op, op в applied_tail → не накладываем повторно
        try await VajraSync.pullDay(store: store, api: srv, date: D)
        XCTAssertEqual(store.slots(D)[40].count, 1)
        XCTAssertTrue(store.record(D)!.ops.isEmpty)
        // повтор той же пачки (например, без GET) — сервер пропускает
        let rec = store.record(D)!
        _ = rec
        let srv2 = FakeServer()
        srv2.loseNextResponse = true
        let store2 = DayStore(dir: dir.appendingPathComponent("b"))
        _ = await RecollectionAction.increment(store: store2, now: at(19, 10, 0), calendar: cal, api: srv2)
        try await VajraSync.pushDay(store: store2, api: srv2, date: D)
        try await VajraSync.pushDay(store: store2, api: srv2, date: D)
        XCTAssertEqual(srv2.slots(D)[40].count, 1)
        XCTAssertEqual(store2.slots(D)[40].count, 1)
    }

    /// B: два параллельных push одной очереди (два процесса — два DayStore на одной папке, свои «шлюзы»).
    func testParallelPushesNoDoubleApply() async throws {
        let srv = FakeServer()
        srv.delayNs = 50_000_000
        for k in 0..<5 { store.add(D, i: 8, count: 1, nowMs: Int64(1_000 + k)) }
        let other = DayStore(dir: dir)
        let g1 = DaySyncGate(), g2 = DaySyncGate()
        async let a: Void = VajraSync.pushDay(store: store, api: srv, date: D, gate: g1)
        async let b: Void = VajraSync.pushDay(store: other, api: srv, date: D, gate: g2)
        async let c: Void = VajraSync.pushDay(store: store, api: srv, date: D, gate: g1)
        _ = try await (a, b, c)
        XCTAssertEqual(srv.slots(D)[8].count, 5)
        XCTAssertEqual(store.slots(D)[8].count, 5)
        XCTAssertTrue(store.record(D)!.ops.isEmpty)
    }

    /// Старый ответ (снимок старше локального) не откатывает показ.
    func testStaleSnapshotIgnored() async throws {
        let srv = FakeServer()
        store.add(D, i: 3, count: 2, nowMs: 10)
        let old = try await srv.getDay(D)
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        store.applyServer(D, old)
        XCTAssertEqual(store.slots(D)[3].count, 2)
    }

    /// set sleep не трогает count — и памятования с другого устройства не затираются.
    func testSetSleepKeepsCountFromOtherDevice() async throws {
        let srv = FakeServer()
        store.set(D, nowMs: 100, [(12, SetFields(sleep: true))])
        _ = try await srv.postOps(D, [.add(12, count: 3, t: 50)])       // веб/другой телефон, раньше нашей отметки
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertEqual(srv.slots(D)[12].count, 3)
        XCTAssertTrue(srv.slots(D)[12].sleep)
        XCTAssertEqual(store.slots(D)[12].count, 3)
    }

    /// Сон (set) → +1 из интента в тот же слот → ↶ НЕ трогает слот.
    func testUndoSkipsSlotChangedAfterwards() async {
        let now = at(19, 12, 0)
        let i = VajraDate.slotIndex(now, calendar: cal)
        let edit = store.set(D, nowMs: VajraDate.ms(now), [(i, SetFields(sleep: true))])
        XCTAssertEqual(edit.changes.count, 1)
        _ = await RecollectionAction.increment(store: store, now: now.addingTimeInterval(5), calendar: cal, api: nil)
        let r = store.revert(D, edit.changes, nowMs: VajraDate.ms(now.addingTimeInterval(10)))
        XCTAssertEqual(r.skipped, 1)
        XCTAssertTrue(r.slots[i].sleep)
        XCTAssertEqual(r.slots[i].count, 1)
    }

    /// Своё ↶ откатывает: set — прежние поля; +1 — обратной add, и после отправки тоже.
    func testUndoRevertsOwnChanges() async throws {
        let srv = FakeServer()
        _ = try await srv.postOps(D, [.add(8, count: 4, t: 50)])
        try await VajraSync.pullDay(store: store, api: srv, date: D)
        let e1 = store.set(D, nowMs: 1_000, [(7, SetFields(forgot: true))])
        XCTAssertEqual(store.revert(D, e1.changes, nowMs: 2_000).skipped, 0)
        XCTAssertFalse(store.slots(D)[7].forgot)
        let plus = store.add(D, i: 8, count: 1, nowMs: 3_000)
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertEqual(store.slots(D)[8].count, 5)
        store.revert(D, [plus.change], nowMs: 4_000)
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertEqual(srv.slots(D)[8].count, 4)
        XCTAssertFalse(srv.slots(D)[7].forgot)
    }

    func testResetDayUsesTAboveDayMax() async throws {
        let srv = FakeServer()
        _ = try await srv.postOps(D, [.add(1, count: 2, qc: 1, t: 9_999_999_999_999)])
        try await VajraSync.pullDay(store: store, api: srv, date: D)
        let r = store.resetDay(D, nowMs: 1_000)
        XCTAssertTrue(r.slots.allSatisfy { $0.count == 0 && $0.qc == 0 && !$0.sleep })
        XCTAssertEqual(r.slots[1].t, 10_000_000_000_000)
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertEqual(srv.slots(D)[1].count, 0)
    }

    func testPruneKeepsPendingAndRecent() {
        store.put("2026-07-01", .init(slots: Slots.empty(), updatedAt: nil))
        store.put("2026-07-03", .init(slots: Slots.empty(), updatedAt: nil, ops: [.add(0, count: 1, t: 1)]))
        store.put("2026-10-01", .init(slots: Slots.empty(), updatedAt: nil))
        store.prune(today: D)
        XCTAssertEqual(store.allDates(), ["2026-07-03", "2026-10-01"])
    }

    /// Миграция билда 2: deltas → add с теми же id/t; dirty-снимок — один раз старым PUT.
    func testMigrationFromBuild2() async throws {
        let legacy: [String: Any] = [
            "slots": Slots.toJSON({ var s = Slots.empty(); s[2] = Slot(sleep: true, t: 7_000); return s }()),
            "dirty": true, "synced": true, "updatedAt": "2026-10-19T08:00:00Z",
            "deltas": [["id": "D-1", "i": 9, "count": 1, "qc": 1, "qm": 0, "qa": 0, "t": 8_000]],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: dir.appendingPathComponent(D + ".json"))
        let rec = store.record(D)!
        XCTAssertTrue(rec.legacyDirty)
        XCTAssertEqual(rec.ops, [Op(id: "D-1", kind: .add, i: 9, t: 8_000, count: 1, qc: 1, qm: 0, qa: 0)])
        XCTAssertEqual(rec.display[9].count, 1)
        let srv = FakeServer()
        _ = try await srv.postOps(D, [.add(2, count: 4, t: 100)])            // на сервере уже были памятования
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertTrue(srv.slots(D)[2].sleep)                                 // PUT слил снимок по t
        XCTAssertEqual(srv.slots(D)[9].count, 1)
        XCTAssertEqual(srv.slots(D)[9].qc, 1)
        let after = store.record(D)!
        XCTAssertFalse(after.legacyDirty)
        XCTAssertTrue(after.ops.isEmpty)
        try await VajraSync.pushDay(store: store, api: srv, date: D)       // повтор — ничего не задваивает
        XCTAssertEqual(srv.slots(D)[9].count, 1)
    }

    /// Очередь > 200 уходит кусками по 200.
    func testPushInChunks() async throws {
        let srv = FakeServer()
        for k in 0..<250 { store.add(D, i: 4, count: 1, nowMs: Int64(k + 1)) }
        try await VajraSync.pushDay(store: store, api: srv, date: D)
        XCTAssertEqual(srv.postSizes, [200, 50])
        XCTAssertEqual(srv.slots(D)[4].count, 250)
        XCTAssertTrue(store.record(D)!.ops.isEmpty)
    }

    /// Устаревший set (op.t < t слота) не применяется — и в Swift, и на сервере (id записан).
    func testStaleSetIgnored() {
        var s = Slots.empty(); s[7] = Slot(count: 10, t: 2_000)
        var applied: [String] = []
        let out = VajraOps.apply(s, [Op(id: "st1", kind: .set, i: 7, t: 1_000, count: 0), Op(id: "st2", kind: .add, i: 7, t: 1_000, count: 1)], applied: &applied)
        XCTAssertEqual(out[7], Slot(count: 11, t: 2_001))
        XCTAssertEqual(applied, ["st1", "st2"])
        var a2: [String] = []
        XCTAssertEqual(VajraOps.apply(s, [Op(id: "big", kind: .add, i: 7, t: 1, count: 100_001)], applied: &a2)[7].count, 10)
    }

    func testISOCompareMixedFormats() {
        XCTAssertTrue(VajraDate.isoLess("2026-01-01T01:01:01Z", "2026-01-01T01:01:01.000005Z"))
        XCTAssertFalse(VajraDate.isoLess("2026-01-01T01:01:01.000005Z", "2026-01-01T01:01:01Z"))
        XCTAssertTrue(VajraDate.isoLess("2026-01-01T01:01:01.5Z", "2026-01-01T01:01:02Z"))
    }

    func testConcurrentIncrementsAreNotLost() async {
        let now = at(19, 9, 0)
        await withTaskGroup(of: Void.self) { g in
            for k in 0..<40 {
                g.addTask { _ = await RecollectionAction.increment(store: self.store, now: now.addingTimeInterval(Double(k)), calendar: self.cal, api: nil) }
            }
        }
        XCTAssertEqual(store.slots(D)[36].count, 40)
    }
}
