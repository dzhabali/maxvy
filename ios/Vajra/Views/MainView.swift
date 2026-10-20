import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TabsBar()
            if VajraConfig.appGroupMissing {
                Text("App Group недоступна — виджеты и кнопка +1 не видят данные приложения")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x991b1b))
                    .frame(maxWidth: .infinity).padding(8)
                    .background(Color(hex: 0xfee2e2).ignoresSafeArea(edges: .horizontal))
            }
            if model.loadingDay {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("загружаю день…").font(.system(size: 12)) }
                    .foregroundStyle(Palette.text2).frame(maxWidth: .infinity).padding(6)
                    .background(Palette.surface2.ignoresSafeArea(edges: .horizontal))
            }
            Group {
                switch model.tab {
                case .tracker: TrackerView()
                case .calendar: CalendarTab()
                case .sleep: SleepTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .overlay(alignment: .top) { ToastView(text: model.toast) }
        .overlay { QualityOverlay() }
        .overlay { AchievementOverlay() }
    }
}

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthManager
    @State private var confirmLogout = false
    @State private var showSettings = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if let e = auth.email { Text(e) }
                Button("Выйти", role: .destructive) { confirmLogout = true }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Ваджра-трекер").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.text)
                    Text("v\(version)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3)
                }
            }
            Spacer(minLength: 4)
            if model.undoCount > 0 {
                Button { model.popUndo() } label: {
                    Text("↶ \(model.undoCount)").font(.system(size: 12)).foregroundStyle(Palette.text2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Capsule().stroke(Palette.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Отменить последнее действие")
            }
            if auth.offline {
                Text("⚡ оффлайн").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amberText)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Palette.amberBg, in: Capsule())
                    .overlay(Capsule().stroke(Palette.amberBorder))
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Palette.text2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
            Text(RuDate.dayMonth(model.selectedDate)).font(.system(size: 12)).foregroundStyle(Palette.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Palette.chip, in: Capsule())
                .overlay(Capsule().stroke(Palette.border))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Palette.surface.ignoresSafeArea(edges: [.top, .horizontal]))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1).ignoresSafeArea(edges: .horizontal) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-settings") { showSettings = true } }
        .confirmationDialog("Выйти из Life? Локальные данные останутся на телефоне.", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { auth.signOut() }
        }
    }
}

struct TabsBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            tab("Трекер", .tracker)
            tab("Календарь", .calendar)
            tab("Сон", .sleep)
        }
        .background(Palette.surface.ignoresSafeArea(edges: .horizontal))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1).ignoresSafeArea(edges: .horizontal) }
    }

    private func tab(_ title: String, _ t: AppModel.Tab) -> some View {
        let on = model.tab == t
        return Button { model.tab = t } label: {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Palette.crimson : Palette.text2)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(on ? Palette.crimson : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum RuDate {
    static let months = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
    static let genitive = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    /// «19 октября»
    static func dayMonth(_ s: String) -> String {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]) else { return s }
        return "\(p[2]) \(genitive[p[1] - 1])"
    }
}

struct ToastView: View {
    let text: String?
    var body: some View {
        Group {
            if let text {
                Text(text).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Palette.text, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: text)
        .allowsHitTesting(false)
    }
}
