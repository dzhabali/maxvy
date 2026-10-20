import AppIntents
import SwiftUI
import UIKit

@main
struct VajraApp: App {
    @UIApplicationDelegateAdaptor(VajraAppDelegate.self) private var appDelegate
    @StateObject private var settings: VajraSettings
    @StateObject private var auth: AuthManager
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let store: DayStore
        let bank: BankStore
        let settings: VajraSettings
        if demo {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vajra-demo-bank", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            let defs = UserDefaults(suiteName: "vajra.demo") ?? .standard
            defs.removePersistentDomain(forName: "vajra.demo")
            bank = BankStore(dir: dir, defaults: defs)
            bank.save(DemoData.bank)
            settings = VajraSettings(defaults: defs)
            settings.offerShown = ProcessInfo.processInfo.arguments.contains("-noOffer")

            store = DayStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("vajra-demo", isDirectory: true))
            DemoData.fill(store)
        } else {
            store = .shared
            bank = .shared
            settings = .shared
        }
        let auth = AuthManager(demo: demo)
        let model = AppModel(store: store, demo: demo, bank: bank, settings: settings)
        model.auth = auth
        if !demo {
            PingScheduler.shared.onAnswered = { [weak model] in Task { @MainActor in model?.reload() } }
        }
        settings.onChange = { [weak model, weak settings] in
            Task { @MainActor in
                if let settings {
                    IdleTimer.apply(active: UIApplication.shared.applicationState == .active, keepAwake: settings.keepAwake)
                }
                model?.showCurrentCard()
                if !demo { await PingScheduler.shared.reschedule() }
            }
        }
        _settings = StateObject(wrappedValue: settings)
        _auth = StateObject(wrappedValue: auth)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(model)
                .environmentObject(settings)
                .preferredColorScheme(.light)
                // демо-проверка вёрстки на ширине iPhone SE (375 pt) на любом симуляторе
                .frame(maxWidth: ProcessInfo.processInfo.arguments.contains("-narrow") ? 375 : .infinity)
                .task { await auth.check() }
                // onChange(scenePhase) не срабатывает на начальное .active при холодном старте
                .onAppear { if scenePhase == .active { model.becameActive() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.wentBackground()
            default: break
            }
            IdleTimer.apply(active: phase == .active, keepAwake: settings.keepAwake)
        }
    }
}

/// Siri и кнопка Action без настройки: фразы с именем приложения.
struct VajraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IncrementRecollectionIntent(),
            // ru — исходные; en — в AppShortcuts.xcstrings («Vajra plus one» через INAlternativeAppNames)
            phrases: [
                "\(.applicationName) плюс один",
                "Отметь памятование в \(.applicationName)",
            ],
            shortTitle: "Памятование +1",
            systemImageName: "suit.diamond.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor = .pink
}

/// Локальные демо-данные для `-demo` (без сети): этот и прошлый месяц, сегодня — до текущего слота.
enum DemoData {
    /// Нейтральный банк для демо и скриншотов (настоящие тексты — только на сервере).
    static let bank = Bank(version: 1,
                           views: [Bank.ViewCard(id: "d1", text: "Демонстрационная цитата длиной около двухсот двадцати знаков: здесь будет дословная строка из банка на сервере, а в публичном репозитории только этот нейтральный текст, чтобы проверить перенос строк, масштаб шрифта и подпись.", tag: nil, src: "Демо-источник"),
                                   Bank.ViewCard(id: "d2", text: "Вторая демонстрационная фраза", tag: nil)],
                           prompts: [Bank.Prompt(id: "p1", q: "Демо-вопрос", hint: "подсказка", tag: nil)])

    static func fill(_ store: DayStore, now: Date = Date()) {
        store.removeAll()
        let today = VajraDate.string(now)
        let ci = VajraDate.slotIndex(now)
        var rng = SplitMix(seed: 108)
        for back in 0..<45 {
            let d = VajraDate.addDays(today, -back)
            if back > 0 && rng.next() % 9 == 0 { continue }  // пропуски
            var s = Slots.empty()
            let last = back == 0 ? ci : 95
            let wake = 26 + Int(rng.next() % 8)               // 6:30–8:15
            let bed = 88 + Int(rng.next() % 6)                // 22:00–23:15
            for i in 0...last {
                if i < wake || i >= bed { s[i].sleep = true; s[i].t = 1; continue }
                let n = Int(rng.next() % 4)
                s[i].count = n
                if n > 0 {
                    s[i].t = 1
                    let q = Int(rng.next() % 10)
                    if q < 5 { s[i].qc = 1 } else if q < 8 { s[i].qm = 1 } else { s[i].qa = 1 }
                }
                if n == 0 && rng.next() % 6 == 0 { s[i].forgot = true; s[i].t = 1 }
            }
            store.put(d, .init(slots: s, updatedAt: nil, fetchedAt: Date().timeIntervalSince1970))
        }
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
