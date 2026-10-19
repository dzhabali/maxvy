import Foundation

/// Поля операции set: только заданные (не nil) выставляются абсолютно.
struct SetFields: Equatable {
    var count: Int?
    var qc: Int?
    var qm: Int?
    var qa: Int?
    var sleep: Bool?
    var forgot: Bool?

    /// Текущие значения слота для тех же полей (для отмены).
    func snapshot(of s: Slot) -> SetFields {
        SetFields(count: count == nil ? nil : s.count, qc: qc == nil ? nil : s.qc, qm: qm == nil ? nil : s.qm,
                  qa: qa == nil ? nil : s.qa, sleep: sleep == nil ? nil : s.sleep, forgot: forgot == nil ? nil : s.forgot)
    }
}

/// Операция над слотом — 1-в-1 с `vajra_apply_ops` сервера (POST /vajra/api/days/<дата>/ops).
/// Идемпотентна по id: повтор после потерянного ответа сервер пропускает.
struct Op: Equatable {
    enum Kind: String { case add, set }
    var id: String
    var kind: Kind
    var i: Int
    var t: Int64
    /// add: дельты (nil = 0); set: абсолютные значения переданных полей.
    var count: Int?
    var qc: Int?
    var qm: Int?
    var qa: Int?
    var sleep: Bool?
    var forgot: Bool?

    static func add(_ i: Int, count: Int = 0, qc: Int = 0, qm: Int = 0, qa: Int = 0, t: Int64) -> Op {
        Op(id: UUID().uuidString, kind: .add, i: i, t: t, count: count, qc: qc, qm: qm, qa: qa)
    }

    static func set(_ i: Int, _ f: SetFields, t: Int64) -> Op {
        Op(id: UUID().uuidString, kind: .set, i: i, t: t, count: f.count, qc: f.qc, qm: f.qm, qa: f.qa, sleep: f.sleep, forgot: f.forgot)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "type": kind.rawValue, "i": i, "t": t]
        if let count { d["count"] = count }
        if let qc { d["qc"] = qc }
        if let qm { d["qm"] = qm }
        if let qa { d["qa"] = qa }
        if let sleep { d["sleep"] = sleep }
        if let forgot { d["forgot"] = forgot }
        return d
    }

    init(id: String, kind: Kind, i: Int, t: Int64, count: Int? = nil, qc: Int? = nil, qm: Int? = nil, qa: Int? = nil,
         sleep: Bool? = nil, forgot: Bool? = nil) {
        self.id = id; self.kind = kind; self.i = i; self.t = t
        self.count = count; self.qc = qc; self.qm = qm; self.qa = qa; self.sleep = sleep; self.forgot = forgot
    }

    init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let k = (d["type"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        func int(_ key: String) -> Int? { d[key] == nil || d[key] is NSNull ? nil : Int(Slots.pyInt(d[key])) }
        func bool(_ key: String) -> Bool? { d[key] == nil || d[key] is NSNull ? nil : Slots.pyTruthy(d[key]) }
        self.init(id: id, kind: k, i: Int(Slots.pyInt(d["i"])), t: Slots.pyInt(d["t"]),
                  count: int("count"), qc: int("qc"), qm: int("qm"), qa: int("qa"), sleep: bool("sleep"), forgot: bool("forgot"))
    }
}

enum VajraOps {
    static let appliedKeep = 3000
    static let maxValue = 100_000
    static let batch = 200

    static func validID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// vajra_apply_ops: add — count/Q += Δ (не ниже 0); set — переданные поля; t = max(t + 1, op.t).
    static func apply(_ base: [Slot], _ ops: [Op], applied: inout [String]) -> [Slot] {
        var s = Slots.fixed(base)
        var seen = Set(applied)
        for op in ops {
            guard validID(op.id), !seen.contains(op.id), (0..<Slots.count).contains(op.i), op.t >= 0,
                  [op.count, op.qc, op.qm, op.qa].allSatisfy({ abs($0 ?? 0) <= maxValue }) else { continue }
            var x = s[op.i]
            switch op.kind {
            case .add:
                x.count = max(0, x.count + (op.count ?? 0))
                x.qc = max(0, x.qc + (op.qc ?? 0))
                x.qm = max(0, x.qm + (op.qm ?? 0))
                x.qa = max(0, x.qa + (op.qa ?? 0))
                x.t = max(x.t + 1, op.t)
            case .set:
                if op.t >= x.t {      // устаревшая установка не применяется
                    if let v = op.sleep { x.sleep = v }
                    if let v = op.forgot { x.forgot = v }
                    if let v = op.count { x.count = max(0, v) }
                    if let v = op.qc { x.qc = max(0, v) }
                    if let v = op.qm { x.qm = max(0, v) }
                    if let v = op.qa { x.qa = max(0, v) }
                    x.t = max(x.t + 1, op.t)
                }
            }
            s[op.i] = x
            seen.insert(op.id)
            applied.append(op.id)
        }
        if applied.count > appliedKeep { applied.removeFirst(applied.count - appliedKeep) }
        return s
    }
}

