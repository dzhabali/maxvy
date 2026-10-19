import XCTest
@testable import Vajra

/// norm_slots / merge_slots — ожидания получены прогоном personal_apps.py (Python) на тех же входах.
final class SlotsTests: XCTestCase {
    private func merged(_ a: [Any], _ b: [Any]) -> [Slot] { Slots.merge(Slots.norm(a), Slots.norm(b)) }

    func testAlways96() {
        XCTAssertEqual(Slots.norm(nil).count, 96)
        XCTAssertEqual(Slots.norm("junk").count, 96)
        XCTAssertEqual(Slots.norm(Array(repeating: ["count": 1], count: 120)).count, 96)
        XCTAssertEqual(Slots.time(0), "00:00")
        XCTAssertEqual(Slots.time(95), "23:45")
        XCTAssertEqual(Slots.time(57), "14:15")
    }

    /// diff_t: [{count:5,t:100,qc:2}] vs [{count:1,sleep:True,t:200,qa:1}] → слот целиком с t=200.
    func testDifferentTTakesNewerWhole() {
        let m = merged([["count": 5, "t": 100, "qc": 2]], [["count": 1, "sleep": true, "t": 200, "qa": 1]])
        XCTAssertEqual(m[0], Slot(count: 1, sleep: true, forgot: false, t: 200, qc: 0, qm: 0, qa: 1))
        XCTAssertEqual(m[1], Slot())
    }

    /// equal_t: max по числам и Q_KEYS, OR по флагам → {count:5, sleep, forgot, t:7, qc:4, qm:3, qa:2}.
    func testEqualTMaxAndOr() {
        let m = merged([["count": 5, "sleep": true, "t": 7, "qc": 1, "qm": 3]], [["count": 2, "forgot": true, "t": 7, "qc": 4, "qa": 2]])
        XCTAssertEqual(m[0], Slot(count: 5, sleep: true, forgot: true, t: 7, qc: 4, qm: 3, qa: 2))
    }

    /// zero_vs_data: пустышка t=0 не затирает данные с t=0.
    func testEmptyDoesNotEraseLegacyData() {
        XCTAssertEqual(merged([], [["count": 3, "t": 0]])[0].count, 3)
    }

    /// minus_wins: более свежий «минус» побеждает (count 5@100 vs 4@101 → 4).
    func testNewerMinusWins() {
        let m = merged([["count": 5, "t": 100]], [["count": 4, "t": 101]])
        XCTAssertEqual(m[0], Slot(count: 4, t: 101))
    }

    /// messy: строки/булевы/None как в Python: int(float("3.9"))=3, bool("false")=True, qc=True→1, t "12.5"→12.
    func testMessyValuesLikePython() {
        let m = merged([["count": "3.9", "sleep": "false", "forgot": 0, "t": "12.5", "qc": true]], [NSNull(), ["count": 2]])
        XCTAssertEqual(m[0], Slot(count: 3, sleep: true, forgot: false, t: 12, qc: 1))
        XCTAssertEqual(m[1], Slot(count: 2))
    }

    /// norm_messy: не-словарь → пустой слот; -2.7 → -2 (усечение к нулю); [] → False; "x" → True; qa "2" → 2.
    func testNormMessy() {
        let n = Slots.norm([["count": "3.9", "sleep": "false", "forgot": 0, "t": "12.5", "qc": true, "qm": 0],
                            "junk",
                            ["count": -2.7, "sleep": [Any](), "forgot": "x", "qa": "2"]])
        XCTAssertEqual(n[0], Slot(count: 3, sleep: true, t: 12, qc: 1))
        XCTAssertEqual(n[1], Slot())
        XCTAssertEqual(n[2], Slot(count: -2, sleep: false, forgot: true, qa: 2))
    }

    func testMergeIdempotentAndCommutative() {
        let a = Slots.norm([["count": 5, "t": 100], ["count": 1, "t": 3, "qm": 1], ["sleep": true, "t": 9]])
        let b = Slots.norm([["count": 2, "t": 100], ["count": 7, "t": 2], ["forgot": true, "t": 10]])
        XCTAssertEqual(Slots.merge(a, b), Slots.merge(b, a))
        XCTAssertEqual(Slots.merge(Slots.merge(a, b), b), Slots.merge(a, b))
        XCTAssertEqual(Slots.merge(a, a), a)
    }

    /// toJSON → как сервер: только ненулевые Q_KEYS, round-trip через JSON сохраняет слоты.
    func testJSONRoundTrip() throws {
        var s = Slots.empty()
        s[3] = Slot(count: 2, sleep: false, forgot: true, t: 1_760_000_000_123, qc: 1, qm: 0, qa: 1)
        let js = Slots.toJSON(s)
        XCTAssertEqual(js[3]["time"] as? String, "00:45")
        XCTAssertNil(js[3]["qm"])
        XCTAssertEqual(js[3]["qa"] as? Int, 1)
        XCTAssertNil(js[0]["qc"])
        let data = try JSONSerialization.data(withJSONObject: ["slots": js])
        let back = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Slots.norm(back["slots"]), s)
    }
}

final class DateTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testSlotIndex() {
        XCTAssertEqual(VajraDate.slotIndex(at(2026, 10, 19, 0, 0), calendar: cal), 0)
        XCTAssertEqual(VajraDate.slotIndex(at(2026, 10, 19, 0, 14, 59), calendar: cal), 0)
        XCTAssertEqual(VajraDate.slotIndex(at(2026, 10, 19, 0, 15), calendar: cal), 1)
        XCTAssertEqual(VajraDate.slotIndex(at(2026, 10, 19, 14, 29), calendar: cal), 57)
        XCTAssertEqual(VajraDate.slotIndex(at(2026, 10, 19, 23, 59, 59), calendar: cal), 95)
    }

    /// Дата дня — локальная: в Вене 00:30 19.10 — это 19-е, хотя в UTC ещё 18-е.
    func testLocalDateNotUTC() {
        let d = at(2026, 10, 19, 0, 30)
        XCTAssertEqual(VajraDate.string(d, calendar: cal), "2026-10-19")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(VajraDate.string(d, calendar: utc), "2026-10-18")
    }

    func testAddDaysAndMonthBounds() {
        XCTAssertEqual(VajraDate.addDays("2026-10-31", 1, calendar: cal), "2026-11-01")
        XCTAssertEqual(VajraDate.addDays("2026-03-29", -1, calendar: cal), "2026-03-28")  // DST
        XCTAssertEqual(VajraDate.monthBounds(year: 2026, month: 12).0, "2026-12-01")
        XCTAssertEqual(VajraDate.monthBounds(year: 2026, month: 12).1, "2027-01-01")
        XCTAssertEqual(VajraDate.daysInMonth(year: 2028, month: 2, calendar: cal), 29)
    }

    func testNextSlotStart() {
        XCTAssertEqual(VajraDate.nextSlotStart(after: at(2026, 10, 19, 14, 7, 30), calendar: cal), at(2026, 10, 19, 14, 15))
        XCTAssertEqual(VajraDate.nextSlotStart(after: at(2026, 10, 19, 23, 50), calendar: cal), at(2026, 10, 20, 0, 0))
    }
}
