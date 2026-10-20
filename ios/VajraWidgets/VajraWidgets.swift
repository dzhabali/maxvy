import AppIntents
import SwiftUI
import WidgetKit

@main
struct VajraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CountWidget()
        QuoteWidget()
        PlusOneControl()
    }
}

// MARK: - Счёт дня

struct CountEntry: TimelineEntry {
    let date: Date
    let total: Int
    let slotCount: Int
    let slotIndex: Int
}

struct CountProvider: TimelineProvider {
    func placeholder(in context: Context) -> CountEntry {
        CountEntry(date: Date(), total: 37, slotCount: 2, slotIndex: VajraDate.slotIndex(Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (CountEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.entry(at: Date()))
    }

    /// Одна запись — свежее чтение store; следующий запрос — на начало следующего слота
    /// (а не цепочка на 4 ч с замороженными числами).
    func getTimeline(in context: Context, completion: @escaping (Timeline<CountEntry>) -> Void) {
        let now = Date()
        let e = Self.entry(at: now)
        DiagLog.log("count getTimeline", "\(context.family) total \(e.total) slot \(Slots.time(e.slotIndex)) slotCount \(e.slotCount)")
        completion(Timeline(entries: [e], policy: .after(VajraDate.nextSlotStart(after: now))))
    }

    static func entry(at now: Date) -> CountEntry {
        let slots = DayStore.shared.slots(VajraDate.string(now))
        let i = VajraDate.slotIndex(now)
        DiagLog.log("count entry", "total \(Slots.total(slots)) slot \(Slots.time(i)) slotCount \(slots[i].count) container …/\(DiagLog.containerTail)")
        return CountEntry(date: now, total: Slots.total(slots), slotCount: slots[i].count, slotIndex: i)
    }
}

struct CountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VajraConfig.countKind, provider: CountProvider()) { e in
            CountWidgetView(entry: e)
        }
        .configurationDisplayName("Ваджра — счёт дня")
        .description("Памятования за сегодня и прогресс к цели 100.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct CountWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CountEntry

    private var progress: Double { min(Double(entry.total), Double(VajraConfig.goal)) / Double(VajraConfig.goal) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: progress) {
                Image(systemName: "suit.diamond.fill")
            } currentValueLabel: {
                Text("\(entry.total)").font(.system(size: 16, weight: .semibold)).minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .containerBackground(for: .widget) { Color.clear }
            .widgetAccentable()

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "suit.diamond.fill").font(.system(size: 11))
                    Text("Ваджра").font(.system(size: 13, weight: .semibold))
                }
                .widgetAccentable()
                Text("\(entry.total) / \(VajraConfig.goal)").font(.system(size: 20, weight: .bold)).minimumScaleFactor(0.6)
                Text("слот \(Slots.time(entry.slotIndex)) · \(entry.slotCount)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }

        default:
            SmallCountView(entry: entry, progress: progress)
                .containerBackground(for: .widget) { Palette.mint }
        }
    }
}

struct SmallCountView: View {
    let entry: CountEntry
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                GemShapeView(size: 18)
                Spacer()
                Text(Slots.time(entry.slotIndex)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.total)").font(.system(size: 40, weight: .light)).foregroundStyle(.white)
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .widgetAccentable()
                Text("/ \(VajraConfig.goal)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 5)
            Button(intent: IncrementRecollectionIntent()) {
                Text("+1").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.mint)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}

// MARK: - Цитата (экран блокировки, маленький/StandBy, средний «Домой»)

struct QuoteEntry: TimelineEntry {
    let date: Date
    let total: Int
    /// nil — банка нет.
    let lock: Bank.ViewCard?
    let small: Bank.ViewCard?
    let medium: Bank.ViewCard?
}

struct QuoteProvider: TimelineProvider {
    static let demo = Bank.ViewCard(id: "demo", text: "Здесь будет короткая выдержка из банка", tag: nil, src: "Источник")

    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: Date(), total: 37, lock: Self.demo, small: Self.demo, medium: Self.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.entries(now: Date(), count: 1)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        let now = Date()
        let e = Self.entries(now: now, count: 1)
        DiagLog.log("quote getTimeline", "\(context.family) total \(e[0].total) quote \(e[0].medium?.id ?? "nil")")
        completion(Timeline(entries: e, policy: .after(VajraDate.nextSlotStart(after: now))))
    }

