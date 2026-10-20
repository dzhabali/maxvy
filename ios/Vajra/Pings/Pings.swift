import BackgroundTasks
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Настройки карточки и пингов (UserDefaults группы).
@MainActor
final class VajraSettings: ObservableObject {
    static let shared = VajraSettings(defaults: UserDefaults(suiteName: VajraConfig.appGroup) ?? .standard)

    let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var cardEnabled: Bool { didSet { defaults.set(cardEnabled, forKey: "vajra.cardEnabled"); onChange?() } }
    @Published var pingsEnabled: Bool { didSet { defaults.set(pingsEnabled, forKey: "vajra.pings.on"); onChange?() } }
    @Published var perDay: Int { didSet { defaults.set(perDay, forKey: "vajra.pings.perDay"); onChange?() } }
    /// Окно в минутах от полуночи; конец ≤ начала — окно через полночь.
    @Published var startMin: Int { didSet { defaults.set(startMin, forKey: "vajra.pings.start"); onChange?() } }
    @Published var endMin: Int { didSet { defaults.set(endMin, forKey: "vajra.pings.end"); onChange?() } }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "vajra.pings.sound"); onChange?() } }
    @Published var offerShown: Bool { didSet { defaults.set(offerShown, forKey: "vajra.pings.offerShown") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func v<T>(_ k: String, _ d: T) -> T { defaults.object(forKey: k) as? T ?? d }
        cardEnabled = v("vajra.cardEnabled", true)
        pingsEnabled = v("vajra.pings.on", false)
        perDay = min(12, max(1, v("vajra.pings.perDay", 5)))
        startMin = v("vajra.pings.start", 8 * 60)
        endMin = v("vajra.pings.end", 21 * 60)
        sound = v("vajra.pings.sound", true)
        offerShown = v("vajra.pings.offerShown", false)
    }
}

/// Случайные моменты пингов: окно каждого дня делится на perDay равных отрезков, момент — внутри
/// отрезка с отступом minGap/2 от краёв → соседние (и через границу дней) не ближе minGap.
enum PingSchedule {
    static let days = 7
    static let minGap: TimeInterval = 45 * 60
    static let maxTotal = 50

    static func generate<R: RandomNumberGenerator>(now: Date, calendar: Calendar, perDay: Int, startMin: Int, endMin: Int,
                                                   days: Int = days, minGap: TimeInterval = minGap, maxTotal: Int = maxTotal,
                                                   using rng: inout R) -> [Date] {
        guard perDay > 0 else { return [] }
        var out: [Date] = []
        let today = calendar.startOfDay(for: now)
        // со вчерашнего: окно через полночь, начатое вчера, ещё может идти
        for k in -1..<days {
            guard let day = calendar.date(byAdding: .day, value: k, to: today),
                  let ws = at(day, startMin, calendar) else { continue }
            let endDay = endMin <= startMin ? calendar.date(byAdding: .day, value: 1, to: day) ?? day : day
            guard let we = at(endDay, endMin, calendar) else { continue }
            let w = we.timeIntervalSince(ws)
            guard w > minGap else { continue }
            let n = min(perDay, max(1, Int(w / minGap)))
            let seg = w / Double(n)
            for j in 0..<n {
                let lo = ws.addingTimeInterval(Double(j) * seg + minGap / 2)
                let span = max(0, seg - minGap)
                let t = lo.addingTimeInterval(span * Double.random(in: 0...1, using: &rng))
                if t > now { out.append(t) }
            }
        }
        return Array(out.sorted().prefix(maxTotal))
    }

    /// Момент «день + минуты» по календарю (DST: несуществующее время → ближайшее следующее).
    private static func at(_ day: Date, _ minutes: Int, _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: day, matchingPolicy: .nextTime,
                 repeatedTimePolicy: .first, direction: .forward)
    }
}

/// Ответ на пинг «Вспомнил +1»: та же операция, что засчёт удержанием — add {count 1} в слот момента ответа.
enum PingAnswer {
    static let category = "PING"
    static let prefix = "ping-"

    static let plusAction = "plus1"

    @discardableResult
    static func apply(store: DayStore, now: Date = Date(), calendar: Calendar = .current) -> (date: String, change: SlotChange) {
        let d = VajraDate.string(now, calendar: calendar)
        let i = VajraDate.slotIndex(now, calendar: calendar)
        let r = store.add(d, i: i, count: 1, nowMs: VajraDate.ms(now))
        return (d, r.change)
    }
}

