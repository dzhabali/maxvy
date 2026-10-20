import AppIntents
import Foundation
import WidgetKit

/// Логика «+1» без UI — её зовут интент, кнопка виджета и тесты.
enum RecollectionAction {
    struct Result: Equatable {
        let total: Int
        /// Дельта дошла до сервера.
        let sent: Bool
    }

    /// +1 в текущий слот сегодняшнего дня (дата и слот — из ОДНОГО момента now, по местному времени)
    /// операцией add (безопасна и на незагруженном дне); если дан api — сразу пробует отправить.
    @discardableResult
    static func increment(store: DayStore, now: Date = Date(), calendar: Calendar = .current, api: VajraBackend?,
                          networkBudget: TimeInterval = 3) async -> Result {
        let day = VajraDate.string(now, calendar: calendar)
        let i = VajraDate.slotIndex(now, calendar: calendar)
        var slots = store.add(day, i: i, count: 1, nowMs: VajraDate.ms(now)).slots
        DiagLog.log("intent add", "day \(day) slot \(Slots.time(i)) slotCount \(slots[i].count) total \(Slots.total(slots)) container …/\(DiagLog.containerTail) groupMissing \(VajraConfig.appGroupMissing)")
        VajraNotify.post()
        if api != nil { reloadWidgets() }   // сразу, до сети
        var sent = false
        if let api {
            // сеть — не дольше networkBudget; не успели — op остаётся в очереди и дойдёт из приложения
            let err: String? = await withTaskGroup(of: String?.self) { g in
                g.addTask {
                    do { try await VajraSync.pushDay(store: store, api: api, date: day); return nil }
                    catch { return "\(error)" }
                }
                g.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(networkBudget * 1e9))
                    return "timeout"
                }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first
            }
            sent = store.record(day)?.ops.isEmpty == true
            DiagLog.log("intent push", "sent \(sent)\(err.map { " err " + $0 } ?? "")")
            slots = store.slots(day)
            VajraNotify.post()
        }
        return Result(total: Slots.total(slots), sent: sent)
    }

    static func todayTotal(store: DayStore, now: Date = Date()) -> Int {
        Slots.total(store.slots(VajraDate.string(now)))
    }

    static func reloadWidgets() {
        DiagLog.log("reloadWidgets")
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

/// «Памятование +1» — для экрана блокировки, Пункта управления, кнопки Action, Siri и виджета.
struct IncrementRecollectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Памятование +1"
    static var description = IntentDescription("Добавляет одно памятование в текущий 15-минутный слот сегодняшнего дня.")
    static var openAppWhenRun: Bool = false
    /// iOS 26+: явно — только фоном, приложение не открывать (замена устаревшему openAppWhenRun).
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    static var isDiscoverable: Bool = true

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let t0 = Date()
        DiagLog.log("intent start", "process \(DiagLog.process)")
        defer { DiagLog.log("intent end", "\(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        let r = await RecollectionAction.increment(store: .shared, api: VajraAPI(session: VajraAPI.makeSession(timeout: 5)))
        RecollectionAction.reloadWidgets()
        let text = r.sent ? "Сегодня \(r.total)" : "Сохранено на телефоне. Сегодня \(r.total)"
        return .result(value: r.total, dialog: IntentDialog(stringLiteral: text))
    }
}
