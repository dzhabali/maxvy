import Foundation
import SwiftUI
import UIKit

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
    /// Идёт подтягивание свежего дня перед «Сбросить день».
    @Published private(set) var loadingDay = false

    let store: DayStore
    let demo: Bool
    let bank: BankStore
    let settings: VajraSettings
    /// Фраза карточки воззрения (nil — карточка скрыта: выключена или банк пуст).
    @Published private(set) var cardText: String?
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

    init(store: DayStore = .shared, api: VajraAPI = .shared, demo: Bool = false,
         bank: BankStore = .shared, settings: VajraSettings? = nil) {
        self.store = store
        self.bank = bank
        self.settings = settings ?? .shared
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
        showCurrentCard()
    }

    // MARK: карточка воззрения

    private static let cardKey = "vajra.card.current"

    /// Следующая фраза из мешка (после засчитанного +1, при открытии, по тапу).
    func advanceCard() {
        let vs = bank.bank.views
        guard settings.cardEnabled, let id = bank.draw("views", ids: vs.map(\.id)) else { showCurrentCard(); return }
        bank.defaults.set(id, forKey: Self.cardKey)
        cardText = vs.first { $0.id == id }?.text
    }

    /// Показать текущую (после смены настроек / загрузки банка), не двигая мешок.
    func showCurrentCard() {
        guard settings.cardEnabled else { cardText = nil; return }
        let vs = bank.bank.views
        if let id = bank.defaults.string(forKey: Self.cardKey), let v = vs.first(where: { $0.id == id }) {
            cardText = v.text
        } else if vs.isEmpty {
            cardText = nil
        } else {
            advanceCard()
        }
    }

    /// Банк: при входе (force) и не чаще раза в 12 ч; изменился — карточка и пинги заново.
    func refreshBank(force: Bool = false) async {
        guard !demo else { return }
        if await bank.refresh(api: api, force: force) {
            showCurrentCard()
            await PingScheduler.shared.reschedule()
        }
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
        advanceCard()
        if !demo {
            Task {
                await refreshBank()
                await PingScheduler.shared.reschedule()
            }
        }
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
        PingScheduler.shared.submitRefresh()
        syncTask?.cancel()
        let store = store, api = api
        // дописать немедленно; фоновое время, чтобы система не усыпила посреди запроса
        let bg = BackgroundTask(name: "vajra-sync")
        Task {
            _ = try? await VajraSync.pushDirty(store: store, api: api)
            bg.end()
        }
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

    // MARK: правки — все через очередь операций (add / set по полям)

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

    /// Удержание 3 с засчитано: +1 в текущий слот сегодня → таймер с нуля → «Как вспомнил?».
    func holdCompleted() {
        ensureToday()
        let now = Date()
        let d = VajraDate.string(now), i = VajraDate.slotIndex(now)
        let r = store.add(d, i: i, count: 1, nowMs: VajraDate.ms(now))
        afterEdit(d, r.slots, changes: [r.change])
        advanceCard()
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

    /// Оценка — add; в отмене склеивается с +1 (откат снимает и +1, и оценку).
    func qPick(_ key: QKey) {
        guard let p = qPending else { return }
        qClose()
        guard p.date == selectedDate else { return }
        let r = store.add(p.date, i: p.index, q: key, nowMs: nowMs)
        var changes = [r.change]
        if let last = undo.last, last.date == p.date, last.changes.count == 1,
           case let .add(i, c, qc, qm, qa) = last.changes[0], i == p.index,
           case let .add(_, _, nqc, nqm, nqa) = r.change {
            undo.removeLast()
            changes = [.add(i: i, count: c, qc: qc + nqc, qm: qm + nqm, qa: qa + nqa)]
        }
        afterEdit(p.date, r.slots, changes: changes)
    }

    private func setFields(_ edits: [(i: Int, fields: SetFields)]) {
        let d = selectedDate
        let r = store.set(d, nowMs: nowMs, edits)
        afterEdit(d, r.slots, changes: r.changes)
    }

    func toggleSleepCurrent() {
        ensureToday()
        let i = currentIndex
        setFields([(i, SetFields(sleep: !slots[i].sleep))])
    }

    func toggleForgotCurrent() {
        ensureToday()
        let i = currentIndex
        setFields([(i, SetFields(forgot: !slots[i].forgot))])
    }

    enum SlotAct { case plus, plus5, minus, sleep, forgot }

    func act(_ a: SlotAct, _ i: Int) {
        guard (0..<Slots.count).contains(i) else { return }
        switch a {
        case .plus, .minus:
            if a == .minus && slots[i].count <= 0 { return }
            let d = selectedDate
            let r = store.add(d, i: i, count: a == .plus ? 1 : -1, nowMs: nowMs)
            afterEdit(d, r.slots, changes: [r.change])
        case .plus5:
            // «+5 ясно» задним числом (веб v2.8.2): одна операция add {count: 5, qc: 5}, одна отмена ↶
            let d = selectedDate
            let r = store.add(d, i: i, count: 5, q: .qc, qAmount: 5, nowMs: nowMs)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            afterEdit(d, r.slots, changes: [r.change])
        case .sleep: setFields([(i, SetFields(sleep: !slots[i].sleep))])
        case .forgot: setFields([(i, SetFields(forgot: !slots[i].forgot))])
        }
    }

    /// «Сон до текущего времени»: sleep=true в слотах 0…ci-1 (счёт не трогаем).
    func sleepTillNow() {
        ensureToday()
        let ci = currentIndex
        setFields((0..<ci).map { ($0, SetFields(sleep: true)) })
        sleepTillDone = true
    }

    /// «Сбросить день» намеренно обнуляет всё — только по свежему (≤ 60 с) снимку сервера.
    func resetDay() {
        let d = selectedDate
        Task {
            if !demo, Date().timeIntervalSince1970 - (store.record(d)?.fetchedAt ?? 0) > 60 {
                loadingDay = true
                do {
                    try await VajraSync.pushDay(store: store, api: shortAPI, date: d)
                    try await VajraSync.pullDay(store: store, api: shortAPI, date: d)
                    auth?.markOnline()
                } catch SyncError.unauthorized {
                    auth?.handleUnauthorized()
                } catch {
                    auth?.markOffline()
                }
                loadingDay = false
                reload()
                guard Date().timeIntervalSince1970 - (store.record(d)?.fetchedAt ?? 0) <= 60 else {
                    showToast("Нет данных дня, нужна сеть")
                    return
                }
            }
            let r = store.resetDay(d, nowMs: nowMs)
            afterEdit(d, r.slots, changes: r.changes)
            sleepTillDone = false
            showToast("День сброшен")
        }
    }

    // MARK: отмена

    struct UndoEntry { let date: String; let changes: [SlotChange] }

    /// add откатывается обратной add; set — только если слот с нашей правки никто не трогал (t совпадает).
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

/// beginBackgroundTask/endBackgroundTask, закрываемый один раз.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
