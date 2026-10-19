import Foundation
import SwiftUI

/// Состояние экрана — порт логики vajra-tracker.html: выбранный день, правки слотов, удержание,
/// оценка, ачивки, отмена, таймер 3:00, перекат дня, синк (debounce 1,5 с, опрос раз в 20 с).
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String { case tracker, calendar, sleep }

    struct YM: Equatable, Hashable { var year: Int; var month: Int  // month 1…12
        var key: String { "\(year)-\(month)" }
        func adding(_ n: Int) -> YM {
            var y = year, m = month + n
            while m < 1 { m += 12; y -= 1 }
            while m > 12 { m -= 12; y += 1 }
            return YM(year: y, month: m)
        }
        static func of(_ d: Date) -> YM {
            let c = Calendar.current.dateComponents([.year, .month], from: d)
            return YM(year: c.year ?? 2026, month: c.month ?? 1)
        }
    }

    struct QPending: Equatable { let date: String; let index: Int }

    static let holdSeconds: Double = 3        // HOLD_MS
    static let qAutoClose: Double = 12        // Q_AUTOCLOSE_MS
    static let timerDuration: Double = 3 * 60 // TIMER_DURATION
    static let timerMaxOvertime: Double = 12 * 3600
    static let undoMax = 20

    @Published var tab: Tab = .tracker
    @Published private(set) var selectedDate: String
    @Published private(set) var slots: [Slot]
    @Published var histOpen = false
    @Published var sleepTillDone = false
    @Published private(set) var qPending: QPending?
    @Published var achievement: Milestone?
    @Published private(set) var toast: String?
    @Published private(set) var timerStart: Date?
    @Published private(set) var undoCount = 0
    @Published var calMonth: YM
    @Published var sleepMonth: YM
    @Published private(set) var months: [String: [String: [Slot]]] = [:]
    /// Тик раз в 30 с — двигает «текущий слот».
    @Published private(set) var clock = Date()
    /// Идёт подтягивание незагруженного дня перед правкой.
    @Published private(set) var loadingDay = false

    let store: DayStore
    let demo: Bool
    private let api: VajraAPI
    private let shortAPI = VajraAPI(session: VajraAPI.makeSession(timeout: 6))
    weak var auth: AuthManager?

    private var undo: [UndoEntry] = []
    private var prevTotal = 0
    private var syncTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var qTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var lastKnownToday: String
    private var monthDirty: Set<String> = []

    init(store: DayStore = .shared, api: VajraAPI = .shared, demo: Bool = false) {
        self.store = store
        self.api = api
        self.demo = demo
        let today = VajraDate.string(Date())
        selectedDate = today
        lastKnownToday = today
        slots = store.slots(today)
        calMonth = .of(Date())
        sleepMonth = .of(Date())
        prevTotal = Slots.total(slots)
        if let tab = UserDefaults.standard.string(forKey: "tab").flatMap(Tab.init(rawValue:)) { self.tab = tab }
        restoreTimer()
        if !demo { store.prune(today: today) }
    }

    // MARK: производные

    var today: String { VajraDate.string(Date()) }
    var isToday: Bool { selectedDate == today }
    var currentIndex: Int { isToday ? VajraDate.slotIndex(Date()) : 47 }
    var total: Int { Slots.total(slots) }
    var quality: VajraStats.Quality { VajraStats.quality(slots) }
    var sleepMinutes: Int { VajraStats.sleepMinutes(slots) }

    // MARK: жизненный цикл

    func becameActive() {
        rolloverCheck()
        ensureToday()
        restoreTimer()
        reload()
        VajraNotify.observe { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rolloverCheck() }
        }
        pollTask?.cancel()
        guard !demo else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func wentBackground() {
        clockTimer?.invalidate()
        clockTimer = nil
        pollTask?.cancel()
        pollTask = nil
        guard !demo else { return }
        syncTask?.cancel()
        let store = store, api = api
        Task { _ = try? await VajraSync.pushDirty(store: store, api: api) }  // дописать немедленно
    }

    /// Синк: дослать неотправленное + свежий снимок выбранного дня.
    func refresh() async {
        guard !demo, auth?.isSignedIn != false else { return }
        let d = selectedDate
        do {
            try await VajraSync.pushDirty(store: store, api: api)
            try await VajraSync.pullDay(store: store, api: api, date: d)
            auth?.markOnline()
        } catch SyncError.unauthorized {
            auth?.handleUnauthorized()
        } catch {
            auth?.markOffline()
        }
        if reload() { RecollectionAction.reloadWidgets() }
    }

    private func scheduleSync() {
        guard !demo else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try await VajraSync.pushDirty(store: self.store, api: self.api)
                self.auth?.markOnline()
            } catch SyncError.unauthorized {
                self.auth?.handleUnauthorized()
            } catch {
                self.auth?.markOffline()
            }
            if self.reload() { RecollectionAction.reloadWidgets() }
        }
    }

    /// Перечитать день из хранилища. true — показываемые слоты изменились.
    @discardableResult
    func reload() -> Bool {
        let s = store.slots(selectedDate)
        prevTotal = Slots.total(s)   // загрузка/синк ачивок не вызывает
        updateUndoCount()
        guard s != slots else { return false }
        slots = s
        return true
    }

    /// Полночь: катимся только вперёд и только если смотрели «сегодня» (как в вебе).
    func rolloverCheck() {
        clock = Date()
        let t = today
        if t != lastKnownToday {
            if t > lastKnownToday && selectedDate == lastKnownToday {
                setDate(t)
            }
            lastKnownToday = t
        }
    }

    // MARK: даты

    func setDate(_ d: String) {
        guard d <= today else { return }
        selectedDate = d
        sleepTillDone = false
        reload()
        if !demo { Task { await refresh() } }
    }

    func prevDay() { setDate(VajraDate.addDays(selectedDate, -1)) }
    func nextDay() { if selectedDate < today { setDate(VajraDate.addDays(selectedDate, 1)) } }

    /// Клик по «живому» UI пишет в СЕГОДНЯ, даже если дата в пикере отстала.
    @discardableResult
    private func ensureToday() -> Bool {
        guard selectedDate < today else { return false }
        setDate(today)
        return true
    }

    // MARK: правки

    /// Правки-установки разрешены только на дне, слитом с сервером: иначе пустая база затёрла бы
    /// серверные слоты. Незагруженный день сначала подтягиваем.
    private func ensureSynced(_ d: String) async -> Bool {
        if demo || store.isSynced(d) { return true }
        loadingDay = true
        defer { loadingDay = false }
        do {
            try await VajraSync.pullDay(store: store, api: shortAPI, date: d)
            auth?.markOnline()
        } catch SyncError.unauthorized {
            auth?.handleUnauthorized()
        } catch {
            auth?.markOffline()
        }
        reload()
        if store.isSynced(d) { return true }
        showToast("Нет данных дня, нужна сеть")
        return false
    }

    private func afterEdit(_ date: String, _ res: [Slot], changes: [SlotChange]) {
        if !changes.isEmpty {
            undo.append(UndoEntry(date: date, changes: changes))
            if undo.count > Self.undoMax { undo.removeFirst() }
        }
        if date == selectedDate {
            slots = res
            let t = Slots.total(res)
            if let m = Milestone.crossed(prev: prevTotal, total: t, shown: shownAch(date)) {
                markAch(date, m.n)
                Task { try? await Task.sleep(nanoseconds: 400_000_000); self.achievement = m }
            }
            prevTotal = t
        }
        monthDirty.insert(Self.monthKey(date))
        RecollectionAction.reloadWidgets()
        scheduleSync()
        updateUndoCount()
    }

    private var nowMs: Int64 { VajraDate.ms(Date()) }

    /// Удержание 3 с засчитано: +1 (дельта) в текущий слот сегодня → таймер с нуля → «Как вспомнил?».
    func holdCompleted() {
        ensureToday()
        let now = Date()
        let d = VajraDate.string(now), i = VajraDate.slotIndex(now)
        let r = store.addDelta(d, i: i, count: 1, nowMs: VajraDate.ms(now))
        afterEdit(d, r.slots, changes: [r.change])
        startTimer()
        qPending = QPending(date: d, index: i)
        qTask?.cancel()
        qTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.qAutoClose * 1e9))
            guard !Task.isCancelled else { return }
            self?.qClose()
        }
    }

    func qClose() { qTask?.cancel(); qPending = nil }

    /// Оценка — дельта; в отмене склеивается с +1 (откат снимает и +1, и оценку).
    func qPick(_ key: QKey) {
        guard let p = qPending else { return }
        qClose()
        guard p.date == selectedDate else { return }
        let r = store.addDelta(p.date, i: p.index, q: key, nowMs: nowMs)
        var changes = [r.change]
        if let last = undo.last, last.date == p.date, last.changes.count == 1,
           case let .delta(i, c, qc, qm, qa, _) = last.changes[0], i == p.index,
           case let .delta(_, _, nqc, nqm, nqa, t) = r.change {
            undo.removeLast()
            changes = [.delta(i: i, count: c, qc: qc + nqc, qm: qm + nqm, qa: qa + nqa, afterT: t)]
        }
        afterEdit(p.date, r.slots, changes: changes)
    }

    private func setEdit(_ f: @escaping (inout [Slot]) -> Void, done: (() -> Void)? = nil) {
        let d = selectedDate
        Task {
            guard await ensureSynced(d) else { return }
            let r = store.setSlots(d, nowMs: nowMs, f)
            afterEdit(d, r.slots, changes: r.changes)
            done?()
        }
    }

    func toggleSleepCurrent() {
        ensureToday()
        let i = currentIndex
        setEdit { $0[i].sleep.toggle() }
    }

    func toggleForgotCurrent() {
        ensureToday()
        let i = currentIndex
        setEdit { $0[i].forgot.toggle() }
    }

    enum SlotAct { case plus, minus, sleep, forgot }

    /// ± — дельты (работают и без загруженного дня), Сон/Забыл — установки.
    func act(_ a: SlotAct, _ i: Int) {
        guard (0..<Slots.count).contains(i) else { return }
        let d = selectedDate
        switch a {
        case .plus, .minus:
            if a == .minus && slots[i].count <= 0 { return }
            let r = store.addDelta(d, i: i, count: a == .plus ? 1 : -1, nowMs: nowMs)
            afterEdit(d, r.slots, changes: [r.change])
        case .sleep: setEdit { $0[i].sleep.toggle() }
        case .forgot: setEdit { $0[i].forgot.toggle() }
        }
    }

    /// «Сон до текущего времени»: слоты 0…ci-1.
    func sleepTillNow() {
        ensureToday()
        let ci = currentIndex
        setEdit({ s in for i in 0..<ci { s[i].sleep = true } }, done: { [weak self] in self?.sleepTillDone = true })
    }

    /// Полный обнул дня: все слоты с t = max(now, maxT + 1), иначе слияние воскресит данные с сервера.
    func resetDay() {
        let d = selectedDate
        Task {
            guard await ensureSynced(d) else { return }
            let r = store.resetDay(d, nowMs: nowMs)
            afterEdit(d, r.slots, changes: r.changes)
            sleepTillDone = false
            showToast("День сброшен")
        }
    }

    // MARK: отмена

    struct UndoEntry { let date: String; let changes: [SlotChange] }

    /// Откат только тех слотов, которые с нашей правки никто не трогал (t совпадает).
    func popUndo() {
        guard let k = undo.lastIndex(where: { $0.date == selectedDate }) else { showToast("Нечего отменять"); return }
        let e = undo.remove(at: k)
        let r = store.revert(e.date, e.changes, nowMs: nowMs)
        if e.date == selectedDate { slots = r.slots; prevTotal = Slots.total(r.slots) }
        monthDirty.insert(Self.monthKey(e.date))
        RecollectionAction.reloadWidgets()
        scheduleSync()
        updateUndoCount()
        showToast(r.skipped == 0 ? "Отменено" : (r.skipped == e.changes.count ? "Изменения уже перезаписаны" : "Отменено; часть изменений уже перезаписана"))
    }

    private func updateUndoCount() { undoCount = undo.filter { $0.date == selectedDate }.count }

    // MARK: таймер 3:00

    private func startTimer() {
        let now = Date()
        timerStart = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "vajra.timerStart")
    }

    private func restoreTimer() {
        let ts = UserDefaults.standard.double(forKey: "vajra.timerStart")
        guard ts > 0, Date().timeIntervalSince1970 - ts <= Self.timerDuration + Self.timerMaxOvertime else {
            UserDefaults.standard.removeObject(forKey: "vajra.timerStart")
            timerStart = nil
            return
        }
        timerStart = Date(timeIntervalSince1970: ts)
    }

    /// Оставшиеся секунды (минус — overtime), nil — таймер не запущен (кружок 3:00).
    func timerSeconds(at now: Date) -> Int {
        guard let s = timerStart else { return Int(Self.timerDuration) }
        let left = Int(Self.timerDuration) - Int(now.timeIntervalSince(s).rounded(.down))
        return max(left, -Int(Self.timerMaxOvertime))
    }

    nonisolated static func formatTimer(_ secs: Int) -> String {
        let a = abs(secs), sign = secs < 0 ? "+" : ""
        let h = a / 3600, m = (a % 3600) / 60, s = a % 60
        return h > 0 ? String(format: "%@%d:%02d", sign, h, m) : String(format: "%@%d:%02d", sign, m, s)
    }

    // MARK: ачивки

    private func shownAch(_ d: String) -> Set<Int> {
        Set((UserDefaults.standard.array(forKey: "vajra.ach." + d) as? [Int]) ?? [])
    }

    private func markAch(_ d: String, _ n: Int) {
        var s = shownAch(d); s.insert(n)
        UserDefaults.standard.set(Array(s), forKey: "vajra.ach." + d)
    }

    // MARK: тост

    func showToast(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: месяцы (календарь и сон)

    static func monthKey(_ date: String) -> String {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[0])-\(p[1])" : ""
    }

    func monthDays(_ ym: YM) -> [String: [Slot]] { months[ym.key] ?? localMonth(ym) }

    private func localMonth(_ ym: YM) -> [String: [Slot]] {
        let (from, to) = VajraDate.monthBounds(year: ym.year, month: ym.month)
        var out: [String: [Slot]] = [:]
        for d in store.allDates() where d >= from && d < to { out[d] = store.slots(d) }
        return out
    }

    /// Сначала — из локального кэша мгновенно, затем GET days?from&to по месяцу.
    func loadMonth(_ ym: YM) {
        let key = ym.key
        if months[key] != nil && !monthDirty.contains(key) { return }
        months[key] = localMonth(ym)
        guard !demo else { monthDirty.remove(key); return }
        let (from, to) = VajraDate.monthBounds(year: ym.year, month: ym.month)
        let cacheFrom = VajraDate.addDays(today, -60)
        Task {
            do {
                let days = try await VajraSync.pullRange(store: store, api: api, from: from, to: to, cacheFrom: cacheFrom)
                months[key] = days
                monthDirty.remove(key)
                reload()
            } catch SyncError.unauthorized {
                auth?.handleUnauthorized()
            } catch {
                auth?.markOffline()
            }
        }
    }

    func openDay(_ d: String) {
        tab = .tracker
        setDate(d)
    }
}
