import Foundation
import WebKit
import Security
import Network
import Combine

/// Manual cookies are an advanced escape hatch for a self-signed build whose
/// web session cannot be established. They are stored per host in the Keychain,
/// never in preferences, and are cleared when the account is signed out.
enum SessionVault {
    static let hosts = ["www.xiaohongshu.com", "www.rednote.com"]
    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.neoruaa.xhsdn.cookies",
         kSecAttrAccount as String: host]
    }
    static func cookie(_ host: String) -> String {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func hasCookie(_ host: String) -> Bool {
        !cookie(host).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A pasted cookie header can contain several `name=value` pairs. Invalid
    /// pairs are dropped instead of failing the whole entry, and the value is
    /// rejected outright when nothing usable remains.
    static func sanitize(_ raw: String) -> String {
        let pairs = raw
            .replacingOccurrences(of: "Cookie:", with: "")
            .replacingOccurrences(of: "\n", with: ";")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                guard let equals = pair.firstIndex(of: "=") else { return false }
                let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
                return !name.isEmpty && equals < pair.index(before: pair.endIndex)
            }
        return pairs.joined(separator: "; ")
    }

    static func set(_ value: String, host: String) throws {
        let q = query(host)
        let data = Data(value.utf8)
        if value.isEmpty { SecItemDelete(q as CFDictionary); return }
        let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var insert = q
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else if result != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}

enum ProxyConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        }
    }
}

enum NetworkPolicy {
    static func proxy(_ value: String) throws -> ProxyConfiguration? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let c = URLComponents(string: value), let host = c.host, !host.isEmpty,
              let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty, ["http", "socks5"].contains(c.scheme?.lowercased() ?? "") else {
            throw ProxyConfigurationError.invalid(L10n.text("network.proxy.invalid"))
        }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: UInt16(port))!)
        return c.scheme == "socks5" ? ProxyConfiguration(socksv5Proxy: endpoint) :
            ProxyConfiguration(httpCONNECTProxy: endpoint)
    }
    static func configuration(_ policy: DownloadPolicy, media: Bool = false) throws -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = min(180, max(5, policy.timeout))
        config.timeoutIntervalForResource = media ? 24 * 3600 : 180
        config.waitsForConnectivity = true
        if !media || policy.proxyMedia, let proxy = try proxy(policy.proxy) { config.proxyConfigurations = [proxy] }
        return config
    }
}

struct SignedInAccount: Codable {
    var name: String
    var uid: String?
    var redID: String?
    var avatar: URL?
    var verifiedAt: Date
}

@MainActor
final class WebSession: ObservableObject {
    static let shared = WebSession()
    @Published private(set) var account: SignedInAccount?
    let dataStore = WKWebsiteDataStore.default()
    init() {
        if let data = UserDefaults.standard.data(forKey: "session.account") {
            account = try? JSONDecoder().decode(SignedInAccount.self, from: data)
        }
    }
    func synchronize() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where Self.trusted(cookie.domain) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
    nonisolated static func trusted(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["xiaohongshu.com", "rednote.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func captureAccount(from webView: WKWebView) async {
        // Cookie writes can finish before the SPA updates its account object.
        // Keep the download session current even when account extraction fails.
        await synchronize()
        guard let host = webView.url?.host, Self.trusted(host) else { return }
        let script = """
        (() => {
          const s=window.__INITIAL_STATE__; if(!s) return null;
          const un=v=>v?._rawValue??v?.value??v;
          if(un(s.user?.loggedIn)!==true) return null;
          const u=un(s.user?.userInfo);
          if(!u || u.guest===true || !u.userId) return null;
          return JSON.stringify({name:u.nickname||u.nickName||u.name||"",
            uid:u.userId||u.user_id||u.id,redID:u.redId||u.red_id,
            avatar:u.imageb||u.images||u.image||u.avatar});
        })()
        """
        guard let result = try? await webView.evaluateJavaScript(script) as? String,
              let data = result.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["name"] as? String, !name.isEmpty else { return }
        let avatar = (dict["avatar"] as? String).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
        account = SignedInAccount(name: name, uid: dict["uid"] as? String, redID: dict["redID"] as? String,
                                  avatar: avatar, verifiedAt: Date())
        if let data = try? JSONEncoder().encode(account) { UserDefaults.standard.set(data, forKey: "session.account") }
        if let avatar { _ = await AuthorAvatarStore.shared.imageData(for: avatar) }
    }
    func logout() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where Self.trusted(cookie.domain) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let own = records.filter { Self.trusted($0.displayName) }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: own)
        for host in SessionVault.hosts { try? SessionVault.set("", host: host) }
        account = nil
        UserDefaults.standard.removeObject(forKey: "session.account")
    }
}

/// Serialises page requests so a batch of links cannot hammer the site. One
/// pacer belongs to one downloader: unrelated tasks (and test fixtures) must not
/// queue behind each other's reservations. An interval of zero means "no
/// pacing", and must not reserve a slot either.
actor RequestPacer {
    static let shared = RequestPacer()
    private var next = Date.distantPast
    func wait(interval: Double) async throws {
        try Task.checkCancellation()
        let interval = max(0, min(30, interval))
        guard interval > 0 else { return }
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(interval)
        if start > now { try await Task.sleep(for: .seconds(start.timeIntervalSince(now))) }
        try Task.checkCancellation()
    }
}
