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

/// Интент «+1» и хранилище на временном каталоге (как App Group), без UI и без сети.
final class IntentStoreTests: XCTestCase {
    private var dir: URL!
    private var store: DayStore!
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

    private let D = "2026-10-19"

    func testIncrementIsDeltaOnCurrentSlot() async {
        let now = at(19, 14, 20)
        let r1 = await RecollectionAction.increment(store: store, now: now, calendar: cal, api: nil)
        let r2 = await RecollectionAction.increment(store: store, now: now.addingTimeInterval(30), calendar: cal, api: nil)
        XCTAssertEqual(r1.total, 1)
        XCTAssertEqual(r2.total, 2)
        XCTAssertFalse(r2.sent)
        let rec = store.record(D)!
        XCTAssertEqual(rec.display[57].count, 2)
        XCTAssertEqual(rec.display[57].t, VajraDate.ms(now.addingTimeInterval(30)))
        XCTAssertEqual(rec.slots[57].count, 0)          // база не тронута — только дельты
        XCTAssertEqual(rec.deltas.count, 2)
        XCTAssertFalse(rec.synced)
        XCTAssertEqual(store.dirtyDates(), [D])
    }

    /// Через полночь: 23:59:59 — слот 95 вчерашнего дня, 00:00:01 — слот 0 нового; счёт не перетекает.
    func testMidnightGoesToNewDay() async {
        _ = await RecollectionAction.increment(store: store, now: at(19, 23, 59, 59), calendar: cal, api: nil)
        let r = await RecollectionAction.increment(store: store, now: at(20, 0, 0, 1), calendar: cal, api: nil)
        XCTAssertEqual(r.total, 1)
        XCTAssertEqual(store.slots(D)[95].count, 1)
        XCTAssertEqual(store.slots("2026-10-20")[0].count, 1)
        XCTAssertEqual(Slots.total(store.slots(D)), 1)
        XCTAssertEqual(Set(store.dirtyDates()), [D, "2026-10-20"])
    }

    /// Незагруженный день: +1 ложится на СВЕЖИЙ серверный слот, а не затирает его пустой базой.
    func testDeltaOnUnsyncedDayAddsToServer() async {
        _ = await RecollectionAction.increment(store: store, now: at(19, 10, 0), calendar: cal, api: nil)
        var server = Slots.empty()
        server[40] = Slot(count: 5, sleep: true, t: 1_000)
        server[3] = Slot(count: 2, t: 7)
        let rec = store.record(D)!
        let body = DayStore.pushBody(rec, server: server)
        XCTAssertEqual(body[40].count, 6)
        XCTAssertTrue(body[40].sleep)
        XCTAssertEqual(body[40].t, rec.deltas[0].t)        // t дельты новее серверного
        XCTAssertEqual(body[3], Slot(count: 2, t: 7))
        // сервер ответил тем же — дельты сняты, день чистый и загруженный
        store.commitPush(D, response: body, updatedAt: "x", sentDeltaIds: Set(rec.deltas.map(\.id)))
        let after = store.record(D)!
        XCTAssertTrue(after.deltas.isEmpty)
        XCTAssertFalse(after.dirty)
        XCTAssertTrue(after.synced)
        XCTAssertEqual(after.display[40].count, 6)
    }

    /// Серверный t новее дельты → t = серверный + 1; дельта, добавленная во время запроса, остаётся.
    func testPushTAndDeltaAddedDuringRequest() {
        store.addDelta(D, i: 10, count: 1, nowMs: 100)
        let rec = store.record(D)!
        var server = Slots.empty(); server[10] = Slot(count: 3, t: 500)
        let body = DayStore.pushBody(rec, server: server)
        XCTAssertEqual(body[10].count, 4)
        XCTAssertEqual(body[10].t, 501)
        store.addDelta(D, i: 10, count: 1, nowMs: 200)          // пришла во время PUT
        store.commitPush(D, response: body, updatedAt: nil, sentDeltaIds: Set(rec.deltas.map(\.id)))
        let after = store.record(D)!
        XCTAssertEqual(after.deltas.count, 1)
        XCTAssertEqual(after.display[10].count, 5)
        XCTAssertTrue(after.needsPush)
    }

