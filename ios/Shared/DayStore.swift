import Foundation

/// Ожидающая дельта «+N / +оценка» в слот — накладывается на СВЕЖИЙ серверный день перед PUT,
/// поэтому +1 не может затереть серверный слот, даже если день локально не загружен.
struct Delta: Equatable {
    var id: String
    var i: Int
    var count: Int
    var qc = 0, qm = 0, qa = 0
    /// Метка правки (мс). На сервер уходит t = max(этот t, серверный t + 1).
    var t: Int64
}

/// Одна изменённая правкой позиция — для отмены ↶.
enum SlotChange: Equatable {
    /// Правка-установка: значение слота ДО (из хранилища) и t ПОСЛЕ.
    case set(i: Int, before: Slot, afterT: Int64)
    /// Правка-дельта: что прибавили и t ПОСЛЕ.
    case delta(i: Int, count: Int, qc: Int, qm: Int, qa: Int, afterT: Int64)

    var index: Int {
        switch self {
        case let .set(i, _, _): return i
        case let .delta(i, _, _, _, _, _): return i
        }
    }

    var afterT: Int64 {
        switch self {
        case let .set(_, _, t): return t
        case let .delta(_, _, _, _, _, t): return t
        }
    }
}

/// Метка правки слота: строго больше прежней (часы могли уйти назад).
func nextT(_ nowMs: Int64, after t: Int64) -> Int64 { max(nowMs, t + 1) }

/// Локальное хранилище дней: JSON на день в контейнере App Group
/// (`days/YYYY-MM-DD.json` = {slots (снимок-база), updatedAt, dirty, synced, deltas}).
/// Пишут приложение, виджеты и интенты — read-modify-write под межпроцессным flock.
/// Показываемый день = база + дельты.
final class DayStore {
    struct Record: Equatable {
        /// Снимок: последний серверный день ⊕ локальные правки-установки.
        var slots: [Slot]
        var updatedAt: String?
        /// В снимке есть правки-установки, которых сервер не видел.
        var dirty: Bool
        /// Снимок хоть раз слит с сервером (правки-установки разрешены только на таком дне).
        var synced: Bool
        var deltas: [Delta] = []

        var display: [Slot] { DayStore.applyDisplay(deltas, to: slots) }
        var needsPush: Bool { dirty || !deltas.isEmpty }
    }

    let dir: URL
    private let lockURL: URL