    /// Сейчас + начало каждого следующего слота (4 ч); цитата — по (дата, слот), счёт — как у CountWidget.
    static func entries(now: Date, count: Int) -> [QuoteEntry] {
        let views = BankStore.shared.bank.views
        let today = VajraDate.string(now)
        let total = Slots.total(DayStore.shared.slots(today))
        var out: [QuoteEntry] = []
        var t = now
        for _ in 0..<count {
            let d = VajraDate.string(t), i = VajraDate.slotIndex(t)
            func q(_ m: Int) -> Bank.ViewCard? { QuotePick.pick(views, maxLen: m, date: d, slot: i) }
            out.append(QuoteEntry(date: t, total: d == today ? total : 0,
                                  lock: q(QuotePick.lockMax), small: q(QuotePick.smallMax), medium: q(QuotePick.mediumMax)))
            t = VajraDate.nextSlotStart(after: t)
        }
        return out
    }
}

struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VajraConfig.quoteKind, provider: QuoteProvider()) { e in
            QuoteWidgetView(entry: e)
        }
        .configurationDisplayName("Ваджра — цитата")
        .description("Выдержка, меняется каждые 15 минут. Средний — со счётом дня и кнопкой +1.")
        .supportedFamilies([.accessoryRectangular, .systemSmall, .systemMedium])
    }
}

struct QuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsBg
    @Environment(\.widgetRenderingMode) private var mode
    let entry: QuoteEntry

    /// Светлый фон приложения — только на домашнем экране в полном цвете; в StandBy/тонировке — системный.
    private var light: Bool { showsBg && mode == .fullColor }
    private var fg: Color { light ? Palette.text : .primary }
    private var fg2: Color { light ? Palette.text2 : .secondary }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            Text(entry.lock?.text ?? QuotePick.noBank)
                .font(.system(size: 12)).italic()
                .lineLimit(3).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .containerBackground(for: .widget) { Color.clear }
        case .systemMedium:
            HStack(spacing: 12) {
                quote(entry.medium, lines: 4, size: 14)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(entry.total)").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(fg)
                            .lineLimit(1).minimumScaleFactor(0.5).widgetAccentable()
                        Text("/\(VajraConfig.goal)").font(.system(size: 13)).foregroundStyle(fg2)
                    }
                    Spacer(minLength: 0)
                    Button(intent: IncrementRecollectionIntent()) {
                        Text("+1").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 72).padding(.vertical, 8)
                            .background(Palette.mint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .widgetAccentable()
                }
                .frame(width: 96)
            }
            .containerBackground(for: .widget) { Palette.bg }
        default:
            quote(entry.small, lines: 5, size: 13)
                .containerBackground(for: .widget) { Palette.bg }
        }
    }

    private func quote(_ v: Bank.ViewCard?, lines: Int, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v?.text ?? QuotePick.noBank)
                .font(.system(size: size)).italic().foregroundStyle(fg)
                .lineLimit(lines).minimumScaleFactor(0.8)
            if let s = v?.src, !s.isEmpty {
                Text("— " + s).font(.system(size: 10)).foregroundStyle(fg2).lineLimit(1).widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Кнопка «+1» (экран блокировки, Пункт управления, кнопка Action)

struct PlusOneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.maxdzhabali.vajra.plusone") {
            ControlWidgetButton(action: IncrementRecollectionIntent()) {
                Label("Памятование +1", systemImage: "suit.diamond.fill")
            }
        }
        .displayName("Ваджра +1")
        .description("Отмечает памятование в текущем 15-минутном слоте.")
    }
}
