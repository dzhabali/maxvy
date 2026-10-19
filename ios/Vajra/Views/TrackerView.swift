import SwiftUI
import UIKit

struct TrackerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSleep = false
    @State private var confirmReset = false

    var body: some View {
        let isToday = model.isToday
        let ci = model.currentIndex
        ScrollView {
            VStack(spacing: 0) {
                DateNav()
                if isToday {
                    Button { confirmSleep = true } label: {
                        Text(model.sleepTillDone ? "Сон до \(Slots.time(ci)) — отмечено ✓" : "Сон до текущего времени")
                            .font(.system(size: 13))
                            .foregroundStyle(model.sleepTillDone ? Palette.blueText : Palette.text2)
                            .frame(maxWidth: .infinity).padding(9)
                            .background(model.sleepTillDone ? Palette.blueBg : Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.sleepTillDone ? Palette.blueBorder : Palette.border))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Palette.surface2.ignoresSafeArea(edges: .horizontal))
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1).ignoresSafeArea(edges: .horizontal) }

                    Button { model.histOpen.toggle() } label: {
                        Text(model.histOpen ? "↓ скрыть" : "↑ прошлые слоты")
                            .font(.system(size: 12)).foregroundStyle(Palette.text3)
                            .frame(maxWidth: .infinity).padding(7)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.top, 4)
                }

                if !isToday {
                    HistoryList(upTo: Slots.count, scrollable: false).padding(.top, 8)
                } else if model.histOpen {
                    HistoryList(upTo: ci, scrollable: true).padding(.top, 8)
                }

                if isToday {
                    NeighborSlot(index: ci - 1).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                    MainHoldButton().padding(.horizontal, 16).padding(.bottom, 10)
                    HStack(spacing: 8) {
                        BottomToggle(title: "Сон", on: model.slots[ci].sleep, style: .green) { model.toggleSleepCurrent() }
                        BottomToggle(title: "Забыл", on: model.slots[ci].forgot, style: .amber) { model.toggleForgotCurrent() }
                    }
                    .padding(.horizontal, 16)
                }

                QualityStatsLine(q: model.quality).padding(.horizontal, 16).padding(.top, 8)

                if isToday {
                    NeighborSlot(index: ci + 1).padding(.horizontal, 16).padding(.top, 8)
                }

                Button("сбросить день") { confirmReset = true }
                    .font(.system(size: 11)).underline().foregroundStyle(Palette.faint)
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                if let s = VajraStats.fmtSleep(model.sleepMinutes) {
                    Text("сон — \(s)").font(.system(size: 13)).foregroundStyle(Palette.text2)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Palette.chip, in: Capsule())
                        .overlay(Capsule().stroke(Palette.border))
                        .padding(.top, 6)
                }
                Spacer(minLength: 16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { FooterProgress(total: model.total) }
        .alert("Подтверждаешь?", isPresented: $confirmSleep) {
            Button("Отметить") { model.sleepTillNow() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сон с 0:00 до \(Slots.time(ci)) будет отмечен.") }
        .alert("Сбросить день?", isPresented: $confirmReset) {
            Button("Сбросить", role: .destructive) { model.resetDay() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все данные за \(model.selectedDate) — очки, сон и «забыл» — обнулятся. Отменить можно кнопкой ↶.")
        }
    }
}

struct DateNav: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            navButton("‹") { model.prevDay() }
            Text((model.isToday ? "Сегодня, " : "") + RuDate.dayMonth(model.selectedDate))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity)
            navButton("›") { model.nextDay() }.opacity(model.isToday ? 0.4 : 1).disabled(model.isToday)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Palette.surface2.ignoresSafeArea(edges: .horizontal))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1).ignoresSafeArea(edges: .horizontal) }
    }

    private func navButton(_ s: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(s).font(.system(size: 15)).foregroundStyle(Palette.text2)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
        }
        .buttonStyle(.plain)
    }
}

/// Главная кнопка: таймер 3:00 слева, счёт текущего слота справа; +1 — только удержанием 3 с.
struct MainHoldButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var holdStart: Date?
    @State private var completed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let now = ctx.date
            let secs = model.timerSeconds(at: now)
            let over = secs < 0
            let ratio: Double = over ? min(Double(-secs) / AppModel.timerDuration, 1) : Double(secs) / AppModel.timerDuration
            let fill: Double = holdStart.map { min(1, now.timeIntervalSince($0) / AppModel.holdSeconds) } ?? 0
            let ci = model.currentIndex
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 9)
                    Circle().trim(from: 0, to: ratio)
                        .stroke(Color.white.opacity(over ? 0.9 : 0.85), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        GemShapeView(size: 22)
                        Text(AppModel.formatTimer(secs)).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        Text(Slots.time(ci)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 104, height: 104)
                .padding(8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.slots[ci].count)")
                        .font(.system(size: 72, weight: .ultraLight)).foregroundStyle(.white)
                        .kerning(-2).lineLimit(1).minimumScaleFactor(0.5)
                    Text(hint(now)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().fill(Color(hex: 0xfda4cf, opacity: 0.38)).frame(width: g.size.width * fill)
                }
            }
            .background(holdStart != nil ? Palette.crimson2 : (over ? Palette.crimson : Palette.mint))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .onLongPressGesture(minimumDuration: AppModel.holdSeconds, maximumDistance: 40) {
            completed = true
            holdStart = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.holdCompleted()
        } onPressingChanged: { pressing in
            if pressing {
                completed = false
                holdStart = Date()
            } else {
                if let s = holdStart, !completed {
                    let held = Date().timeIntervalSince(s)
                    if held > 0.15 && held < AppModel.holdSeconds - 0.05 { model.showToast("Держи 3 секунды") }
                }
                holdStart = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Вспомнил +1, удерживай 3 секунды")
        .accessibilityAction(named: "Плюс один") { model.holdCompleted() }
    }

    private func hint(_ now: Date) -> String {
        guard let s = holdStart else { return "держи 3 сек — вспомни" }
        let left = Int((AppModel.holdSeconds - now.timeIntervalSince(s)).rounded(.up))
        return left > 0 ? "вспоминай… \(left)" : "вспоминай…"
    }
}

