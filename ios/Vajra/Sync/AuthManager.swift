import Foundation

/// Вход паролем Life: POST /chronicle/login (pw, next=/vajra/) → кука `life` (Path=/, год).
/// Пароль не хранится. Кука — в общем хранилище App Group (её видят интенты/виджеты).
@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable { case checking, signedOut, signedIn }

    @Published private(set) var state: State = .checking
    @Published private(set) var email: String?
    @Published private(set) var offline = false

    private let flagKey = "vajra.wasSignedIn"
    private let emailKey = "vajra.email"
    private let urlSession = VajraAPI.shared.session
    private let demo: Bool

    private var wasSignedIn: Bool {
        get { UserDefaults.standard.bool(forKey: flagKey) }
        set { UserDefaults.standard.set(newValue, forKey: flagKey) }
    }

    init(demo: Bool = false) {
        self.demo = demo
        email = UserDefaults.standard.string(forKey: emailKey)
        if demo { state = .signedIn }
    }

    var isSignedIn: Bool { state == .signedIn }

    /// GET /vajra/api/me. Нет сети, но раньше входили — пускаем офлайн (данные локальные).
    func check() async {
        if demo { return }
        switch await fetchMe() {
        case .ok:
            offline = false
            state = .signedIn
        case .unauthorized:
            markSignedOut()
        case .unreachable:
            offline = true
            state = wasSignedIn ? .signedIn : .signedOut
        }
    }

    /// nil — успех, иначе текст ошибки.
    func signIn(password: String) async -> String? {
        var r = URLRequest(url: VajraAPI.loginURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = FormEncoding.encode([("pw", password), ("next", "/vajra/")]).data(using: .utf8)
        do {
            let (_, resp) = try await urlSession.data(for: r) // 303 → /vajra/ URLSession проходит сам
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 { return "Неверный пароль" }
        } catch {
            return "Нет связи с сервером"
        }
        switch await fetchMe() {
        case .ok:
            VajraAPI.rememberCookieFromStorage()
            offline = false
            state = .signedIn
            return nil
        case .unauthorized:
            return "Неверный пароль"
        case .unreachable:
            return "Нет связи с сервером"
        }
    }

    /// Выход: кука удаляется, локальные дни НЕ трогаются.
    func signOut() {
        let storage = VajraAPI.cookies
        for c in storage.cookies ?? [] where c.name == VajraAPI.cookieName {
            storage.deleteCookie(c)
        }
        VajraAPI.forgetCookie()
        markSignedOut()
    }

    func markOnline() { offline = false }
    func markOffline() { offline = true }

    /// 401 от API во время работы → экран входа (локальные данные остаются и дошлются после входа).
    func handleUnauthorized() {
        if demo { return }
        markSignedOut()
    }

    private func markSignedOut() {
        wasSignedIn = false
        email = nil
        UserDefaults.standard.removeObject(forKey: emailKey)
        offline = false
        state = .signedOut
    }

    private enum MeResult { case ok, unauthorized, unreachable }

    private func fetchMe() async -> MeResult {
        var r = URLRequest(url: VajraAPI.meURL)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        VajraAPI.prepare(&r)
        do {
            let (data, resp) = try await urlSession.data(for: r)
            VajraAPI.rememberCookie(from: resp)
            guard let http = resp as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 401 { return .unauthorized }
            guard http.statusCode == 200 else { return .unreachable }
            struct Me: Decodable { let uid: String?; let email: String? }
            let me = try? JSONDecoder().decode(Me.self, from: data)
            wasSignedIn = true
            email = me?.email
            UserDefaults.standard.set(me?.email, forKey: emailKey)
            return .ok
        } catch {
            return .unreachable
        }
    }
}
