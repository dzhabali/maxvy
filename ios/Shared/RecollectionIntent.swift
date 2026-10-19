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
    static func increment(store: DayStore, now: Date = Date(), calendar: Calendar = .current, api: VajraBackend?) async -> Result {
        let day = VajraDate.string(now, calendar: calendar)
        let i = VajraDate.slotIndex(now, calendar: calendar)
        var slots = store.add(day, i: i, count: 1, nowMs: VajraDate.ms(now)).slots
        VajraNotify.post()
        var sent = false
        if let api {
            do {
                try await VajraSync.pushDay(store: store, api: api, date: day)
                sent = store.record(day)?.ops.isEmpty == true
            } catch {
                sent = false   // 401 / нет сети: операция остаётся и дойдёт из приложения
            }
            slots = store.slots(day)
            VajraNotify.post()
        }
        return Result(total: Slots.total(slots), sent: sent)
    }

    static func todayTotal(store: DayStore, now: Date = Date()) -> Int {
        Slots.total(store.slots(VajraDate.string(now)))
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

/// «Памятование +1» — для экрана блокировки, Пункта управления, кнопки Action, Siri и виджета.
struct IncrementRecollectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Памятование +1"
    static var description = IntentDescription("Добавляет одно памятование в текущий 15-минутный слот сегодняшнего дня.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let r = await RecollectionAction.increment(store: .shared, api: VajraAPI(session: VajraAPI.makeSession(timeout: 5)))
        RecollectionAction.reloadWidgets()
        let text = r.sent ? "Сегодня \(r.total)" : "Сохранено на телефоне. Сегодня \(r.total)"
        return .result(value: r.total, dialog: IntentDialog(stringLiteral: text))
    }
}