/// День с сервера: слоты, updatedAt и последние применённые id операций (?ops=1).
struct ServerDay: Equatable {
    var slots: [Slot]
    var updatedAt: String?
    var appliedTail: [String]
}

/// Позиция правки — для отмены ↶.
enum SlotChange: Equatable {
    /// add: инверсия — новая add с −Δ.
    case add(i: Int, count: Int, qc: Int, qm: Int, qa: Int)
    /// set: прежние значения полей; откат — только если t слота всё ещё afterT.
    case set(i: Int, before: SetFields, afterT: Int64)
}

/// Метка правки слота: строго больше прежней (часы могли уйти назад).
func nextT(_ nowMs: Int64, after t: Int64) -> Int64 { max(nowMs, t + 1) }

/// Локальное хранилище дней: JSON на день в контейнере App Group
/// (`days/YYYY-MM-DD.json` = {slots — последний ответ сервера, updatedAt, appliedTail, fetchedAt, ops — очередь}).
/// Показ = снимок + ожидающие операции (кроме уже применённых сервером по appliedTail).
/// Пишут приложение, виджеты и интенты — read-modify-write под межпроцессным flock.
final class DayStore {
    struct Record: Equatable {
        var slots: [Slot]
        var updatedAt: String?
        var appliedTail: [String] = []
        /// Когда снимок пришёл с сервера (сек с 1970), 0 — ни разу.
        var fetchedAt: Double = 0
        var ops: [Op] = []
        /// Формат билда 2: снимок с неотправленными правками — один раз отправить старым PUT.
        var legacyDirty = false

        var display: [Slot] {
            var a = appliedTail
            return VajraOps.apply(slots, ops, applied: &a)
        }

        var needsPush: Bool { !ops.isEmpty || legacyDirty }
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

    // MARK: чтение

    func record(_ date: String) -> Record? {
        guard let data = try? Data(contentsOf: url(date)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var ops = (obj["ops"] as? [[String: Any]] ?? []).compactMap(Op.init(json:))
        // миграция билда 2: дельты → add с теми же id и t
        for d in obj["deltas"] as? [[String: Any]] ?? [] {
            guard let id = d["id"] as? String, !ops.contains(where: { $0.id == id }) else { continue }
            ops.append(Op(id: id, kind: .add, i: Int(Slots.pyInt(d["i"])), t: Slots.pyInt(d["t"]), count: Int(Slots.pyInt(d["count"])),
                          qc: Int(Slots.pyInt(d["qc"])), qm: Int(Slots.pyInt(d["qm"])), qa: Int(Slots.pyInt(d["qa"]))))
        }
        return Record(slots: Slots.norm(obj["slots"]), updatedAt: obj["updatedAt"] as? String,
                      appliedTail: obj["appliedTail"] as? [String] ?? [],
                      fetchedAt: (obj["fetchedAt"] as? NSNumber)?.doubleValue ?? 0,
                      ops: ops,
                      legacyDirty: Slots.pyTruthy(obj["legacyDirty"]) || Slots.pyTruthy(obj["dirty"]))
    }

    /// Показываемые слоты дня.
    func slots(_ date: String) -> [Slot] { record(date)?.display ?? Slots.empty() }

    func exists(_ date: String) -> Bool { FileManager.default.fileExists(atPath: url(date).path) }

    func allDates() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.count == 15 }.map { String($0.prefix(10)) }.sorted()
    }

    func dirtyDates() -> [String] { allDates().filter { record($0)?.needsPush == true } }

    // MARK: правки (только в очередь операций)

    private func load(_ date: String) -> Record { record(date) ?? Record(slots: Slots.empty(), updatedAt: nil) }

    /// +N / −N / оценка в слот.
    @discardableResult
    func add(_ date: String, i: Int, count: Int = 0, q: QKey? = nil, qAmount: Int = 1, nowMs: Int64) -> (slots: [Slot], change: SlotChange) {
        withLock {
            var rec = load(date)
            let t = nextT(nowMs, after: rec.display[i].t)
            let op = Op.add(i, count: count, qc: q == .qc ? qAmount : 0, qm: q == .qm ? qAmount : 0, qa: q == .qa ? qAmount : 0, t: t)
            rec.ops.append(op)
            write(date, rec)
            return (rec.display, .add(i: i, count: count, qc: op.qc ?? 0, qm: op.qm ?? 0, qa: op.qa ?? 0))
        }
    }