struct GemButton: View {
    let plus: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                GemShapeView(size: 13)
                Text(plus ? "+" : "−").font(.system(size: 13))
            }
            .foregroundStyle(plus ? Palette.gemText : Palette.text2)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(plus ? Palette.gemBg : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(plus ? Palette.gemBorder : Palette.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plus ? "плюс" : "минус")
    }
}

struct SmallToggle: View {
    let title: String
    let on: Bool
    let amber: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(on ? title + " ✓" : title).font(.system(size: 12))
                .foregroundStyle(on ? (amber ? Palette.amberText : Palette.greenDark) : Palette.text2)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(on ? (amber ? Palette.amberBg : Palette.greenBg) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? (amber ? Palette.amberBorder : Palette.greenBorder) : Palette.border))
        }
        .buttonStyle(.plain)
    }
}

struct NeighborSlot: View {
    @EnvironmentObject private var model: AppModel
    let index: Int

    var body: some View {
        if (0..<Slots.count).contains(index) {
            let s = model.slots[index]
            HStack(spacing: 10) {
                Text(Slots.time(index)).font(.system(size: 13)).foregroundStyle(Palette.text2).frame(width: 44, alignment: .leading)
                Text(s.count > 0 ? "\(s.count)" : "—").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                GemButton(plus: true) { model.act(.plus, index) }
                GemButton(plus: false) { model.act(.minus, index) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
        }
    }
}

struct HistoryList: View {
    @EnvironmentObject private var model: AppModel
    let upTo: Int
    let scrollable: Bool

    var body: some View {
        Group {
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .frame(maxHeight: 300)
                        .onAppear { if upTo > 0 { proxy.scrollTo(upTo - 1, anchor: .bottom) } }
                }
            } else {
                rows
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
        .padding(.horizontal, 16)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<max(0, upTo), id: \.self) { i in
                let s = model.slots[i]
                HStack(spacing: 8) {
                    Text(Slots.time(i)).font(.system(size: 13)).foregroundStyle(Palette.text2).frame(width: 44, alignment: .leading)
                    Text("\(s.count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text).frame(minWidth: 18, alignment: .leading)
                    Spacer(minLength: 0)
                    GemButton(plus: true) { model.act(.plus, i) }
                    GemButton(plus: false) { model.act(.minus, i) }
                    SmallToggle(title: "Сон", on: s.sleep, amber: false) { model.act(.sleep, i) }
                    SmallToggle(title: "Забыл", on: s.forgot, amber: true) { model.act(.forgot, i) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Palette.surface)
                .overlay(alignment: .bottom) { if i < upTo - 1 { Rectangle().fill(Palette.chip).frame(height: 1) } }
                .id(i)
            }
        }
    }
}

struct BottomToggle: View {
    enum Style { case green, amber }
    let title: String
    let on: Bool
    let style: Style
    let action: () -> Void

    var body: some View {
        let fg = on ? (style == .green ? Palette.greenDark : Palette.amberText) : Palette.text2
        let bg = on ? (style == .green ? Palette.greenBg : Palette.amberBg) : Palette.surface
        let bd = on ? (style == .green ? Palette.greenBorder : Palette.amberBorder) : Palette.border
        Button(action: action) {
            Text(on ? title + " ✓" : title).font(.system(size: 13)).foregroundStyle(fg)
                .frame(maxWidth: .infinity).padding(12)
                .background(bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(bd))
        }
        .buttonStyle(.plain)
    }
}

struct QualityStatsLine: View {
    let q: VajraStats.Quality
    var body: some View {
        if q.n > 0 {
            Text("ясно \(Text("\(q.qc)").bold()) · средне \(Text("\(q.qm)").bold()) · автомат \(Text("\(q.qa)").bold()) — ясных \(q.clearPct)%")
                .font(.system(size: 12)).foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
        }
    }
}

struct FooterProgress: View {
    let total: Int
    var body: some View {
        let pct = VajraStats.goalPct(total)
        HStack(spacing: 12) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.chip)
                    Capsule().fill(Color(hex: VajraStats.footerColorHex(pct: pct)))
                        .frame(width: g.size.width * CGFloat(pct) / 100)
                }
                .overlay(Capsule().stroke(Palette.border))
            }
            .frame(height: 10)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pct)
            Text("\(total) / \(VajraConfig.goal)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            Text("\(pct)%").font(.system(size: 12)).foregroundStyle(Palette.text2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Palette.surface.ignoresSafeArea(edges: [.bottom, .horizontal]))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1).ignoresSafeArea(edges: .horizontal) }
    }
}