    func testMinusDeltaClampsAtZero() {
        var server = Slots.empty(); server[5] = Slot(count: 1, t: 3)
        let ds = [Delta(id: "a", i: 5, count: -1, t: 10), Delta(id: "b", i: 5, count: -1, t: 11)]
        XCTAssertEqual(DayStore.applyForPush(ds, to: server)[5].count, 0)
    }

    /// Правка (Сон) → +1 из интента в тот же слот → ↶ НЕ трогает слот.
    func testUndoSkipsSlotChangedByIntentAfterwards() async {
        store.applyServer(D, slots: Slots.empty(), updatedAt: nil)
        let now = at(19, 12, 0)
        let i = VajraDate.slotIndex(now, calendar: cal)
        let edit = store.setSlots(D, nowMs: VajraDate.ms(now)) { $0[i].sleep = true }
        XCTAssertEqual(edit.changes.count, 1)
        _ = await RecollectionAction.increment(store: store, now: now.addingTimeInterval(5), calendar: cal, api: nil)
        let r = store.revert(D, edit.changes, nowMs: VajraDate.ms(now.addingTimeInterval(10)))
        XCTAssertEqual(r.skipped, 1)
        XCTAssertTrue(r.slots[i].sleep)
        XCTAssertEqual(r.slots[i].count, 1)
    }

    /// Свою нетронутую правку ↶ откатывает; +1 откатывается обратной дельтой (и после отправки тоже).
    func testUndoRevertsOwnChanges() {
        store.applyServer(D, slots: Slots.empty(), updatedAt: nil)
        let e1 = store.setSlots(D, nowMs: 1_000) { $0[7].forgot = true }
        XCTAssertEqual(store.revert(D, e1.changes, nowMs: 2_000).skipped, 0)
        XCTAssertFalse(store.slots(D)[7].forgot)

        var server = Slots.empty(); server[8] = Slot(count: 4, t: 50)
        store.applyServer(D, slots: server, updatedAt: nil)
        let plus = store.addDelta(D, i: 8, count: 1, nowMs: 3_000)
        let rec = store.record(D)!
        store.commitPush(D, response: DayStore.pushBody(rec, server: server), updatedAt: nil, sentDeltaIds: Set(rec.deltas.map(\.id)))
        XCTAssertEqual(store.slots(D)[8].count, 5)
        let r = store.revert(D, [plus.change], nowMs: 4_000)
        XCTAssertEqual(r.skipped, 0)
        XCTAssertEqual(r.slots[8].count, 4)
    }

    func testResetDayUsesTAboveDayMax() {
        var server = Slots.empty(); server[1] = Slot(count: 2, t: 9_999_999_999_999)
        store.applyServer(D, slots: server, updatedAt: nil)
        let r = store.resetDay(D, nowMs: 1_000)
        XCTAssertTrue(r.slots.allSatisfy { $0.t == 10_000_000_000_000 && $0.count == 0 })
        XCTAssertEqual(Slots.merge(r.slots, server)[1].count, 0)
    }

    func testPruneKeepsPendingAndRecent() {
        store.put("2026-07-01", .init(slots: Slots.empty(), updatedAt: nil, dirty: false, synced: true))
        store.put("2026-07-02", .init(slots: Slots.empty(), updatedAt: nil, dirty: true, synced: true))
        store.put("2026-07-03", .init(slots: Slots.empty(), updatedAt: nil, dirty: false, synced: false,
                                      deltas: [Delta(id: "x", i: 0, count: 1, t: 1)]))
        store.put("2026-10-01", .init(slots: Slots.empty(), updatedAt: nil, dirty: false, synced: true))
        store.prune(today: D)
        XCTAssertEqual(store.allDates(), ["2026-07-02", "2026-07-03", "2026-10-01"])
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