    /// Выставить поля в слотах. Слоты, где значения уже такие, пропускаются.
    @discardableResult
    func set(_ date: String, nowMs: Int64, _ edits: [(i: Int, fields: SetFields)]) -> (slots: [Slot], changes: [SlotChange]) {
        withLock {
            var rec = load(date)
            var changes: [SlotChange] = []
            for e in edits where (0..<Slots.count).contains(e.i) {
                let cur = rec.display[e.i]
                let before = e.fields.snapshot(of: cur)
                guard before != e.fields else { continue }
                let t = nextT(nowMs, after: cur.t)
                rec.ops.append(.set(e.i, e.fields, t: t))
                changes.append(.set(i: e.i, before: before, afterT: t))
            }
            if !changes.isEmpty { write(date, rec) }
            return (rec.display, changes)
        }
    }

    /// «Сбросить день»: set count=0, сон/забыл=false, оценки=0 во всех слотах; t = max(now, maxT + 1).
    @discardableResult
    func resetDay(_ date: String, nowMs: Int64) -> (slots: [Slot], changes: [SlotChange]) {
        withLock {
            var rec = load(date)
            let disp = rec.display
            let t = nextT(nowMs, after: disp.map(\.t).max() ?? 0)
            let f = SetFields(count: 0, qc: 0, qm: 0, qa: 0, sleep: false, forgot: false)
            var changes: [SlotChange] = []
            for i in 0..<Slots.count {
                rec.ops.append(.set(i, f, t: t))
                changes.append(.set(i: i, before: f.snapshot(of: disp[i]), afterT: max(disp[i].t + 1, t)))
            }
            write(date, rec)
            return (rec.display, changes)
        }
    }

    /// Отмена: add — обратной add; set — прежние поля, только если t слота не менялся с нашей правки.
    @discardableResult
    func revert(_ date: String, _ changes: [SlotChange], nowMs: Int64) -> (slots: [Slot], skipped: Int) {
        withLock {
            var rec = load(date)
            var skipped = 0
            for ch in changes.reversed() {
                switch ch {
                case let .add(i, c, qc, qm, qa):
                    let t = nextT(nowMs, after: rec.display[i].t)
                    rec.ops.append(.add(i, count: -c, qc: -qc, qm: -qm, qa: -qa, t: t))
                case let .set(i, before, afterT):
                    let cur = rec.display[i]
                    guard cur.t == afterT else { skipped += 1; continue }
                    rec.ops.append(.set(i, before, t: nextT(nowMs, after: cur.t)))
                }
            }
            write(date, rec)
            return (rec.display, skipped)
        }
    }

    // MARK: сервер

    /// Снимок с сервера (GET / ответ POST) заменяет локальный, если он не старше уже имеющегося.
    /// Операции, которые сервер уже применил (appliedTail) или которые мы отправили (sent), уходят из очереди.
    @discardableResult
    func applyServer(_ date: String, _ day: ServerDay, sent: Set<String> = [], now: Date = Date()) -> [Slot] {
        withLock {
            let local = record(date)
            var rec = local ?? Record(slots: Slots.empty(), updatedAt: nil)
            let stale = local?.updatedAt.map { cur in VajraDate.isoLess(day.updatedAt ?? "", cur) } ?? false
            let known = Set(day.appliedTail).union(sent)
            if !stale {
                rec.slots = Slots.fixed(day.slots)
                rec.updatedAt = day.updatedAt
                rec.appliedTail = day.appliedTail
                rec.fetchedAt = now.timeIntervalSince1970
                rec.ops.removeAll { known.contains($0.id) }
            } else {
                // старый снимок не берём; отправленные (sent) сервер применил — новее снимок их уже содержит
                rec.ops.removeAll { sent.contains($0.id) }
            }
            if rec != local { write(date, rec) }
            return rec.display
        }
    }

    /// Ответ старого PUT (миграция билда 2): снимок = итог слияния на сервере, флаг снят.
    func clearLegacy(_ date: String, response: ServerDay) {
        withLock {
            var rec = load(date)
            rec.slots = Slots.fixed(response.slots)
            rec.updatedAt = response.updatedAt ?? rec.updatedAt
            rec.legacyDirty = false
            write(date, rec)
        }
    }

    /// Прямая запись (демо-данные, тесты).
    func put(_ date: String, _ rec: Record) { withLock { write(date, rec) } }

    /// Кэш последних keep дней: старые дни без очереди удаляются.
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
        var obj: [String: Any] = ["slots": Slots.toJSON(rec.slots), "appliedTail": rec.appliedTail,
                                  "fetchedAt": rec.fetchedAt, "ops": rec.ops.map(\.json)]
        if let u = rec.updatedAt { obj["updatedAt"] = u }
        if rec.legacyDirty { obj["legacyDirty"] = true }
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
