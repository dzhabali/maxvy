import AppIntents
import SwiftUI

@main
struct VajraApp: App {
    @StateObject private var auth: AuthManager
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let store: DayStore
        if demo {
            store = DayStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("vajra-demo", isDirectory: true))
            DemoData.fill(store)
        } else {
            store = .shared
        }
        let auth = AuthManager(demo: demo)
        let model = AppModel(store: store, demo: demo)
        model.auth = auth
        _auth = StateObject(wrappedValue: auth)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(model)
                .preferredColorScheme(.light)
                .task { await auth.check() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.wentBackground()
            default: break
            }
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

    struct SplitMix {
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
