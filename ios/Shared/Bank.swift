import Foundation

/// Банк воззрений (карточка над кнопкой) и вопросов (пинги). Живёт только на сервере
/// (`GET /vajra/api/bank`, за входом Life); в репозитории текстов нет — здесь лишь формат и кэш.
struct Bank: Codable, Equatable {
    struct ViewCard: Codable, Equatable { var id: String; var text: String; var tag: String?; var src: String? = nil }
    struct Prompt: Codable, Equatable { var id: String; var q: String; var hint: String?; var tag: String? }

    var version: Int = 0
    var views: [ViewCard] = []
    var prompts: [Prompt] = []

    static let empty = Bank()
    /// Вопрос пинга, когда банка нет.
    static let neutralQuestion = "Что сейчас перед тобой?"
}

/// «Мешок»: все id в случайном порядке без повторов, потом заново. Смена набора id не сбрасывает
/// уже показанные в этом круге — новые id добавляются к непоказанным.
struct ShuffleBag: Codable, Equatable {
    var order: [String] = []
    var pos = 0

    mutating func next<R: RandomNumberGenerator>(_ ids: [String], using rng: inout R) -> String? {
        var uniq: [String] = []
        var seenIDs = Set<String>()
        for id in ids where seenIDs.insert(id).inserted { uniq.append(id) }
        guard !uniq.isEmpty else { return nil }
        let all = Set(uniq)
        if Set(order) != all || order.count != uniq.count {
            let shown = order.prefix(min(pos, order.count)).filter { all.contains($0) }
            let shownSet = Set(shown)
            order = shown + uniq.filter { !shownSet.contains($0) }.shuffled(using: &rng)
            pos = shown.count
        }
        if pos >= order.count {
            let last = order.last
            order = uniq.shuffled(using: &rng)
            if order.count > 1, order.first == last { order.swapAt(0, order.count - 1) }
            pos = 0
        }
        defer { pos += 1 }
        return order[pos]
    }

    mutating func next(_ ids: [String]) -> String? {
        var g = SystemRandomNumberGenerator()
        return next(ids, using: &g)
    }
}

/// Кэш банка в контейнере App Group + мешки в UserDefaults группы.
final class BankStore {
    static let shared = BankStore(dir: VajraConfig.containerURL(), defaults: UserDefaults(suiteName: VajraConfig.appGroup) ?? .standard)
    static let refreshInterval: TimeInterval = 12 * 3600

    let defaults: UserDefaults
    private let file: URL
    private let lock = NSLock()
    private var cached: Bank?

    init(dir: URL, defaults: UserDefaults) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("bank.json")
        self.defaults = defaults
    }

    var bank: Bank {
        lock.withLock {
            if let cached { return cached }
            let b = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Bank.self, from: $0) } ?? .empty
            cached = b
            return b
        }
    }

    func save(_ b: Bank) {
        lock.withLock {
            cached = b
            if let d = try? JSONEncoder().encode(b) { try? d.write(to: file, options: .atomic) }
        }
    }

    var lastFetch: Date? {
        get { let t = defaults.double(forKey: "vajra.bank.fetched"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "vajra.bank.fetched") }
    }

    func isStale(now: Date = Date()) -> Bool {
        guard let l = lastFetch else { return true }
        return now.timeIntervalSince(l) >= Self.refreshInterval || now < l
    }

    /// Загрузить с сервера (force — при входе). true — банк изменился.
    @discardableResult
    func refresh(api: VajraAPI, force: Bool = false, now: Date = Date()) async -> Bool {
        guard force || isStale(now: now) else { return false }
        guard let b = try? await api.getBank() else { return false }
        lastFetch = now
        guard b != bank else { return false }
        save(b)
        return true
    }

    // MARK: мешки

    func draw<R: RandomNumberGenerator>(_ key: String, ids: [String], using rng: inout R) -> String? {
        lock.withLock {
            let k = "vajra.bag." + key
            var bag = defaults.data(forKey: k).flatMap { try? JSONDecoder().decode(ShuffleBag.self, from: $0) } ?? ShuffleBag()
            let id = bag.next(ids, using: &rng)
            if let d = try? JSONEncoder().encode(bag) { defaults.set(d, forKey: k) }
            return id
        }
    }

    func draw(_ key: String, ids: [String]) -> String? {
        var g = SystemRandomNumberGenerator()
        return draw(key, ids: ids, using: &g)
    }

    /// Следующий вопрос пинга (без банка — нейтральный).
    func nextPrompt() -> Bank.Prompt {
        let ps = bank.prompts
        if let id = draw("prompts", ids: ps.map(\.id)), let p = ps.first(where: { $0.id == id }) { return p }
        return Bank.Prompt(id: "neutral", q: Bank.neutralQuestion, hint: nil, tag: nil)
    }
}

extension VajraAPI {
    /// GET /vajra/api/bank — JSON как есть.
    func getBank() async throws -> Bank {
        var r = URLRequest(url: Self.base.appendingPathComponent("vajra/api/bank"))
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.prepare(&r)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw SyncError.network }
        Self.rememberCookie(from: resp)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }
        if http.statusCode == 401 { throw SyncError.unauthorized }
        guard http.statusCode == 200 else { throw SyncError.server(http.statusCode) }
        guard let b = try? JSONDecoder().decode(Bank.self, from: data) else { throw SyncError.badResponse }
        return b
    }
}

/// Цитата для виджетов: детерминированно по (дата, 15-мин слот) среди views подходящей длины —
/// держится весь слот и не трогает «мешок» карточки приложения.
enum QuotePick {
    static let lockMax = 90      // экран блокировки
    static let smallMax = 110    // «Цитата» маленький / StandBy
    static let mediumMax = 160   // «Домой» средний
    static let noBank = "Открой Ваджру, чтобы загрузить выдержки"

    static func pick(_ views: [Bank.ViewCard], maxLen: Int, date: String, slot: Int) -> Bank.ViewCard? {
        let ok = views.filter { !$0.text.isEmpty && $0.text.count <= maxLen }
        guard !ok.isEmpty else { return nil }
        return ok[Int(hash("\(date)#\(slot)") % UInt64(ok.count))]
    }

    /// FNV-1a 64 — стабилен между запусками (в отличие от Hasher).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}
