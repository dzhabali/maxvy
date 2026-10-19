import SwiftUI

private let weekdays = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

/// Дни месяца сеткой с понедельника: nil — пустая ячейка.
private func monthCells(_ ym: AppModel.YM) -> [String?] {
    let cal = Calendar(identifier: .gregorian)
    let first = cal.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)) ?? Date()
    var dow = cal.component(.weekday, from: first) - 1   // 0 = вс
    if dow == 0 { dow = 7 }
    let n = VajraDate.daysInMonth(year: ym.year, month: ym.month, calendar: cal)
    var out: [String?] = Array(repeating: nil, count: dow - 1)
    for d in 1...n { out.append(String(format: "%04d-%02d-%02d", ym.year, ym.month, d)) }
    return out
}

struct StatTile: View {
    let value: String
    let label: String
    var big = false
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: big ? 22 : 18, weight: .bold)).foregroundStyle(Palette.text)
            Text(label).font(.system(size: big ? 11 : 10)).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).padding(.horizontal, 6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
    }
}

struct MonthNav: View {
    @Binding var ym: AppModel.YM
    var body: some View {
        HStack {
            btn("‹") { ym = ym.adding(-1) }
            Spacer()
            Text("\(RuDate.months[ym.month - 1]) \(String(ym.year))").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
            Spacer()
            btn("›") { ym = ym.adding(1) }
        }
        .padding(.bottom, 12)
    }
    private func btn(_ s: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(s).font(.system(size: 15)).foregroundStyle(Palette.text2)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
        }
        .buttonStyle(.plain)
    }
}

struct WeekdayHeader: View {
    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 3) {
            ForEach(weekdays, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Palette.text3).padding(.vertical, 3) }
        }
        .padding(.bottom, 3)
    }
}

struct CalendarTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let days = model.monthDays(model.calMonth)
        let today = model.today
        let st = VajraStats.month(days, today: today)
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    StatTile(value: st.sum.map(String.init) ?? "—", label: "за месяц")
                    StatTile(value: st.avg.map(String.init) ?? "—", label: "среднее/день")
                    StatTile(value: st.best.map(String.init) ?? "—", label: "лучший день")
                    StatTile(value: st.days.map(String.init) ?? "—", label: "дней практики")
                }
                .padding(.bottom, 14)
                MonthNav(ym: $model.calMonth)
                WeekdayHeader()
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(Array(monthCells(model.calMonth).enumerated()), id: \.offset) { _, ds in
                        if let ds {
                            let score = Slots.total(days[ds] ?? [])
                            Button { model.openDay(ds) } label: { ScoreCell(ds: ds, score: score, isToday: ds == today) }
                                .buttonStyle(.plain)
                                .disabled(ds > today)
                        } else {
                            Color.clear.frame(minHeight: 54)
                        }
                    }
                }
                legend.padding(.top, 12)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .onAppear { model.loadMonth(model.calMonth) }
        .onChange(of: model.calMonth) { _, ym in model.loadMonth(ym) }
    }

    private var legend: some View {
        let items: [(UInt32, String)] = [(0x94a3b8, "1–25"), (0x06b6d4, "26–50"), (0x22c55e, "51–75"), (0xf59e0b, "76–99"), (0xc0185a, "100+ 🔥")]
        return VStack(spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1).padding(.bottom, 10)
            HStack(spacing: 14) {
                ForEach(items, id: \.1) { c, t in
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: c)).frame(width: 9, height: 9)
                        Text(t).font(.system(size: 12)).foregroundStyle(Palette.text2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ScoreCell: View {
    let ds: String
    let score: Int
    let isToday: Bool

    var body: some View {
        let color = Color(hex: VajraStats.scoreColorHex(score))
        let pct = CGFloat(VajraStats.goalPct(score)) / 100
        VStack(spacing: 2) {
            Text(String(Int(ds.suffix(2)) ?? 0)).font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Palette.crimson : Palette.text3)
            if score > 0 {
                Text(score >= 100 ? "\(score)🔥" : "\(score)").font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.6)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.chip)
                        Capsule().fill(color).frame(width: g.size.width * pct)
                    }
                }
                .frame(height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isToday ? Palette.crimson : Palette.border, lineWidth: isToday ? 1.5 : 1))
    }
}

struct SleepTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let days = model.monthDays(model.sleepMonth)
        let today = model.today
        ScrollView {
            VStack(spacing: 0) {
                StatTile(value: VajraStats.monthSleepAvg(days, today: today).flatMap(VajraStats.fmtSleep) ?? "—",
                         label: "среднее время сна за месяц", big: true)
                    .padding(.bottom, 14)
                MonthNav(ym: $model.sleepMonth)
                WeekdayHeader()
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(Array(monthCells(model.sleepMonth).enumerated()), id: \.offset) { _, ds in
                        if let ds {
                            let mins = VajraStats.sleepMinutes(days[ds] ?? [])
                            VStack(spacing: 2) {
                                Text(String(Int(ds.suffix(2)) ?? 0)).font(.system(size: 11, weight: ds == today ? .semibold : .regular))
                                    .foregroundStyle(ds == today ? Palette.crimson : Palette.text3)
                                if let s = VajraStats.fmtSleep(mins) {
                                    Text(s).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.text2)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ds == today ? Palette.crimson : Palette.border, lineWidth: ds == today ? 1.5 : 1))
                        } else {
                            Color.clear.frame(minHeight: 54)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .onAppear { model.loadMonth(model.sleepMonth) }
        .onChange(of: model.sleepMonth) { _, ym in model.loadMonth(ym) }
    }
}
