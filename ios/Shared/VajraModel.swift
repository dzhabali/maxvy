import Foundation
import os

/// Общие константы приложения и расширения виджетов.
enum VajraConfig {
    static let appGroup = "group.com.maxdzhabali.vajra"
    static let countKind = "com.maxdzhabali.vajra.count"
    static let quoteKind = "com.maxdzhabali.vajra.quote"
    static let widgetKinds = [countKind, quoteKind]
    static let goal = 100
    static let slotsPerDay = 96

    /// true — контейнер App Group недоступен (подпись без entitlement): виджеты/интенты не увидят данные.
    private(set) static var appGroupMissing = false

    static var isTesting: Bool { NSClassFromString("XCTestCase") != nil }

    /// Контейнер App Group (общий с виджетами и интентами). Без него: под XCTest — Application Support
    /// процесса; в работе — то же, но с ошибкой в лог и плашкой в приложении.
    static func containerURL() -> URL {
        if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return u
        }
        if !isTesting {
            appGroupMissing = true
            os_log("App Group %{public}@ недоступна — данные только внутри процесса", log: .default, type: .error, appGroup)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vajra", isDirectory: true)
    }
}

/// Межпроцессный сигнал «день изменился» (интент/виджет → открытое приложение).
enum VajraNotify {
    static let name = "com.maxdzhabali.vajra.changed" as CFString
    private static var handler: (() -> Void)?

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
    }

    /// Один наблюдатель на процесс; handler зовётся на главной очереди.
    static func observe(_ h: @escaping () -> Void) {
        let first = handler == nil
        handler = h
        guard first else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { VajraNotify.handler?() }
        }, name, nil, .deliverImmediately)
    }
}

/// Оценка памятования: ясно / средне / автомат (сервер: Q_KEYS = ('qc', 'qm', 'qa')).
enum QKey: String, CaseIterable {
    case qc, qm, qa
}

/// Один 15-минутный слот дня (как на сервере: count, sleep, forgot, t + ненулевые Q_KEYS).
struct Slot: Equatable {
    var count: Int = 0
    var sleep: Bool = false
    var forgot: Bool = false
    /// Метка последней правки слота на клиенте, мс с 1970. 0 — не трогали.
    var t: Int64 = 0
    var qc: Int = 0
    var qm: Int = 0
    var qa: Int = 0

    subscript(q: QKey) -> Int {
        get {
            switch q {
            case .qc: return qc
            case .qm: return qm
            case .qa: return qa
            }
        }
        set {
            switch q {
            case .qc: qc = newValue
            case .qm: qm = newValue
            case .qa: qa = newValue
            }
        }
    }
}

/// Логика слотов — 1-в-1 с `norm_slots` / `merge_slots` из life-chronicle/personal_apps.py.
enum Slots {
    static let count = VajraConfig.slotsPerDay

    static func time(_ i: Int) -> String {
        String(format: "%02d:%02d", i / 4, (i % 4) * 15)
    }

    static func empty() -> [Slot] { Array(repeating: Slot(), count: count) }

    /// norm_slots: всегда ровно 96 слотов; не-словари → пустой слот; числа — int(float(v or 0)),
    /// флаги — bool(v) по правилам Python.
    static func norm(_ arr: Any?) -> [Slot] {
        let src = arr as? [Any] ?? []
        return (0..<count).map { i in
            let s = (i < src.count ? src[i] as? [String: Any] : nil) ?? [:]
            var r = Slot()
            r.count = Int(pyInt(s["count"]))
            r.sleep = pyTruthy(s["sleep"])
            r.forgot = pyTruthy(s["forgot"])
            r.t = pyInt(s["t"])
            r.qc = Int(pyInt(s["qc"]))
            r.qm = Int(pyInt(s["qm"]))
            r.qa = Int(pyInt(s["qa"]))
            return r
        }
    }

    /// Дополнить/обрезать до 96 (на случай кривого массива в памяти).
    static func fixed(_ a: [Slot]) -> [Slot] {
        if a.count == count { return a }
        return (0..<count).map { $0 < a.count ? a[$0] : Slot() }
    }

    /// merge_slots: разные t — слот целиком с большим t; равные — max по числам, OR по флагам.
    static func merge(_ a: [Slot], _ b: [Slot]) -> [Slot] {
        let A = fixed(a), B = fixed(b)
        return (0..<count).map { i in
            let x = A[i], y = B[i]
            if x.t != y.t { return x.t > y.t ? x : y }
            return Slot(count: max(x.count, y.count), sleep: x.sleep || y.sleep, forgot: x.forgot || y.forgot,
                        t: x.t, qc: max(x.qc, y.qc), qm: max(x.qm, y.qm), qa: max(x.qa, y.qa))
        }
    }

