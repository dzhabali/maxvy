import AppIntents
import SwiftUI
import WidgetKit

@main
struct VajraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CountWidget()
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

    /// Запись сейчас + на начало каждого следующего 15-минутного слота (4 часа вперёд).
    /// Счёт будущих записей берётся из текущего файла дня; после полуночи — новый день (0).
    func getTimeline(in context: Context, completion: @escaping (Timeline<CountEntry>) -> Void) {
        let now = Date()
        let store = DayStore.shared
        let today = VajraDate.string(now)
        let slots = store.slots(today)
        var entries: [CountEntry] = []
        var t = now
        for _ in 0..<17 {
            let same = VajraDate.string(t) == today
            let i = VajraDate.slotIndex(t)
            entries.append(CountEntry(date: t, total: same ? Slots.total(slots) : 0, slotCount: same ? slots[i].count : 0, slotIndex: i))
            t = VajraDate.nextSlotStart(after: t)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func entry(at now: Date) -> CountEntry {
        let slots = DayStore.shared.slots(VajraDate.string(now))
        let i = VajraDate.slotIndex(now)
        return CountEntry(date: now, total: Slots.total(slots), slotCount: slots[i].count, slotIndex: i)
    }
}

struct CountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.maxdzhabali.vajra.count", provider: CountProvider()) { e in
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
