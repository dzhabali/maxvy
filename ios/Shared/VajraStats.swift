import Foundation

/// Статистика — те же правила, что в вебе (vajra-tracker.html v2.8.1).
enum VajraStats {
    struct Month: Equatable {
        var sum: Int?      // «за месяц» — nil = «—»
        var avg: Int?      // «среднее/день» — только завершённые дни (без сегодня), с ненулевым счётом
        var best: Int?     // «лучший день»
        var days: Int?     // «дней практики»
    }

    /// drawCalendar: суммы по дням с ненулевым счётом; среднее — без сегодняшнего дня, Math.round.
    static func month(_ days: [String: [Slot]], today: String) -> Month {
        let sums = days.mapValues { Slots.total($0) }
        let vals = sums.values.filter { $0 > 0 }
        let avgVals = sums.filter { $0.value > 0 && $0.key != today }.map(\.value)
        let sum = vals.reduce(0, +)
        return Month(sum: sum == 0 ? nil : sum,
                     avg: avgVals.isEmpty ? nil : jsRound(Double(avgVals.reduce(0, +)) / Double(avgVals.count)),
                     best: vals.max(),
                     days: vals.isEmpty ? nil : vals.count)
    }

    /// calcSleepMinutes: число слотов «сон» × 15.
    static func sleepMinutes(_ slots: [Slot]) -> Int { slots.filter(\.sleep).count * 15 }

    /// Среднее время сна за месяц: дни с mins>0, без сегодня, округление до 5 минут.
    static func monthSleepAvg(_ days: [String: [Slot]], today: String) -> Int? {
        let mins = days.filter { $0.key != today }.map { sleepMinutes($0.value) }.filter { $0 > 0 }
        guard !mins.isEmpty else { return nil }
        return jsRound(Double(mins.reduce(0, +)) / Double(mins.count) / 5) * 5
    }

    /// fmtSleepTime: "Ч:ММ"; 0 → nil.
    static func fmtSleep(_ mins: Int) -> String? {
        guard mins > 0 else { return nil }
        return String(format: "%d:%02d", mins / 60, mins % 60)
    }

    struct Quality: Equatable { var qc = 0, qm = 0, qa = 0
        var n: Int { qc + qm + qa }
        var clearPct: Int { n == 0 ? 0 : jsRound(Double(qc) / Double(n) * 100) }
    }

    static func quality(_ slots: [Slot]) -> Quality {
        slots.reduce(into: Quality()) { $0.qc += $1.qc; $0.qm += $1.qm; $0.qa += $1.qa }
    }

    /// Прогресс к цели: min(100, round(t/100*100)).
    static func goalPct(_ total: Int) -> Int { min(100, jsRound(Double(total) / Double(VajraConfig.goal) * 100)) }

    /// Цвет счёта дня в календаре (scoreColor) — hex.
    static func scoreColorHex(_ n: Int) -> UInt32 {
        if n >= 100 { return 0xc0185a }
        if n >= 76 { return 0xf59e0b }
        if n >= 51 { return 0x22c55e }
        if n >= 26 { return 0x06b6d4 }
        return 0x94a3b8
    }

    /// Цвет полосы прогресса в футере.
    static func footerColorHex(pct: Int) -> UInt32 {
        pct >= 100 ? 0xf59e0b : pct >= 67 ? 0x22c55e : pct >= 34 ? 0x06b6d4 : 0x94a3b8
    }

    /// Math.round из JS (половина — вверх).
    static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
}

/// Ачивки дня (MILESTONES в вебе).
struct Milestone: Equatable, Identifiable {
    let n: Int
    let label: String
    let sub: String
    let colorHex: UInt32
    let khechara: Bool
    var id: Int { n }

    static let all: [Milestone] = [
        Milestone(n: 25, label: "ДОСТИЖЕНИЕ", sub: "Начало", colorHex: 0x1d6ef5, khechara: false),
        Milestone(n: 50, label: "ПОЛПУТИ", sub: "Полпути", colorHex: 0x8b5cf6, khechara: false),
        Milestone(n: 75, label: "ПОЧТИ", sub: "Почти", colorHex: 0xf59e0b, khechara: false),
        Milestone(n: 100, label: "КХЕЧАРА", sub: "Небеса открыты", colorHex: 0x7c3aed, khechara: true),
    ]

    /// Первая ачивка, порог которой пересечён (prev < n ≤ total) и ещё не показан сегодня.
    static func crossed(prev: Int, total: Int, shown: Set<Int>) -> Milestone? {
        all.first { total >= $0.n && prev < $0.n && !shown.contains($0.n) }
    }
}