    /// Сериализация как на сервере: time, count, sleep, forgot, t + только ненулевые Q_KEYS.
    static func toJSON(_ slots: [Slot]) -> [[String: Any]] {
        fixed(slots).enumerated().map { i, s in
            var d: [String: Any] = ["time": time(i), "count": s.count, "sleep": s.sleep, "forgot": s.forgot, "t": s.t]
            for q in QKey.allCases where s[q] != 0 { d[q.rawValue] = s[q] }
            return d
        }
    }

    static func total(_ s: [Slot]) -> Int { s.reduce(0) { $0 + $1.count } }

    // MARK: Python-семантика

    static func isBool(_ v: Any) -> Bool {
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() }
        return false
    }

    /// int(float(v or 0)). Неразбираемая строка (на сервере — исключение) → 0.
    static func pyInt(_ v: Any?) -> Int64 {
        guard let v, !(v is NSNull) else { return 0 }
        var d: Double?
        if isBool(v) {
            d = (v as! NSNumber).boolValue ? 1 : 0
        } else if let n = v as? NSNumber {
            d = n.doubleValue
        } else if let s = v as? String {
            d = Double(s.trimmingCharacters(in: .whitespaces))
        }
        guard let x = d, x.isFinite, abs(x) < 9.2e18 else { return 0 }
        return Int64(x.rounded(.towardZero))
    }

    /// bool(v) по правилам Python (непустая строка — True, даже "false").
    static func pyTruthy(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if isBool(v) { return (v as! NSNumber).boolValue }
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        if let s = v as? String { return !s.isEmpty }
        if let a = v as? [Any] { return !a.isEmpty }
        if let m = v as? [String: Any] { return !m.isEmpty }
        return true
    }
}

/// Даты дня — по ЛОКАЛЬНОМУ календарю (граница суток — местная полночь).
enum VajraDate {
    static func string(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Полдень локального дня (для арифметики дат без DST-сюрпризов).
    static func date(_ s: String, calendar: Calendar = .current) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// index = (час*60+мин)/15 по местному времени.
    static func slotIndex(_ d: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return min(VajraConfig.slotsPerDay - 1, max(0, ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 15))
    }

    static func addDays(_ s: String, _ n: Int, calendar: Calendar = .current) -> String {
        guard let d = date(s, calendar: calendar), let r = calendar.date(byAdding: .day, value: n, to: d) else { return s }
        return string(r, calendar: calendar)
    }

    /// Сравнение updatedAt сервера: «…:05Z» и «…:05.000123Z» — как даты; нераспознанное — как строки.
    static func isoLess(_ a: String, _ b: String) -> Bool {
        if let x = parseISO(a), let y = parseISO(b) { return x < y }
        return a < b
    }

    /// «YYYY-MM-DDTHH:MM:SS[.ffffff]Z» с точностью до микросекунд (ISO8601DateFormatter режет до мс).
    static func parseISO(_ s: String) -> Date? {
        guard s.hasSuffix("Z") else { return nil }
        let body = s.dropLast()
        let parts = body.split(separator: ".", maxSplits: 1)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let base = f.date(from: String(parts[0]) + "Z") else { return nil }
        guard parts.count == 2 else { return base }
        guard let frac = Double("0." + parts[1]) else { return nil }
        return base.addingTimeInterval(frac)
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// [start, end) месяца: month — 1…12; end — первое число следующего месяца.
    static func monthBounds(year: Int, month: Int) -> (String, String) {
        let ny = month == 12 ? year + 1 : year
        let nm = month == 12 ? 1 : month + 1
        return (String(format: "%04d-%02d-01", year, month), String(format: "%04d-%02d-01", ny, nm))
    }

    static func daysInMonth(year: Int, month: Int, calendar: Calendar = .current) -> Int {
        guard let d = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let r = calendar.range(of: .day, in: .month, for: d) else { return 30 }
        return r.count
    }

    /// Начало следующего слота после d (для timeline виджетов).
    static func nextSlotStart(after d: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let m = ((c.minute ?? 0) / 15 + 1) * 15
        var dc = DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: 0)
        dc.second = 0
        let base = calendar.date(from: dc) ?? d
        return calendar.date(byAdding: .minute, value: m, to: base) ?? d.addingTimeInterval(900)
    }
}