    init(dir: URL) {
        self.dir = dir
        lockURL = dir.appendingPathComponent(".lock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static let shared = DayStore(dir: VajraConfig.containerURL().appendingPathComponent("days", isDirectory: true))

    private func url(_ date: String) -> URL { dir.appendingPathComponent(date + ".json") }

    // MARK: дельты

    /// Для показа: count/оценки не ниже 0, t — самый свежий.
    static func applyDisplay(_ deltas: [Delta], to base: [Slot]) -> [Slot] {
        var s = Slots.fixed(base)
        for d in deltas where (0..<Slots.count).contains(d.i) {
            s[d.i].count = max(0, s[d.i].count + d.count)
            s[d.i].qc = max(0, s[d.i].qc + d.qc)
            s[d.i].qm = max(0, s[d.i].qm + d.qm)
            s[d.i].qa = max(0, s[d.i].qa + d.qa)
            s[d.i].t = max(s[d.i].t, d.t)
        }
        return s
    }

    /// Для отправки: дельты на свежий серверный день, t = max(t дельты, t слота + 1).
    static func applyForPush(_ deltas: [Delta], to server: [Slot]) -> [Slot] {
        var s = Slots.fixed(server)
        for d in deltas where (0..<Slots.count).contains(d.i) {
            s[d.i].count = max(0, s[d.i].count + d.count)
            s[d.i].qc = max(0, s[d.i].qc + d.qc)
            s[d.i].qm = max(0, s[d.i].qm + d.qm)
            s[d.i].qa = max(0, s[d.i].qa + d.qa)
            s[d.i].t = max(d.t, s[d.i].t + 1)
        }
        return s
    }

    /// Тело PUT: снимок ⊕ свежий серверный день, поверх — ожидающие дельты.
    static func pushBody(_ rec: Record, server: [Slot]) -> [Slot] {
        applyForPush(rec.deltas, to: Slots.merge(rec.slots, server))
    }

    // MARK: чтение

    func record(_ date: String) -> Record? {
        guard let data = try? Data(contentsOf: url(date)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let deltas: [Delta] = (obj["deltas"] as? [[String: Any]] ?? []).map {
            Delta(id: $0["id"] as? String ?? UUID().uuidString, i: Int(Slots.pyInt($0["i"])), count: Int(Slots.pyInt($0["count"])),
                  qc: Int(Slots.pyInt($0["qc"])), qm: Int(Slots.pyInt($0["qm"])), qa: Int(Slots.pyInt($0["qa"])), t: Slots.pyInt($0["t"]))
        }
        return Record(slots: Slots.norm(obj["slots"]), updatedAt: obj["updatedAt"] as? String,
                      dirty: Slots.pyTruthy(obj["dirty"]), synced: Slots.pyTruthy(obj["synced"]), deltas: deltas)
    }

    /// Показываемые слоты дня (база + дельты).
    func slots(_ date: String) -> [Slot] { record(date)?.display ?? Slots.empty() }

    func isSynced(_ date: String) -> Bool { record(date)?.synced == true }

    func exists(_ date: String) -> Bool { FileManager.default.fileExists(atPath: url(date).path) }

    func allDates() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.count == 15 }.map { String($0.prefix(10)) }.sorted()
    }

    func dirtyDates() -> [String] { allDates().filter { record($0)?.needsPush == true } }

    // MARK: правки

    private func load(_ date: String) -> Record {
        record(date) ?? Record(slots: Slots.empty(), updatedAt: nil, dirty: false, synced: false)
    }

    /// Правка-дельта (+1, −1, оценка). Работает и на незагруженном дне.
    @discardableResult
    func addDelta(_ date: String, i: Int, count: Int = 0, q: QKey? = nil, qAmount: Int = 1, nowMs: Int64) -> (slots: [Slot], change: SlotChange) {
        withLock {
            var rec = load(date)
            let t = nextT(nowMs, after: rec.display[i].t)
            var d = Delta(id: UUID().uuidString, i: i, count: count, t: t)
            switch q {
            case .qc?: d.qc = qAmount
            case .qm?: d.qm = qAmount
            case .qa?: d.qa = qAmount
            case nil: break
            }
            rec.deltas.append(d)
            write(date, rec)
            return (rec.display, .delta(i: i, count: d.count, qc: d.qc, qm: d.qm, qa: d.qa, afterT: t))
        }
    }

    /// Правка-установка по показываемым слотам: f меняет значения (без t), хранилище само ставит
    /// t = max(now, t+1) изменённым слотам и сворачивает их дельты в снимок.
    @discardableResult
    func setSlots(_ date: String, nowMs: Int64, _ f: (inout [Slot]) -> Void) -> (slots: [Slot], changes: [SlotChange]) {
        withLock {
            var rec = load(date)
            let before = rec.display
            var after = before
            f(&after)
            var changes: [SlotChange] = []
            for i in 0..<Slots.count where after[i] != before[i] {
                var s = after[i]
                s.t = nextT(nowMs, after: before[i].t)
                rec.slots[i] = s
                rec.deltas.removeAll { $0.i == i }
                changes.append(.set(i: i, before: before[i], afterT: s.t))
            }
            if !changes.isEmpty { rec.dirty = true; write(date, rec) }
            return (rec.display, changes)
        }
    }

    /// «Сбросить день»: все слоты пустые с одним t = max(now, maxT(дня) + 1).
    @discardableResult
    func resetDay(_ date: String, nowMs: Int64) -> (slots: [Slot], changes: [SlotChange]) {
        withLock {
            var rec = load(date)
            let before = rec.display
            let t = nextT(nowMs, after: before.map(\.t).max() ?? 0)
            rec.slots = Array(repeating: Slot(t: t), count: Slots.count)
            rec.deltas = []
            rec.dirty = true
            write(date, rec)
            return (rec.display, (0..<Slots.count).map { .set(i: $0, before: before[$0], afterT: t) })
        }
    }

    /// Отмена: слот возвращается, только если его t всё ещё равен t нашей правки (никто не правил после).
    /// Возвращает число пропущенных позиций.
    @discardableResult
    func revert(_ date: String, _ changes: [SlotChange], nowMs: Int64) -> (slots: [Slot], skipped: Int) {
        withLock {
            var rec = load(date)
            var skipped = 0
            for ch in changes.reversed() {
                let i = ch.index
                let cur = rec.display[i]
                guard cur.t == ch.afterT else { skipped += 1; continue }
                let t = nextT(nowMs, after: cur.t)
                switch ch {
                case let .set(_, before, _):
                    var s = before
                    s.t = t
                    rec.slots[i] = s
                    rec.deltas.removeAll { $0.i == i }
                    rec.dirty = true
                case let .delta(_, c, qc, qm, qa, _):
                    rec.deltas.append(Delta(id: UUID().uuidString, i: i, count: -c, qc: -qc, qm: -qm, qa: -qa, t: t))
                }
            }
            write(date, rec)
            return (rec.display, skipped)
        }
    }

    // MARK: сервер

    /// Снимок сервера (GET) — истина: снимок ⊕ сервер; дельты остаются ждать отправки.
    @discardableResult
    func applyServer(_ date: String, slots server: [Slot], updatedAt: String?) -> [Slot] {
        withLock {
            let local = record(date)
            var rec = local ?? Record(slots: Slots.empty(), updatedAt: nil, dirty: false, synced: false)
            rec.slots = Slots.merge(rec.slots, server)
            rec.updatedAt = updatedAt ?? rec.updatedAt
            rec.dirty = rec.slots != Slots.fixed(server)
            rec.synced = true
            if rec != local { write(date, rec) }
            return rec.display
        }
    }

    /// Ответ на PUT: снимок ⊕ ответ, отправленные дельты удаляются (добавленные за время запроса — остаются).
    @discardableResult
    func commitPush(_ date: String, response: [Slot], updatedAt: String?, sentDeltaIds: Set<String>) -> [Slot] {
        withLock {
            var rec = load(date)
            rec.slots = Slots.merge(rec.slots, response)
            rec.deltas.removeAll { sentDeltaIds.contains($0.id) }
            rec.updatedAt = updatedAt ?? rec.updatedAt
            rec.dirty = rec.slots != Slots.fixed(response)
            rec.synced = true
            write(date, rec)
            return rec.display
        }
    }

    /// Прямая запись (демо-данные, тесты).
    func put(_ date: String, _ rec: Record) { withLock { write(date, rec) } }

    /// Кэш последних keep дней: старые дни без неотправленного удаляются.
    func prune(today: String, keep: Int = 60) {
        let cutoff = VajraDate.addDays(today, -keep)
        withLock {
            for d in allDates() where d < cutoff && record(d)?.needsPush != true {
                try? FileManager.default.removeItem(at: url(d))
            }
        }
    }

    func removeAll() {
        withLock { for d in allDates() { try? FileManager.default.removeItem(at: url(d)) } }
    }

    private func write(_ date: String, _ rec: Record) {
        var obj: [String: Any] = ["slots": Slots.toJSON(rec.slots), "dirty": rec.dirty, "synced": rec.synced,
                                  "deltas": rec.deltas.map { ["id": $0.id, "i": $0.i, "count": $0.count, "qc": $0.qc, "qm": $0.qm, "qa": $0.qa, "t": $0.t] }]
        if let u = rec.updatedAt { obj["updatedAt"] = u }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: url(date), options: .atomic)
    }

    private func withLock<T>(_ f: () -> T) -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return f()
    }
}
