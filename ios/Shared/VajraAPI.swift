import Foundation

enum SyncError: Error, Equatable {
    case unauthorized
    case server(Int)
    case badResponse
    case network
}

/// Клиент /vajra/api на life.maxdzhabali.com (сервер — life-chronicle/personal_apps.py).
struct VajraAPI {
    static let base = URL(string: "https://life.maxdzhabali.com")!
    static let loginURL = base.appendingPathComponent("chronicle/login")
    static let meURL = base.appendingPathComponent("vajra/api/me")
    static let cookieName = "life"

    /// Кука `life` живёт в общем для App Group хранилище — её видят и приложение, и расширение виджетов.
    static var cookies: HTTPCookieStorage {
        HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: VajraConfig.appGroup)
    }

    static func makeSession(timeout: TimeInterval = 20) -> URLSession {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = cookies
        c.httpCookieAcceptPolicy = .always
        c.httpShouldSetCookies = true
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    static let shared = VajraAPI(session: makeSession())

    // MARK: кука `life` — копия в UserDefaults группы (запасной путь для расширения)

    private static let cookieKey = "lifeCookie"
    private static var groupDefaults: UserDefaults? { UserDefaults(suiteName: VajraConfig.appGroup) }

    private static func save(_ c: HTTPCookie) {
        var rec: [String: Any] = ["value": c.value]
        if let e = c.expiresDate { rec["expires"] = e.timeIntervalSince1970 }
        groupDefaults?.set(rec, forKey: cookieKey)
    }

    /// Запомнить куку из ответа с Set-Cookie.
    static func rememberCookie(from resp: URLResponse?) {
        guard let http = resp as? HTTPURLResponse, let url = http.url,
              let fields = http.allHeaderFields as? [String: String] else { return }
        if let c = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first(where: { $0.name == cookieName }) { save(c) }
    }

    /// Запомнить куку из хранилища (после входа: 303-редирект Set-Cookie видит только хранилище).
    static func rememberCookieFromStorage() {
        if let c = cookies.cookies(for: base)?.first(where: { $0.name == cookieName }) { save(c) }
    }

    static func forgetCookie() { groupDefaults?.removeObject(forKey: cookieKey) }

    /// Если в хранилище куки нет (другой процесс) — заголовок Cookie вручную из копии.
    static func prepare(_ r: inout URLRequest) {
        if cookies.cookies(for: base)?.contains(where: { $0.name == cookieName }) == true { return }
        guard let rec = groupDefaults?.dictionary(forKey: cookieKey), let v = rec["value"] as? String else { return }
        if let e = rec["expires"] as? Double, e < Date().timeIntervalSince1970 { return }
        r.setValue("\(cookieName)=\(v)", forHTTPHeaderField: "Cookie")
    }

    let session: URLSession

    static func serverDay(_ obj: [String: Any]) -> ServerDay {
        ServerDay(slots: Slots.norm(obj["slots"]), updatedAt: obj["updatedAt"] as? String,
                  appliedTail: (obj["applied_tail"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    private static let opsQuery = [URLQueryItem(name: "ops", value: "1")]

    func getDay(_ date: String) async throws -> ServerDay {
        Self.serverDay(try await call("GET", "days/" + date, query: Self.opsQuery))
    }

    /// POST ops — идемпотентно по id; ответ — итоговый день.
    func postOps(_ date: String, _ ops: [Op]) async throws -> ServerDay {
        Self.serverDay(try await call("POST", "days/" + date + "/ops", query: Self.opsQuery, body: ["ops": ops.map(\.json)]))
    }

    /// Старый PUT {slots} → слияние по слотам на сервере (только для миграции билда 2).
    func putDay(_ date: String, _ slots: [Slot]) async throws -> ServerDay {
        Self.serverDay(try await call("PUT", "days/" + date, body: ["slots": Slots.toJSON(slots)]))
    }

    /// GET days?from&to (to — не включительно).
    func getRange(from: String, to: String) async throws -> [String: ServerDay] {
        let obj = try await call("GET", "days", query: [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)] + Self.opsQuery)
        var out: [String: ServerDay] = [:]
        for (k, v) in obj { if let rec = v as? [String: Any] { out[k] = Self.serverDay(rec) } }
        return out
    }

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(url: Self.base.appendingPathComponent("vajra/api/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        Self.prepare(&r)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw SyncError.network }
        Self.rememberCookie(from: resp)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }
        if http.statusCode == 401 { throw SyncError.unauthorized }
        guard http.statusCode == 200 else { throw SyncError.server(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncError.badResponse }
        return obj
    }
}

/// Сервер для синка (в тестах — модель сервера в памяти).
protocol VajraBackend {
    func getDay(_ date: String) async throws -> ServerDay
    func postOps(_ date: String, _ ops: [Op]) async throws -> ServerDay
    func putDay(_ date: String, _ slots: [Slot]) async throws -> ServerDay
}

extension VajraAPI: VajraBackend {}

/// Один синк дня на процесс; между процессами безопасно — операции идемпотентны на сервере.
actor DaySyncGate {
    static let shared = DaySyncGate()
    private var running: [String: Task<Void, Error>] = [:]

    /// Работы одного дня выстраиваются цепочкой: каждая ждёт предыдущую (без опроса в цикле).
    func run(_ date: String, _ work: @escaping () async throws -> Void) async throws {
        let prev = running[date]
        let t = Task {
            _ = try? await prev?.value
            try await work()
        }
        running[date] = t
        defer { if running[date] == t { running[date] = nil } }
        try await t.value
    }
}

/// Синк, общий для приложения и интентов.
enum VajraSync {
    /// Отправка очередей всех дней. Возвращает число отправленных дней.
    @discardableResult
    static func pushDirty(store: DayStore, api: VajraBackend) async throws -> Int {
        var n = 0
        for d in store.dirtyDates() {
            try await pushDay(store: store, api: api, date: d)
            n += 1
        }
        return n
    }

    /// Под flock — ожидающие операции (без удаления) → POST /ops → ответ = снимок, отправленные id — из очереди.
    /// Повтор после потерянного ответа безопасен: сервер уже знает эти id.
    static func pushDay(store: DayStore, api: VajraBackend, date: String, gate: DaySyncGate = .shared) async throws {
        try await gate.run(date) {
            if let rec = store.record(date), rec.legacyDirty {
                store.clearLegacy(date, response: try await api.putDay(date, rec.slots))
            }
            // кусками ≤ 200 (лимит сервера); после каждого ответа — удалить ровно отправленные id
            while let ops = store.record(date)?.ops, !ops.isEmpty {
                let chunk = Array(ops.prefix(VajraOps.batch))
                let r = try await api.postOps(date, chunk)
                store.applyServer(date, r, sent: Set(chunk.map(\.id)))
            }
        }
    }

    /// GET дня → снимок.
    static func pullDay(store: DayStore, api: VajraBackend, date: String, gate: DaySyncGate = .shared) async throws {
        try await gate.run(date) {
            store.applyServer(date, try await api.getDay(date))
        }
    }

    /// Месяц: в локальный кэш — только дни окна cacheFrom… (последние ~60) и уже известные; показ — снимок + очередь.
    static func pullRange(store: DayStore, api: VajraAPI, from: String, to: String, cacheFrom: String) async throws -> [String: [Slot]] {
        let server = try await api.getRange(from: from, to: to)
        var out: [String: [Slot]] = [:]
        for (d, day) in server {
            out[d] = (d >= cacheFrom || store.exists(d)) ? store.applyServer(d, day) : day.slots
        }
        for d in store.allDates() where d >= from && d < to && out[d] == nil {
            out[d] = store.slots(d)
        }
        return out
    }
}
