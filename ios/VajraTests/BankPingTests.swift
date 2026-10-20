import XCTest
@testable import Vajra

/// Мешок, расписание пингов, ответ на пинг, карточка. Строки — выдуманные («тест N»).
final class BankPingTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vajra-bank-\(UUID().uuidString)", isDirectory: true)
        suite = "vajra.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func vienna() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }

    private func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: мешок

    func testBagNoRepeatsThenRestarts() {
        var rng = DemoData.SplitMix(seed: 7)
        var bag = ShuffleBag()
        let ids = (1...5).map { "тест \($0)" }
        let round1 = (0..<5).compactMap { _ in bag.next(ids, using: &rng) }
        XCTAssertEqual(Set(round1), Set(ids))
        let round2 = (0..<5).compactMap { _ in bag.next(ids, using: &rng) }
        XCTAssertEqual(Set(round2), Set(ids))
        XCTAssertNotEqual(round1.last, round2.first)
        XCTAssertNil(bag.next([], using: &rng))
    }

    func testBagKeepsShownWhenSetChanges() {
        var rng = DemoData.SplitMix(seed: 3)
        var bag = ShuffleBag()
        let a = bag.next(["тест 1", "тест 2", "тест 3"], using: &rng)!
        let rest = (0..<3).compactMap { _ in bag.next(["тест 1", "тест 2", "тест 3", "тест 4"], using: &rng) }
        XCTAssertFalse(rest.contains(a))
        XCTAssertEqual(Set(rest + [a]), ["тест 1", "тест 2", "тест 3", "тест 4"])
    }

    func testBagPersistsInDefaults() {
        let store = BankStore(dir: dir, defaults: defaults)
        let ids = ["тест 1", "тест 2", "тест 3"]
        var got: [String] = []
        for _ in 0..<3 {
            let s2 = BankStore(dir: dir, defaults: defaults)   // новое чтение состояния
            got.append(s2.draw("x", ids: ids)!)
        }
        XCTAssertEqual(Set(got), Set(ids))
        XCTAssertEqual(store.nextPrompt().q, Bank.neutralQuestion)
    }

    func testBankDecodesWithAndWithoutSrc() throws {
        let js = #"{"version":2,"views":[{"id":"a","text":"тест 1","tag":"x","src":"источник 1"},{"id":"b","text":"тест 2","tag":"y"}],"prompts":[{"id":"p","q":"тест 3","hint":"тест 4","tag":"z"}]}"#
        let b = try JSONDecoder().decode(Bank.self, from: Data(js.utf8))
        XCTAssertEqual(b.views[0].src, "источник 1")
        XCTAssertNil(b.views[1].src)
        XCTAssertEqual(b.prompts[0].hint, "тест 4")
    }

    func testQuotePickStablePerSlotAndFiltered() {
        let vs = [Bank.ViewCard(id: "a", text: String(repeating: "т", count: 80), tag: nil),
                  Bank.ViewCard(id: "b", text: String(repeating: "е", count: 100), tag: nil),
                  Bank.ViewCard(id: "c", text: String(repeating: "с", count: 150), tag: nil),
                  Bank.ViewCard(id: "d", text: "тест 4", tag: nil)]
        let p1 = QuotePick.pick(vs, maxLen: QuotePick.lockMax, date: "2026-10-20", slot: 40)
        XCTAssertEqual(p1, QuotePick.pick(vs, maxLen: QuotePick.lockMax, date: "2026-10-20", slot: 40))
        for slot in 0..<96 {
            XCTAssertTrue(["a", "d"].contains(QuotePick.pick(vs, maxLen: 90, date: "2026-10-20", slot: slot)!.id))
            XCTAssertNotEqual(QuotePick.pick(vs, maxLen: 160, date: "2026-10-21", slot: slot)!.id, "")
        }
        let ids = Set((0..<96).map { QuotePick.pick(vs, maxLen: 160, date: "2026-10-20", slot: $0)!.id })
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
        XCTAssertNil(QuotePick.pick([], maxLen: 90, date: "2026-10-20", slot: 1))
        XCTAssertNil(QuotePick.pick([vs[2]], maxLen: 90, date: "2026-10-20", slot: 1))
        XCTAssertEqual(QuotePick.hash("тест"), QuotePick.hash("тест"))
    }

    @MainActor
    func testIdleTimerLogic() {
        XCTAssertTrue(IdleTimer.disabled(active: true, keepAwake: true))
        XCTAssertFalse(IdleTimer.disabled(active: false, keepAwake: true))
        XCTAssertFalse(IdleTimer.disabled(active: true, keepAwake: false))
        XCTAssertTrue(VajraSettings(defaults: defaults).keepAwake)   // по умолчанию вкл
    }

    // MARK: таймер 3:00 в группе

    func testIntentAndPingResetTimer() async {
        let store = DayStore(dir: dir.appendingPathComponent("days"))
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await RecollectionAction.increment(store: store, now: t1, api: nil, timerDefaults: defaults)
        XCTAssertEqual(VajraTimer.start(defaults: defaults), t1.timeIntervalSince1970)
        let t2 = t1.addingTimeInterval(60)
        PingAnswer.apply(store: store, now: t2, timerDefaults: defaults)
        XCTAssertEqual(VajraTimer.start(defaults: defaults), t2.timeIntervalSince1970)
    }

    @MainActor
    func testPlus5DoesNotResetTimerButHoldDoes() {
        let settings = VajraSettings(defaults: defaults)
        let model = AppModel(store: DayStore(dir: dir.appendingPathComponent("days")), demo: true,
                             bank: BankStore(dir: dir, defaults: defaults), settings: settings)
        XCTAssertEqual(VajraTimer.start(defaults: defaults), 0)
        model.act(.plus5, 3)
        XCTAssertEqual(VajraTimer.start(defaults: defaults), 0)
        model.holdCompleted()
        XCTAssertGreaterThan(VajraTimer.start(defaults: defaults), 0)
        XCTAssertNotNil(model.timerStart)
    }

    @MainActor
    func testSlotChangesAtBoundary() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let before = noon.addingTimeInterval(-1)                       // 11:59:59
        let store = DayStore(dir: dir.appendingPathComponent("days"))
        let d = VajraDate.string(noon)
        store.add(d, i: VajraDate.slotIndex(before), count: 11, nowMs: 1_000)
        let model = AppModel(store: store, demo: true, bank: BankStore(dir: dir, defaults: defaults),
                             settings: VajraSettings(defaults: defaults))
        model.slotTick(before)
        let i1 = model.currentIndex(at: before)
        XCTAssertEqual(Slots.time(i1), "11:45")
        XCTAssertEqual(model.slots[i1].count, 11)
        model.slotTick(noon)
        let i2 = model.currentIndex(at: noon)
        XCTAssertEqual(Slots.time(i2), "12:00")
        XCTAssertEqual(i2, i1 + 1)
        XCTAssertEqual(model.slots[i2].count, 0)
    }

    // MARK: расписание

    func testScheduleWindowGapLimit() {
        let cal = vienna()
        var rng = DemoData.SplitMix(seed: 11)
        let now = date(cal, 2026, 10, 20, 6)
        let ts = PingSchedule.generate(now: now, calendar: cal, perDay: 5, startMin: 8 * 60, endMin: 21 * 60, using: &rng)
        XCTAssertEqual(ts.count, 35)
        XCTAssertEqual(ts, ts.sorted())
        for t in ts {
            let c = cal.dateComponents([.hour, .minute], from: t)
            let m = c.hour! * 60 + c.minute!
            XCTAssertTrue(m >= 8 * 60 && m < 21 * 60, "\(t)")
        }
        for (a, b) in zip(ts, ts.dropFirst()) { XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 45 * 60 - 0.001) }
        XCTAssertLessThan(ts.last!, date(cal, 2026, 10, 27, 0))

        var rng2 = DemoData.SplitMix(seed: 12)
        let many = PingSchedule.generate(now: now, calendar: cal, perDay: 12, startMin: 8 * 60, endMin: 21 * 60, using: &rng2)
        XCTAssertEqual(many.count, 50)
    }

    func testScheduleTodayOnlyFuture() {
        let cal = vienna()
        var rng = DemoData.SplitMix(seed: 5)
        let now = date(cal, 2026, 10, 20, 15)
        let ts = PingSchedule.generate(now: now, calendar: cal, perDay: 5, startMin: 8 * 60, endMin: 21 * 60, using: &rng)
        XCTAssertTrue(ts.allSatisfy { $0 > now })
        let today = ts.filter { cal.isDate($0, inSameDayAs: now) }
        XCTAssertLessThanOrEqual(today.count, 3)
        XCTAssertEqual(ts.count - today.count, 30)
    }

    func testScheduleAcrossMidnightAndDST() {
        let cal = vienna()
        var rng = DemoData.SplitMix(seed: 9)
        // 25.10.2026 03:00 — переход на зимнее время в Вене (сутки 25 часов); окно 22:00–02:00 через полночь
        let now = date(cal, 2026, 10, 24, 12)
        let ts = PingSchedule.generate(now: now, calendar: cal, perDay: 4, startMin: 22 * 60, endMin: 2 * 60, using: &rng)
        XCTAssertFalse(ts.isEmpty)
        for t in ts {
            let h = cal.component(.hour, from: t)
            XCTAssertTrue(h >= 22 || h < 2, "\(t)")
        }
        for (a, b) in zip(ts, ts.dropFirst()) { XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 45 * 60 - 0.001) }
        // ночь после перехода — полные 4 пинга по местным часам
        let dstNight = ts.filter { $0 > date(cal, 2026, 10, 25, 22) && $0 < date(cal, 2026, 10, 26, 3) }
        XCTAssertEqual(dstNight.count, 4)
    }

    // MARK: ответ на пинг

    func testPingAnswerIsOneAddWithoutQ() {
        let store = DayStore(dir: dir.appendingPathComponent("days"))
        let cal = vienna()
        let now = date(cal, 2026, 10, 20, 23, 50)
        let r = PingAnswer.apply(store: store, now: now, calendar: cal)
        XCTAssertEqual(r.date, "2026-10-20")
        let ops = store.record("2026-10-20")?.ops ?? []
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .add)
        XCTAssertEqual(ops[0].i, 95)
        XCTAssertEqual(ops[0].count, 1)
        XCTAssertEqual((ops[0].qc ?? 0) + (ops[0].qm ?? 0) + (ops[0].qa ?? 0), 0)
        XCTAssertEqual(store.slots("2026-10-20")[95].count, 1)
        XCTAssertNotEqual(PingAnswer.plusAction, UNNotificationDefaultActionIdentifierForTests)
    }

    // MARK: карточка

    @MainActor
    func testCardChangesAfterHoldNotAfterPlus5() {
        let bank = BankStore(dir: dir, defaults: defaults)
        bank.save(Bank(version: 1, views: (1...4).map { Bank.ViewCard(id: "v\($0)", text: "тест \($0)", tag: nil) }, prompts: []))
        let settings = VajraSettings(defaults: defaults)
        let model = AppModel(store: DayStore(dir: dir.appendingPathComponent("days")), demo: true, bank: bank, settings: settings)
        let c0 = model.cardText
        XCTAssertNotNil(c0)
        model.act(.plus5, 3)
        XCTAssertEqual(model.cardText, c0)
        model.holdCompleted()
        XCTAssertNotEqual(model.cardText, c0)
        // удержание — +1 без оценки
        let i = VajraDate.slotIndex(Date()), s = model.slots[i]
        XCTAssertEqual(s.qc + s.qm + s.qa, i == 3 ? 5 : 0)
        XCTAssertGreaterThanOrEqual(s.count, 1)
        settings.cardEnabled = false
        model.showCurrentCard()
        XCTAssertNil(model.cardText)
    }
}

private let UNNotificationDefaultActionIdentifierForTests = "com.apple.UNNotificationDefaultActionIdentifier"
