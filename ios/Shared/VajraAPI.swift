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

    func getDay(_ date: String) async throws -> (slots: [Slot], updatedAt: String?, exists: Bool) {
        let obj = try await call("GET", "days/" + date)
        return (Slots.norm(obj["slots"]), obj["updatedAt"] as? String, Slots.pyTruthy(obj["exists"]))
    }

    /// PUT {slots} → сервер сливает по слотам и возвращает итог {slots, updatedAt}.
    func putDay(_ date: String, _ slots: [Slot]) async throws -> (slots: [Slot], updatedAt: String?) {
        let obj = try await call("PUT", "days/" + date, body: ["slots": Slots.toJSON(slots)])
        return (Slots.norm(obj["slots"]), obj["updatedAt"] as? String)
    }

    /// GET days?from&to (to — не включительно) → {дата: slots}.
    func getRange(from: String, to: String) async throws -> [String: (slots: [Slot], updatedAt: String?)] {
        let obj = try await call("GET", "days", query: [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)])
        var out: [String: (slots: [Slot], updatedAt: String?)] = [:]
        for (k, v) in obj {
            guard let rec = v as? [String: Any] else { continue }
            out[k] = (Slots.norm(rec["slots"]), rec["updatedAt"] as? String)
        }
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

/// Синк, общий для приложения и интентов.
enum VajraSync {
    /// Отправка всех дней с неотправленным. Возвращает число отправленных.
    @discardableResult
    static func pushDirty(store: DayStore, api: VajraAPI) async throws -> Int {
        var n = 0
        for d in store.dirtyDates() {
            try await pushDay(store: store, api: api, date: d)
            n += 1
        }
        return n
    }

    /// Дельты — на СВЕЖИЙ серверный день (GET перед PUT); без дельт — снимок как есть.
    static func pushDay(store: DayStore, api: VajraAPI, date: String) async throws {
        guard let rec = store.record(date), rec.needsPush else { return }
        let body: [Slot]
        if rec.deltas.isEmpty {
            body = rec.slots
        } else {
            body = DayStore.pushBody(rec, server: try await api.getDay(date).slots)
        }
        let r = try await api.putDay(date, body)
        store.commitPush(date, response: r.slots, updatedAt: r.updatedAt, sentDeltaIds: Set(rec.deltas.map(\.id)))
    }

    /// GET дня → слияние с локальным; день становится «загруженным» (synced), даже если на сервере пуст.
    static func pullDay(store: DayStore, api: VajraAPI, date: String) async throws {
        let r = try await api.getDay(date)
        store.applyServer(date, slots: r.slots, updatedAt: r.updatedAt)
    }

    /// Месяц: сервер ⊕ локальное. В локальный кэш кладутся только дни из окна cacheFrom… (последние ~60).
    static func pullRange(store: DayStore, api: VajraAPI, from: String, to: String, cacheFrom: String) async throws -> [String: [Slot]] {
        let server = try await api.getRange(from: from, to: to)
        var out: [String: [Slot]] = [:]
        for (d, rec) in server {
            if d >= cacheFrom || store.exists(d) {
                out[d] = store.applyServer(d, slots: rec.slots, updatedAt: rec.updatedAt)
            } else {
                out[d] = rec.slots
            }
        }
        for d in store.allDates() where d >= from && d < to && out[d] == nil {
            out[d] = store.slots(d)
        }
        return out
    }
}
