import SwiftUI

/// Телефон горизонтально (как в вебе): весь экран = кнопка, +1 удержанием 3 с.
/// Слева таймер с подписью, справа счёт текущего слота, внизу — день из 100. Всегда сегодня.
struct LandscapeQuickTap: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let ring = min(h * 0.55, 220)
            HoldSurface(cornerRadius: 0) { t in
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(spacing: 12) {
                            TimerRing(t: t, lineWidth: 10, gem: ring * 0.15, value: ring * 0.2, unit: ring * 0.09, slot: 14)
                                .frame(width: ring, height: ring)
                            Text(timerCaption(t))
                                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center).lineLimit(2)
                                .frame(width: ring + 40)
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("в слоте \(Slots.time(t.ci))–\(Slots.time(t.ci + 1))")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            Text("\(model.isToday ? model.slots[t.ci].count : 0)")
                                .font(.system(size: min(h * 0.45, 200), weight: .ultraLight)).foregroundStyle(.white)
                                .kerning(-4).lineLimit(1).minimumScaleFactor(0.5)
                                .contentTransition(.numericText())
                            Text(t.hint).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxHeight: .infinity)

                    dayLine
                }
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 14)
                .padding(EdgeInsets(top: g.safeAreaInsets.top, leading: g.safeAreaInsets.leading,
                                    bottom: g.safeAreaInsets.bottom, trailing: g.safeAreaInsets.trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { dayBar }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { if !model.isToday { model.setDate(model.today) } }   // живой режим — только сегодня
    }

    private func timerCaption(_ t: HoldTick) -> String {
        if t.over { return "пора вспомнить — сверх 3 мин" }
        if model.timerStart == nil { return "таймер 3 мин стартует с +1" }
        return "до следующего памятования"
    }

    private var dayLine: some View {
        let total = model.isToday ? model.total : 0
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("за день").foregroundStyle(.white.opacity(0.6))
            Text("\(total) из \(VajraConfig.goal)").fontWeight(.semibold).foregroundStyle(.white)
            Spacer(minLength: 8)
            Text("\(VajraStats.goalPct(total))%").foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 14).monospacedDigit())
    }

    private var dayBar: some View {
        let pct = VajraStats.goalPct(model.isToday ? model.total : 0)
        return GeometryReader { b in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.15))
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: b.size.width * CGFloat(pct) / 100)
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pct)
    }
}