/// Планирование уведомлений и обработка действий.
@MainActor
final class PingScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PingScheduler()
    static let bgTask = "com.maxdzhabali.vajra.pings"

    var settings: VajraSettings = .shared
    var bank: BankStore = .shared
    var store: DayStore = .shared
    var onAnswered: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func registerAtLaunch() {
        center.delegate = self
        let acts = [UNNotificationAction(identifier: PingAnswer.plusAction, title: "Вспомнил +1", options: [])]
        center.setNotificationCategories([UNNotificationCategory(identifier: PingAnswer.category, actions: acts, intentIdentifiers: [])])
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTask, using: nil) { task in
            Task { @MainActor in
                await PingScheduler.shared.reschedule()
                PingScheduler.shared.submitRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }

    func submitRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.bgTask)
        r.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Разрешение при включении. false — отказ.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Пересоздать все пинги (выкл — просто снять).
    func reschedule(now: Date = Date()) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(PingAnswer.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard settings.pingsEnabled else { return }
        let st = await center.notificationSettings()
        guard st.authorizationStatus == .authorized || st.authorizationStatus == .provisional else { return }
        var g = SystemRandomNumberGenerator()
        let times = PingSchedule.generate(now: now, calendar: .current, perDay: settings.perDay,
                                          startMin: settings.startMin, endMin: settings.endMin, using: &g)
        for t in times {
            let p = bank.nextPrompt()
            let c = UNMutableNotificationContent()
            c.title = p.q
            if let h = p.hint, !h.isEmpty { c.body = h }
            c.categoryIdentifier = PingAnswer.category
            c.interruptionLevel = .active
            if settings.sound { c.sound = .default }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
            let req = UNNotificationRequest(identifier: PingAnswer.prefix + UUID().uuidString, content: c,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == PingAnswer.category,
              response.actionIdentifier == PingAnswer.plusAction else { return }   // тап по самому пингу — просто открыть
        await handle()
    }

    private func handle() async {
        let bg = BackgroundTask(name: "vajra-ping")
        let r = PingAnswer.apply(store: store)
        VajraNotify.post()
        RecollectionAction.reloadWidgets()
        onAnswered?()
        try? await VajraSync.pushDay(store: store, api: VajraAPI(session: VajraAPI.makeSession(timeout: 5)), date: r.date)
        VajraNotify.post()
        RecollectionAction.reloadWidgets()
        await reschedule()
        bg.end()
    }
}

final class VajraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !VajraConfig.isTesting && !ProcessInfo.processInfo.arguments.contains("-demo") {
            MainActor.assumeIsolated { PingScheduler.shared.registerAtLaunch() }
        }
        return true
    }
}

// MARK: экран настроек

struct SettingsSheet: View {
    @EnvironmentObject private var settings: VajraSettings
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Карточка воззрения", isOn: $settings.cardEnabled)
                } footer: { Text("Фраза над главной кнопкой; меняется после каждого +1 и по тапу.") }

                Section {
                    Toggle("Пинги-вопросы", isOn: Binding(get: { settings.pingsEnabled }, set: { on in
                        if on { Task { await PingToggle.enable(settings) { denied = !$0 } } } else { settings.pingsEnabled = false }
                    }))
                    if denied {
                        Text("Разреши в Settings → Notifications → Ваджра").font(.footnote).foregroundStyle(Palette.amberText)
                    }
                    Stepper("Сколько в день: \(settings.perDay)", value: $settings.perDay, in: 1...12)
                    DatePicker("С", selection: minutes($settings.startMin), displayedComponents: .hourAndMinute)
                    DatePicker("До", selection: minutes($settings.endMin), displayedComponents: .hourAndMinute)
                    Toggle("Звук", isOn: $settings.sound)
                } header: { Text("Пинги на экран блокировки") } footer: {
                    Text("Случайные моменты в окне, не чаще раза в 45 мин. Кнопка «Вспомнил +1» прямо с экрана блокировки засчитывает +1.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }

    private func minutes(_ b: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: b.wrappedValue / 60, minute: b.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }
}

enum PingToggle {
    /// Включить пинги: спросить разрешение; при отказе — выключено и подсказка.
    @MainActor
    static func enable(_ s: VajraSettings, result: @escaping (Bool) -> Void) async {
        s.offerShown = true
        let ok = await PingScheduler.shared.requestAuthorization()
        s.pingsEnabled = ok
        result(ok)
    }
}

/// Плашка «Включить пинги-вопросы?» — один раз после обновления.
struct PingOffer: View {
    @EnvironmentObject private var settings: VajraSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !settings.offerShown && !settings.pingsEnabled {
            HStack(spacing: 10) {
                Text("Включить пинги-вопросы?").font(.system(size: 13)).foregroundStyle(Palette.text2)
                Spacer(minLength: 4)
                Button("Включить") {
                    Task { await PingToggle.enable(settings) { ok in if !ok { model.showToast("Разреши в Settings → Notifications") } } }
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.crimson)
                Button { settings.offerShown = true } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                    .foregroundStyle(Palette.text3)
                    .accessibilityLabel("Не надо")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        }
    }
}
